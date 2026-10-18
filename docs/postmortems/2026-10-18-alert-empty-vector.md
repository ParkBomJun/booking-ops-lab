# 포스트모템: 알림 규칙의 빈 벡터 문제 (2026-10-18)

## 요약
처리 정체를 잡기 위한 critical 알림 `BookingProcessingStalled` 가 실제 라이브락 상황에서 12분 49초 동안 한 번도 평가되지 않았다. 원인은 식의 `rate(worker_transitions_total{from="parsed"}[5m]) == 0` 부분이 "전이 0건" 과 "시계열 없음" 을 구분하지 못한 것이다. 재시작 직후처럼 전이를 한 번도 성공하지 못한 프로세스는 Counter 시계열 자체가 없고, `and` 로 묶인 식 전체가 빈 벡터가 되어 알림이 존재하지 않는 것처럼 동작했다. 규칙에 `or vector(0)` 을 넣고 worker 가 시작 시 전이 지표를 0 으로 선등록하도록 고친 뒤 재검증에서 **3분 18초 만에 Discord 도착** 을 확인했다.

## 영향
- 실사용 영향 없음(훈련 중 발견).
- 운영이었다면: worker 가 재시작된 뒤 정체되는 가장 흔한 시나리오(잘못된 배포, 설정 오류, 임대 라이브락)에서 critical 알림이 **영원히** 오지 않는다. 부수 증상(이번엔 포워더 지연 warning)이 우연히 있을 때만 12분 뒤 알게 된다.

## 타임라인 (KST)
| 시각 | 사건 |
|---|---|
| 17:14 | 임대 라이브락 포스트모템에 "운영이었다면 Stalled 가 잡았을 것" 이라 기록. 검증 필요 항목으로 남김 |
| 17:57 | 검증 1회차: 보정 제거 복제본(임대 1s, 포워더 지연 2.5s)으로 라이브락 재현. `worker` 별칭으로 띄워 Prometheus 가 수집 |
| 17:58 | +30s `VersionConflictsObserved` firing (info, Discord 미발송) |
| 18:08 | +10m49s `ForwarderLatencyHigh` firing (부수 증상) |
| 18:10 | +12m49s Discord 수신. 내용은 `ForwarderLatencyHigh`. **Stalled 는 pending 조차 없음** |
| 18:1x | 18:05 시점 질의로 원인 확인: `worker_transitions_total{from="parsed"}` EMPTY, parsed=2, up=1 |
| 18:4x | 수정 적용(규칙 `or vector(0)`, 억제 규칙, 지표 0 선등록). 재검증 2회차(지연 1.5s)는 라이브락이 유지되지 않아 무효 |
| 19:28 | 재검증 3회차: 복제본 폴링 250ms, 임대 1s, 지연 1.5s(지연 warning 임계 2s 미만). parsed 2건 투입 |
| 19:28:47 | +46s `BookingProcessingStalled` pending |
| 19:30:48 | +2m47s firing. Alertmanager 에서 `VersionConflictsObserved` 가 Stalled 에 억제됨(inhibited) 확인 |
| **19:31:19** | **+3m18s Discord 수신 = `BookingProcessingStalled`** (critical group_wait 30s). p95 는 1.95s 로 지연 warning 은 끝까지 침묵 |
| 19:31 | 정리: 복제본 컨테이너·이미지 삭제, 운영 worker 복귀(lease 60000ms, `worker_config_adjusted`=0), 포워더 기본값 |

## 감지 방법
- 1회차: Discord 에 온 것은 `ForwarderLatencyHigh` 뿐. 정체 자체를 가리키는 알림은 없었다. 로그에서 `version conflict` 938줄, DB 에서 version 471 을 보고서야 정체를 알 수 있었다.
- 3회차(수정 후): Stalled 가 유일하게 Discord 로 간 알림. 같은 원인의 info 알림은 억제 규칙으로 UI 에만 남았다.
- 도착 시간 해석: 이번 3분 18초는 **직전 5분간 전이가 없던 상태**에서 잰 값(= 15s 스크레이프 + for 2m + group_wait 30s + 약간). 정상 처리 중이다가 정체되면 5분 윈도우가 비는 시간이 더해져 **최대 약 8분 30초**. 설계 의도(약 7분) 안이다.

