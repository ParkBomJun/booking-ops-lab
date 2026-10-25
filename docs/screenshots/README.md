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

## 추가 예정 — 2026-10-25 Azure 실배포 (파일은 사람이 넣는다)

Grafana 는 NSG 로 작업자 IP 에만 열려 있어 외부인은 접속할 수 없다. 그래서 운영 화면은 스크린샷으로 대체한다. 캡처 시 구독 ID·개인 IP 가 보이는 부분은 가린다.

| 파일 | 내용 |
|---|---|
| `cd-4-first-success.png` | Actions CD #4 (`2b46837`) — 첫 end-to-end 성공. verify · build-push ×3 · deploy 전부 초록, 1m 36s |
| `cd-5-rolled-back.png` | Actions CD #5 (`6bb00dc`) — deploy job 빨강, 요약에 `DEPLOY_RESULT=rolled_back` 과 `rolling back to 1d951b2…` |
| `cd-runs-list.png` | CD 실행 목록 — #4 초록 → #5 빨강 → #6 초록 연속. 문서 커밋 `2083a55` 에는 실행이 없다 |
| `grafana-azure-home.png` | Azure VM 의 Grafana (`http://<fqdn>:3000`) 홈 — 프로비저닝된 데이터 소스·대시보드 |
| `azure-resource-group.png` | 포털 `rg-bookingops-lab` 리소스 목록 — Terraform 이 만든 것(VM·NIC·공인 IP·NSG·VNet·Storage·Key Vault·자동 종료) |
| `history-log.png` | VM `/opt/booking-ops-lab/.deploy/history.log` — `rolled_back new=6bb00dc… rollback_to=1d951b2…` 행 |
