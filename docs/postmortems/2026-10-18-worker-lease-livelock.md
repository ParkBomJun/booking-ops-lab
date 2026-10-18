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
알람 기능에 라이브락 감지가 실질적으로 작동하는지 확인이 필요

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