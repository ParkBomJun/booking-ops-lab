# 포스트모템: worker 임대 라이브락 (2026-10-18)

## 요약
worker의 임대 시간(1초)이 포워더 HTTP 타임아웃(3초)보다 짧아, 처리 중인 건을 매 폴링마다 다른 일꾼이 다시 집어가고 먼저 끝난 결과는 version 불일치로 버려지는 라이브락이 발생했다. 전송은 매번 성공했지만 DB 상태는 parsed에서 넘어가지 못했다. 임대를 타임아웃의 2배 이상으로 조정하고 시작 시 검증을 추가해 해결했다.

## 영향
parsed 상태 부킹 2건이 sent로 전이되지 못하고 무한 재처리됨. worker는 정상 기동 상태로 보였고 에러 로그도 없어 헬스체크로는 감지 불가. 실사용 영향 없음 (테스트 중 발견).

## 타임라인
(시각 KST. 최초 발생은 10:41경 검증 중이었고 그 컨테이너 로그는 재빌드로 유실되어, 수정 전 조건을 17:14에 복제본으로 재현한 로그를 쓴다. 원본 로그 파일: 바탕화면 `worker-livelock-log-2026-10-18.txt`)

```
17:14:04.261 INFO  worker config                      poll_ms=1000 concurrency=4 http_timeout_ms=3000 max_attempts=5 backoff_base_ms=1000 backoff_max_ms=30000 lease_ms=1000
17:14:04.272 INFO  worker http starting               addr=:18081
17:14:09.784 INFO  forwarder accepted                 booking_id=livelock-2 attempt=1 stage=send result=ok ref=FWD-dm7tb9b3y1ph
17:14:09.784 INFO  forwarder accepted                 booking_id=livelock-1 attempt=1 stage=send result=ok ref=FWD-dm7tb9b3x5gb
17:14:09.786 WARN  version conflict, result discarded booking_id=livelock-2 attempt=1 expected_version=2 actual_version=3 actual_status=parsed
17:14:09.786 INFO  processed                          booking_id=livelock-2 attempt=1 stage=parsed duration_ms=2506
17:14:09.797 WARN  version conflict, result discarded booking_id=livelock-1 attempt=1 expected_version=2 actual_version=3 actual_status=parsed
```

이후 1초 간격으로 동일 패턴 반복 (version 2→3→4→5…). 30초 관찰 동안 version 충돌 38건, 두 건 모두 parsed 유지, version 21까지 상승.

10:44 (최초 발생 당일) lease 하한 보정 코드 추가, 재빌드 → 정상 전이 확인. 17:14 재현 시 보정 제거 복제본에서만 재발.

## 감지 방법
테스트에선 로그에서 version conflict 반복 패턴으로 발견. 운영이었다면 worker_version_conflicts_total이 0에서 급증하는 것(info 알림 VersionConflictsObserved)과, parsed가 5분간 안 빠지는 BookingProcessingStalled(critical)로 감지됐을 것.
알람 기능에 라이브락 감지가 실질적으로 작동하는지 확인이 필요 → 아래에서 검증함.

### 검증: 알림이 실제로 라이브락을 잡는가 (2026-10-18 17:57~18:11 KST)
방법: 보정을 뺀 복제본을 compose 네트워크에 `worker` 별칭으로 띄워(운영 worker 정지, Prometheus 설정 무변경) 포워더 지연 2.5s·임대 1s 로 parsed 2건을 투입. 15초마다 Prometheus/Alertmanager 상태와 Discord 발송 카운터를 기록.

| 경과 | 사건 |
|---|---|
| +0s | parsed 2건 투입. 복제본이 1초마다 재claim 시작 |
| +30s | `VersionConflictsObserved` firing (info → Discord 안 감, UI 에만) |
| +46s~ | `ForwarderLatencyHigh` pending (지연 2.5s 가 p95 임계 2s 초과), `BacklogAging` 은 pending/해제 반복 |
| +649s (10m49s) | `ForwarderLatencyHigh` firing |
| **+769s (12m49s)** | **Discord 수신 1건 = `ForwarderLatencyHigh`** (firing 후 group_wait 2m) |
| 종료 시 | `BookingProcessingStalled` **한 번도 pending 되지 않음.** 2건은 parsed 유지, version 471, 복제본 로그에 version conflict 938줄 |

**결론: 설계 가정이 틀렸다.** 라이브락을 직접 가리키는 critical 알림은 오지 않았고, 포워더 지연이라는 부수 증상의 warning 만 12분 49초 만에 왔다. 지연 주입이 없는 라이브락(예: GC 정지, 느린 DB)이었다면 Discord 에 아무것도 오지 않았다.

