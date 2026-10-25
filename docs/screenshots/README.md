# 스크린샷 (2026-10-18, 장애 훈련 1번 재현)

시각은 전부 UTC. 훈련: mock-forwarder `FAIL_RATE=0.5`, 20초마다 부킹 5건, 11분간 (02:27~02:42).

| 파일 | 내용 |
|---|---|
| `prometheus-worker-attempts.png` | `worker_attempts_total` 분당 시도 수(result 별). 02:27부터 `http_5xx`가 올라오고 `ok`도 재시도로 같이 늘어난다 |
| `prometheus-forwarder-error-ratio.png` | 실패 비율. 임계값 0.2를 넘어 0.30~0.38에서 유지. 포워더 원복(02:42) 직후 분모가 줄며 순간 0.5 스파이크 후 0 |
| `prometheus-alerts-timeline.png` | `ALERTS` 시계열. `ForwarderErrorRateHigh` 02:28 pending → 02:33 firing, `FailedBookingsIncreasing` 02:28 firing. 두 알림 모두 02:49 해제 |
| `prometheus-alert-rules.png` | 규칙 10개(3그룹) 로드 상태 — 캡처 당시 수치. 이후 `ConfigAdjusted`가 추가되어 현재 11개 |
| `alertmanager-status.png` | Alertmanager v0.28.1 상태·설정(웹훅 URL은 파일 참조라 노출되지 않음) |
| `grafana-booking-api-drill1.png` | 같은 구간의 booking-api 대시보드. 훈련 행을 DB에 직접 넣어 API 패널은 비어 있고 상태별 건수만 변한다. **worker 대시보드는 아직 없음(다음 작업)** |

Discord 수신 화면은 헤드리스로 찍을 수 없어 수동 캡처 필요: `discord-forwarder-error-rate.png` 로 저장 예정.

## 캡처 방법
Windows Chrome 헤드리스로 찍는다 (Grafana 는 캡처 동안만 익명 Viewer 허용 후 원복).
```
chrome.exe --headless=new --window-size=1600,1000 --virtual-time-budget=30000 --screenshot=<out>.png "<url>"
```
주의: 훈련 중 Docker VM 시계가 호스트보다 뒤처져 있어 데이터가 실제보다 이른 시각에 기록됐다. "최근 1시간" 대신 `g0.end_input` / Grafana `from`·`to` 로 구간을 명시해 찍었다.
