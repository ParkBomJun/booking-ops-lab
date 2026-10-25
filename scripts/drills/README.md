# 장애 훈련 스크립트 (`scripts/drills/`)

장애 훈련을 **같은 방법으로 다시 돌릴 수 있게** 스크립트로 남긴다. 각 스크립트는 주입 → 관찰 → 원복 → 증거 저장까지 한 번에 한다.
어떤 이유로 중간에 죽어도(에러, Ctrl-C) `trap` 이 원복을 실행한다.

| 파일 | 역할 |
|---|---|
| `lib.sh` | 공통 함수. Prometheus/Alertmanager 질의, 부킹 POST, 알림 대기, 스냅샷, 증거 저장. 직접 실행하지 않는다 |
| `drill2-claude-timeout.sh` | 훈련 2번: Claude 타임아웃 → 검토 대기함 급증 → `NeedsReviewRatioHigh` → Discord |

## 전제
- 스택 7개 컨테이너가 떠 있다 (`docker compose ps`). 스크립트가 먼저 세어 보고 7개가 아니면 멈춘다.
- 호스트에 `bash`, `curl`, `python3` (표준 라이브러리만). `jq` 는 필요 없다.
- WSL + Docker Desktop(통합 꺼짐) 이면 `docker.exe` 를 자동으로 쓴다. 서버(리눅스)에서는 `docker`. 바꾸려면 `DOCKER=... ` 로 지정.
- 설정 덮어쓰기는 `.env.drill2` 같은 **두 번째 env 파일**로 한다. `docker.exe` 는 Windows 프로세스라 WSL 셸 환경변수를 보지 못하고,
  env 파일 경로도 Windows 쪽에서 풀기 때문에 **저장소 루트 기준 상대 경로**여야 한다. 이 파일들은 `.gitignore` 의 `.env.*` 로 커밋되지 않는다.

## 훈련 2번: `drill2-claude-timeout.sh`

```bash
# 기본값: 20초마다 3건, 최대 12분, Discord 발송 확인 시 트래픽 중단, 원복 후 실제 호출 5건
bash scripts/drills/drill2-claude-timeout.sh

# 2026-10-22 실행값 (실제 호출 10건)
RECOVERY_REQUESTS=10 bash scripts/drills/drill2-claude-timeout.sh

# 증거를 덮어쓰지 않고 따로 보관
EVIDENCE_DIR=docs/postmortems/evidence/drill2-rerun bash scripts/drills/drill2-claude-timeout.sh
```

| 변수 | 기본 | 뜻 |
|---|---|---|
| `DURATION_SEC` | 720 | 주입 트래픽 최대 시간 |
| `RATE_N` / `RATE_INTERVAL_SEC` | 3 / 20 | "20초마다 3건" |
| `STOP_ON_DISCORD` | 1 | Discord 발송 카운터가 오르면 DURATION 전에 트래픽 중단 (검토함에 쌓이는 가짜 행을 줄인다) |
| `RECOVERY_REQUESTS` | 5 | 원복 후 **실제 Claude 호출** 건수. 비용이 들므로 최대 10 |
| `WAIT_RESOLVE_SEC` | 720 | 알림 해제 대기 상한 |
| `WAIT_RESOLVED_NOTIFY_SEC` | 600 | 해제 후 Discord resolved 메시지 대기 상한 |
| `EVIDENCE_DIR` | `docs/postmortems/evidence/drill2` | 증거 파일 위치. 같은 이름은 덮어쓴다 |