## 근본 원인
1. **PromQL 의미론 오해.** `rate(x[5m]) == 0` 은 x 가 존재할 때만 0 을 돌려준다. 존재하지 않으면 빈 벡터이고, 빈 벡터와 `and` 한 결과도 빈 벡터다. "0" 과 "없음" 을 같은 것으로 가정했다.
2. **Counter 의 지연 생성.** `prometheus.CounterVec` 은 `WithLabelValues(...)` 가 처음 호출될 때 시계열을 만든다. 전이를 한 번도 못 한 프로세스는 `from="parsed"` 시계열이 없다. 정체가 심할수록(전이 0건) 지표가 없어지는, 알림 목적과 정반대의 성질이다.
3. **검증 없는 가정.** 규칙을 쓰고 `promtool check rules` 만 통과시킨 뒤 "울릴 것" 이라고 문서에 적었다. 문법 검사는 의미를 검사하지 않는다.

## 조치
- `infra/monitoring/alert-rules.yml`: `(sum(rate(worker_transitions_total{from="parsed"}[5m])) or vector(0)) == 0`.
- `infra/monitoring/alertmanager/alertmanager.yml`: `TargetDown{service=worker}` → `BookingProcessingStalled` 억제. 수정 후엔 worker 가 죽어도 Stalled 가 같이 울리므로 critical 두 개를 하나로 줄인다.
- `services/worker/metrics.go` `preRegisterTransitions()`: 전이 표의 모든 (from,to) 와 version 충돌 카운터를 시작 시 0 으로 선등록. 규칙 쪽 방어와 이중.
- 재검증으로 Discord 도착 3분 18초 확인.

## 재발 방지
- Counter 기반 "0 이면 이상" 규칙은 항상 `or vector(0)` 또는 `absent()` 와 함께 쓴다. 코드 리뷰 체크리스트에 추가(`docs/metrics.md` "Counter 기반 규칙의 함정").
- 앱은 알림이 의존하는 라벨 조합을 시작 시 0 으로 내보낸다.
- 알림 규칙은 **장애를 실제로 주입해 Discord 도착 시간을 잰 뒤** "감지한다" 고 적는다. 포스트모템 감지 방법 절에는 측정값을 쓴다.
- 미해결: `BacklogAging` 은 라이브락에서 pending/해제를 반복한다(행이 매 틱 claim 되어 "대기 중" 시간이 짧음). 대기 정의를 `claimed_until` 무관하게 바꿀지 검토.

## 배운 점
- 알림은 "조건이 참이면 울린다" 가 아니라 "조건이 **평가되어** 참이면 울린다". 평가 자체가 안 되는 경우(빈 벡터, 스크레이프 실패, 라벨 불일치)가 더 위험하다. 조용히 아무 일도 안 일어나기 때문이다.
- 가장 심한 장애일수록 지표가 사라지는 설계를 피한다. "일이 안 일어났다" 는 사실을 0 이라는 값으로 남겨야 한다.
- 검증 환경의 사소한 수치(폴링 틱 1s vs 호출 1.5s)가 재현 성패를 가른다. 2회차가 무효였던 이유를 이해하지 못했다면 "라이브락이 안 생기니 문제없다" 는 잘못된 결론을 냈을 것이다.

## 참고
- 선행 포스트모템: `2026-10-18-worker-lease-livelock.md` (감지 방법 절의 1회차 측정)
- 재현 스크립트 출력: 1회차 Discord +769s, 3회차 Discord +198s