**왜 Stalled 가 안 울렸나.** 식 `... and on() sum(rate(worker_transitions_total{from="parsed"}[5m])) == 0` 에서 복제본은 새 프로세스라 전이를 한 번도 성공하지 못했고, CounterVec 은 첫 Inc 전에는 시계열을 만들지 않는다. 즉 `worker_transitions_total{from="parsed"}` 가 **0 이 아니라 없음(absent)** 이어서 `and` 가 빈 결과가 됐다(18:05 시점 질의로 확인: 시계열 EMPTY, parsed=2, up=1). "worker 가 죽으면 안 울린다" 고 알고 있던 한계가 "재시작 직후 정체에도 안 울린다" 로 넓어진 것이다. 운영에서 가장 흔한 정체 시나리오(배포 직후 멈춤)를 정확히 놓친다.

**부수 관찰.** (1) `BacklogAging` 은 행이 1초마다 claim 되어 "대기 중" 으로 잡히는 시간이 짧아 pending 에서 계속 해제됐다. 라이브락에는 쓸모없는 지표다. (2) 정리 후 2건이 `failed` 가 됐다: 복제본 종료 시 마지막 in-flight 쓰기가 성공해 `sent` 가 됐는데, mock-forwarder 를 재기동하며 메모리가 비어 GET 이 404 → 4xx 즉시 실패 규칙에 걸렸다. 모의 시스템의 한계지만, "상대 시스템이 상태를 잃었을 때 confirm 404 를 즉시 실패로 볼 것인가" 는 실제 운영에서도 결정이 필요한 지점이다.

**후속 조치 → 적용 완료. 결과는 `2026-10-18-alert-empty-vector.md`.** 수정 후 재검증에서 Stalled 가 3분 18초 만에 Discord 도착.
1. Stalled 식을 absent 에 강건하게: `(sum(rate(worker_transitions_total{from="parsed"}[5m])) or vector(0)) == 0`. 그러면 worker 가 죽었을 때도 Stalled 가 울리므로 `TargetDown{service=worker}` → `BookingProcessingStalled` inhibition 을 추가해 critical 중복을 막는다.
2. worker 시작 시 `worker_transitions_total` 의 주요 라벨 조합을 0 으로 미리 등록(`WithLabelValues(...).Add(0)`)해 "없음" 과 "0" 을 구분 가능하게 한다. 1 과 함께 적용하면 이중 방어.
3. 재검증: 같은 방법으로 재현해 Stalled 가 약 7분(5m 윈도우 + for 2m) + 30s(critical group_wait) 안에 Discord 에 도착하는지 측정.

정리 확인: 복제본 컨테이너·이미지 삭제, 운영 worker 복귀(lease_ms=60000, `worker_config_adjusted`=0, healthz ok), 포워더 기본값, 작업 트리 변경 0건.

## 근본 원인
임대(lease_ms)와 HTTP 타임아웃(http_timeout_ms)은 "임대 > 타임아웃"이어야 하는 서로 의존하는 값인데, 독립된 설정으로 존재했고 그 관계를 검증하는 코드가 없었다. 그래서 잘못된 조합으로도 worker가 정상 기동했다.

## 조치
임대 값을 타임아웃 값보다 높게 수정

## 재발 방지
시작 시 lease_ms >= 2 × http_timeout_ms 검증. 위반 시 안전값으로 자동 상향하고 WARN 로그에 설정값·보정값을 남긴다. 기동 실패가 아닌 보정을 택한 이유: 이 값은 다른 설정에서 계산 가능하고, worker가 안 뜨면 처리 정체라는 더 큰 장애가 되기 때문.
보정 발생을 worker_config_adjusted 지표로 노출하고 info 알림 연결 (로그에만 남는 경고는 놓치기 쉬우므로).
BookingProcessingStalled 알림 추가 — 라이브락을 포함해 worker가 조용히 멈춘 모든 경우를 감지.

## 배운 점
프로세스가 살아 있는 것과 일이 완료되는 것은 다르다. 헬스체크는 전자만 보여주므로, 처리량 지표와 정체 알림이 있어야 후자가 보인다.
서로 의존하는 설정값은 코드가 그 관계를 검증해야 한다. 잘못된 조합을 조용히 받아들여 돌다 터지는 것이 최악이다.
설정 검증은 한 가지 방식이 아니다. 없으면 동작 불가한 값은 기동 실패로, 다른 값에서 계산 가능한 안전 파라미터는 보정 후 경고로 나눈다.