### 무엇을 하는가
1. **사전 점검** — 호스트와 Prometheus 컨테이너의 시계 차이(Docker VM 시계가 몇 시간 뒤처진 적이 있다), 컨테이너 7개, `compose config` 로 병합 결과(`CLAUDE_TIMEOUT_MS: "1"`) 확인, `baseline.json`.
2. **주입** — `docker compose --env-file .env --env-file .env.drill2 up -d --no-deps booking-api`. booking-api 컨테이너만 재생성된다. `CLAUDE_TIMEOUT_MS=1` 이면 1ms 안에 컨텍스트가 만료돼 TLS 도 못 맺는다 → Claude API 에 닿지 않으니 **과금 0**, 응답은 `201` + `status=needs_review` + `review_reason=claude_timeout`.
3. **트래픽** — 가짜 부킹 텍스트(테스트상사, 부산→로테르담 등) 를 고유한 `Idempotency-Key`(`drill2-<ns>-<seq>`) 로 보낸다. **첫 요청이 `claude_timeout` 폴백이 아니면 "주입 안 됨" 으로 즉시 중단**한다 (훈련 1번 때 주입이 조용히 실패한 적이 있어서).
4. **관찰** — 20초마다 한 줄: 보낸 건수, 비율 식 값, `ALERTS` 상태, Discord 카운터. pending / firing / Discord 시각을 타임라인에 남긴다.
5. **원복** — `docker compose --env-file .env up -d --no-deps booking-api`. 컨테이너 환경변수를 `grep '^CLAUDE_TIMEOUT_MS='` 로만 확인한다(전체를 찍으면 API 키가 나온다).
6. **회복 증명** — 실제 Claude 호출 N 건 → `status=parsed`, 소요 ms 기록.
7. **해제 대기** — Prometheus `ALERTS` 에서 사라질 때까지. 비율 식이 5분 윈도우라 마지막 타임아웃 요청 뒤 5분 이상 걸린다. resolved 메시지는 Alertmanager 가 다음 `group_interval`(warning 10m) 틱에 보내므로 따로 기다려 카운터로 확인한다.
8. **증거 + 최종 점검** — `after.json`, 구간 질의(`*-range.json`), `timeline.tsv`, `requests.tsv`, `summary.json`. 노브 기본값, 컨테이너 7개, 최근 2분 `claude_timeout` 증가분 0, Alertmanager 에 남은 알림.

### 어디를 보는가
- Prometheus http://localhost:9090
  - 비율: `sum(rate(booking_processed_total{result="needs_review"}[5m])) / sum(rate(booking_processed_total{result=~"parsed|needs_review"}[5m]))` → 주입 뒤 1.0
  - 원인: `sum by (result) (increase(booking_claude_requests_total[1m]))` → `claude_timeout` 만 오른다
  - 알림: `ALERTS{alertname="NeedsReviewRatioHigh"}` (pending → firing), `ALERTS_FOR_STATE` (pending 시작 시각)
  - 적체: `booking_needs_review_count`
- Alertmanager http://localhost:9093 — firing 목록, `inhibitedBy`. 발송 증거는 `alertmanager_notifications_total{integration="discord"}` 카운터(Prometheus 에서 질의).
- Discord — `[FIRING:1] NeedsReviewRatioHigh (warning)` 메시지, 해제되면 `[RESOLVED]`.

### 예상 시간 (규칙 설계값)
| 단계 | 설계 | 이유 |
|---|---|---|
| pending | T0 + 약 30s | `rate()` 는 샘플 2개가 필요 → 스크레이프 15s × 2 |
| firing | pending + 5m (+ 평가 주기 15s) | 규칙 `for: 5m` |
| Discord | firing + 2m | warning 라우트 `group_wait: 2m` |
| **합계** | **T0 + 약 7.5~8m** | 2026-10-22 측정값은 포스트모템 참고 |
| 해제 | 마지막 타임아웃 요청 + 약 5m | 5분 윈도우에서 needs_review 가 빠져야 비율 < 0.5 |
| resolved 메시지 | 해제 + 최대 10m | `group_interval: 10m` |

### 원복 확인 (스크립트가 끝에 찍지만 손으로도)
```bash
docker.exe inspect booking-api --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^CLAUDE_TIMEOUT_MS='   # 10000
docker.exe compose ps   # 7개 Up
curl -s 'localhost:9090/api/v1/query' --data-urlencode 'query=sum(increase(booking_claude_requests_total{result="claude_timeout"}[5m]))'   # 비어 있거나 0
curl -s localhost:9093/api/v2/alerts   # 남은 알림. NeedsReviewBacklog(info) 는 훈련 행이 남아 있는 동안 켜져 있을 수 있다
```

### 뒷정리 (선택)
훈련이 남긴 `needs_review` 행은 자동으로 돌아오지 않는다(상태 기계상 `needs_review → parsed` 는 사람 몫, 미구현). 20건을 넘으면 30분 뒤 `NeedsReviewBacklog`(info, Discord 미발송) 가 켜진다.
지우려면 (가짜 데이터이므로 안전):
```sql
DELETE FROM bookings WHERE idempotency_key LIKE 'drill2-%' AND status = 'needs_review';
```
