# AI 도구 활용 기록

이 프로젝트는 Claude Code를 보조 도구로 사용해 진행한다.
**AI가 틀리게 만든 부분과 고친 과정**을 빠짐없이 기록하는 것이 이 문서의 목적이다.

## 2026-10-17 — 1단계: Go 모듈 초기화 + `/healthz`

### 한 일
- `services/booking-api/go.mod` 생성 (`go mod init`)
- `main.go`: 표준 라이브러리만으로 HTTP 서버, `GET /healthz` → `{"status":"ok"}`
- `log/slog` JSON 로거를 기본 로거로 설정
- `http.Server`에 Read/Write/Idle 타임아웃 명시

### AI 실수와 수정
- **gofmt 미준수**: AI가 작성한 구조체 필드의 주석 정렬이 `gofmt` 기준과 달랐다.
  `gofmt -l .`로 감지 → `gofmt -w main.go`로 수정. 이후 CI에서 `gofmt -l` 결과가 비어 있지 않으면 실패시키는 규칙을 넣을 예정.
- **검증 스크립트 조건 오류**: `gofmt -l . && echo fmt-dirty`는 출력이 없어도(=정상) 성공 코드로 끝나 "fmt-dirty"를 찍었다.
  실제 상태는 정상이었고, 포맷 검사는 `test -z "$(gofmt -l .)"` 형태가 맞다.

### 검증 결과
- `GET /healthz` → 200, `{"status":"ok"}`
- `POST /healthz` → 405 (메서드 지정 라우팅 `"GET /healthz"` 동작 확인)
- 시작 로그가 한 줄 JSON으로 출력됨

## 2026-10-17 — 1단계: docker-compose(PostgreSQL + booking-api), `/healthz` DB 확인

### 한 일
- `services/booking-api/Dockerfile`: 멀티스테이지 빌드(golang:1.27-alpine → distroless static nonroot), 최종 이미지 18.8MB
- `docker-compose.yml`: postgres:17-alpine(healthcheck, 명명 볼륨) + booking-api(`depends_on: service_healthy`)
- `.env.example` 추가. 실제 `.env`는 gitignore 대상
- `main.go`: `pgxpool`로 DB 연결, `/healthz`가 2초 타임아웃 Ping 실패 시 503 + `{"status":"degraded"}`
- 시작 시 `DATABASE_URL` 없으면 즉시 종료(fail-fast), DB 도달 불가 시 종료 후 compose restart에 맡김

### AI 실수와 수정
- 이번 작업에서는 빌드·실행 모두 첫 시도에 통과. 단, AI가 처음 제안한 compose의 booking-api `healthcheck`는
  distroless 이미지에 curl/셸이 없어 동작할 수 없음을 작성 중 확인하고 제거했다. 대신 외부 `healthcheck.sh`와
  Prometheus로 확인하는 방향으로 메모를 남겼다.

### 검증 결과
| 상황 | 응답 |
|---|---|
| 정상 | 200 `{"status":"ok","checks":{"db":"ok"}}` |
| `docker compose stop postgres` | 503 `{"status":"degraded","checks":{"db":"fail: context deadline exceeded"}}` |
| `docker compose start postgres` 후 | 200으로 자동 복귀 (재시작 불필요, 풀이 재연결) |

## 2026-10-17 — 1단계: 스키마·마이그레이션, Claude 파싱(타임아웃·폴백), 멱등 저장

### 한 일
- `migrations/001_create_bookings.sql` + `migrate.go`: `embed`로 SQL을 바이너리에 포함, 시작 시 `schema_migrations`에 없는 파일만 파일당 1트랜잭션으로 적용. `pg_advisory_lock`으로 다중 인스턴스 동시 실행 방지
- `parser.go`: Anthropic Go SDK(v1.82.0). 요청별 `context.WithTimeout`, SDK 재시도 0, 실패 사유를 `claude_timeout / claude_error / invalid_json / validation_failed`로 분류. 요청당 `input_tokens / output_tokens / cache_read_tokens / elapsed_ms` 로그
- `store.go`: `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING RETURNING` → 0행이면 기존 행 반환. UNIQUE 제약이 동시 요청의 최종 방어선
- `handlers.go`: `POST /bookings`(`Idempotency-Key` 헤더 필수, 본문 16KB 제한), `GET /bookings/{id}`
- 비밀값 보호: API 키는 `mustEnv`→`NewParser` 인자로만 전달, 구조체에 보관하지 않음. 시작 로그는 `api_key_set=true/false`만 출력. API 에러 로그는 `status`와 `request_id`만 남기고 에러 객체 전체를 찍지 않음

### AI 실수와 수정
- **불필요한 import 우회 코드**: 처음 작성한 `handlers.go`에 쓰지 않는 `io` 패키지를 `var _ = io.EOF`로 억지로 유지하는 줄이 있었다. 빌드 직후 발견해 import와 함께 삭제. "컴파일러 경고를 피하기 위한 코드"는 코드 리뷰에서 걸릴 전형적인 패턴
- **WriteTimeout 충돌 사전 발견**: 기존 `http.Server.WriteTimeout`이 10초였는데 Claude 호출 타임아웃도 10초라 응답 직전에 연결이 끊길 수 있었다. 작성 중 발견해 30초로 조정
- **gofmt 2회 재발**: 새 파일 작성 후 `gofmt -l`에 걸림. 이제 매 작업 마지막에 `gofmt -w` + `test -z "$(gofmt -l .)"`를 고정 절차로 둔다. CI에 반드시 넣을 것

### 설계 메모
- 구조화 출력(`output_config.format`) 대신 시스템 프롬프트 + Go 측 JSON 파싱/검증을 택했다. 모델 출력이 깨지는 경우가 곧 "검토 대기함" 폴백이라 장애 훈련 시연에 유리하고, 코드가 단순하다
- 기본 모델은 `claude-opus-5-5`, `CLAUDE_MODEL`로 교체 가능. 비용이 걱정되면 `claude-haiku-5-5`로 바꿔 테스트 가능 (1단계 부킹 파싱 정도면 품질 차이 작음)
- SDK 자체 재시도를 끈 이유: 재시도 정책을 서비스가 통제해야 지표(재시도 횟수)가 정확하고, 이 서비스는 재시도 대신 폴백이 설계 원칙

### 검증 결과 (실제 API 키 없이 가능한 경로)
| 시나리오 | 결과 |
|---|---|
| 잘못된 키 → Claude 401 | 201, `status=needs_review`, `review_reason=claude_error`, 로그에 키 노출 0건 |
| `CLAUDE_TIMEOUT_MS=1` | 201, `review_reason=claude_timeout`, `elapsed_ms=1` |
| 같은 `Idempotency-Key` 재전송(본문 달라도) | 200, 기존 행 반환, Claude 미호출 (`stage=idempotency` 로그) |
| 헤더 누락 | 400 |
| 컨테이너 재시작 | `migration applied` 로그 없음 (재적용 안 됨) |
| 실제 키(워크스페이스 범위)로 파싱 | 201, `status=parsed`, 8개 필드 전부 정확. `claude-haiku-5-5`, 입력 364 / 출력 99 토큰, 1,344ms |

### 추가 (같은 날) — 실제 키 테스트에서 400, 로그 설계 실수 발견
- **증상**: 실제 키를 넣고 호출하자 Claude API가 400. `review_reason=claude_error`로 폴백은 정상 동작했지만 원인을 알 수 없었다.
- **로그 설계 실수(AI)**: "키가 섞여 들어갈 수 있다"는 이유로 API 에러 로그에 `status`와 `request_id`만 남기게 했다.
  그 결과 장애 원인 파악에 curl로 **재현**이 필요했다. SDK 소스를 확인하니 `apiErr.Error()`는 메서드·URL·상태·요청ID·응답 본문만 담고
  요청 헤더(키)는 포함하지 않아 로그에 남겨도 안전했다. → 에러 메시지를 로그에 포함하도록 수정.
  교훈: **비밀값 보호와 진단 가능성은 상충하지 않는다. 무엇이 비밀인지 정확히 확인하고 그것만 가린다.**
- **실제 원인**: 발급한 키가 특정 워크스페이스에 묶이지 않은 조직 범위 키여서 `anthropic-workspace-id` 헤더가 필요했다.
  코드에 `ANTHROPIC_WORKSPACE_ID`(선택) 지원을 추가. 권장은 **워크스페이스 범위 키를 새로 발급**하는 것 — 최소 권한 원칙에도 맞고 헤더가 필요 없다.

## 2026-10-17 — 1단계: `/metrics`, Prometheus, Grafana

### 한 일
- `metrics.go`: 지표 7종(`docs/metrics.md`), DB 조회형 Gauge Collector, HTTP 미들웨어(404/405 → `route="unknown"`)
- `ctxlog.go`: context 로거. 요청 범위 모든 로그 줄에 `booking_id` 보장
- `infra/monitoring/prometheus.yml`(`sample_limit: 1000`), Grafana 데이터소스·대시보드 프로비저닝(패널 10개), compose에 Prometheus v3.5.0 / Grafana 12.2.0 추가
- Grafana는 `.env` 비밀번호, 가입 금지, UI 수정 불가(설정은 코드로만)

### AI 실수와 수정
- **존재하지 않는 함수 호출**: 상태 코드를 문자열로 바꾸며 `http.StatusText0`라는 없는 함수를 썼다. 컴파일 전 자체 검토에서 발견해 `strconv.Itoa`로 교체. Go 표준 라이브러리 함수명을 기억으로 쓰지 말고 확인할 것
- **unused import**: parser에서 `slog` 직접 호출을 ctx 로거로 바꾼 뒤 import를 안 지워 `go vet` 실패 → 삭제
- **로그 식별자 불일치(이전 작업의 숨은 버그)**: 이전 커밋에서 parser는 `booking_id`=멱등키, handler는 `booking_id`=DB 숫자 id를 찍고 있었다. 같은 키 이름에 다른 의미가 섞여 로그 검색이 깨지는 상태였다. 이번에 `booking_id`=멱등키, `row_id`=DB id로 통일

### 검증 결과
| 항목 | 결과 |
|---|---|
| `/admin`, `/.env`, `/wp-login.php`(404), `DELETE /healthz`(405) | 전부 `route="unknown"` 한 시계열로 집계 |
| 정상 라우트 | `/healthz`, `/bookings`, `/bookings/{id}` 패턴 라벨 |
| 샘플 수 | 129 (sample_limit 1000) |
| Prometheus 타깃 | booking-api `up`, `booking_needs_review_count`=4 질의 성공 |
| Claude 지표 | 실제 호출 1건: ok=1, input 336 / output 89 토큰, 1.31s |
| 로그 `booking_id` | stage 포함 로그 3/3 줄에 존재 |
| Grafana | 대시보드 자동 로드 확인 (http://localhost:3000/d/booking-api) |

## 2026-10-18 — 2단계: mock-forwarder + worker

### 한 일
- 구현 전 설계 문서로 합의: DB 가 큐, claim 은 `FOR UPDATE SKIP LOCKED` + 임대(`claimed_until`), 백오프는 `next_attempt_at` 컬럼에 저장, 모든 쓰기는 `WHERE version = $expected` 낙관적 잠금, 상태 전이 표로 역행 차단. 결정 사항: 4xx 즉시 failed, 409/200 은 성공, `DUP_RATE` 는 "저장 후 500(응답 유실)", 동시 처리 4.
- 마이그레이션 002(컬럼 5개 + 부분 인덱스), `services/mock-forwarder`(장애 주입 4종), `services/worker`(폴러 1 + 처리기 N, channel, graceful shutdown), 지표 9종(`worker_`), compose·Prometheus 연결, `docs/architecture.md` 신설.

### AI 실수와 수정
- **설계 누락 → 라이브락**: 설계에 "임대 > HTTP 타임아웃" 불변식이 없었다. 검증 중 임대 1s·지연 2.5s 로 돌리자 매 틱 같은 행이 재claim 되어 모든 마무리 UPDATE 가 version 충돌(`worker_version_conflicts_total`=16)로 버려지고 행이 `parsed` 에 version 12 까지 머물렀다. 충돌 방침(덮어쓰지 않음)은 정확히 동작했으나 그 방침만으로는 진행이 보장되지 않는다. → 시작 시 `lease < 2×httpTimeout` 이면 경고 후 올리도록 수정. 교훈: **"충돌 시 어떻게 할지" 뿐 아니라 "충돌이 영원히 반복되지 않는 조건" 도 설계에 적어야 한다.**
- **Dockerfile 복제 실수**: booking-api Dockerfile 을 sed 로 복제하면서 `COPY --from=builder /out/worker /booking-api` 처럼 목적지 경로를 놓쳤다. ENTRYPOINT `/worker` 가 없어 컨테이너가 안 떴을 것. 빌드 전 grep 검토에서 발견해 수정.
- **검증 환경 착오(2건)**: (1) 이 WSL 배포판에는 Docker 통합이 꺼져 있어 `docker.exe` 를 직접 호출했는데, Windows 프로세스라 **WSL 셸 환경변수가 전달되지 않아** `FWD_FAIL_RATE=0.5 docker compose up` 이 장애를 주입하지 못했다. 지표에 `injected_fail` 이 0 인 것으로 알아채고 `--env-file` 로 전환. (2) 공백이 든 경로를 셸 변수에 넣어 `$PSQL` 이 깨졌다. 함수로 교체. 교훈: 장애 주입은 "주입됐다는 증거 지표(`forwarder_requests_total{outcome="injected_*"}`)" 를 먼저 확인한다.
- **OUT_OF_ORDER 가 거부 전이를 만들지 못함**: pull 모델에서는 confirmed 가 된 뒤 다시 조회하지 않으므로, 뒤늦은 `pending` 은 "아직 대기" 로 흡수되어 `worker_transition_rejected_total` 이 0 이었다. 전이 표는 임대 만료 후 이중 처리나 수동 조작에 대한 방어선이며, 단위 테스트(`store_test.go`)로 역행 거부를 검증했다. 포스트모템 때 이 한계를 그대로 적는다.

### 검증 결과
| 시나리오 | 결과 |
|---|---|
| 정상 | parsed→sent→confirmed, version 1→5, 4 타깃 up |
| FAIL_RATE 0.5, 10건 | 500 4회 → `worker_retries_total{send}`=4, 전부 confirmed, 최대 version 9 |
| DELAY 4s (타임아웃 3s) | `result="timeout"` 5회 → failed, `last_error`="max attempts (5) exceeded at send: timeout after 3s" |
| 종료 중 4건 in-flight, `compose stop` | 4건 모두 `transition applied` 후 "all workers drained" → "worker stopped". claimed_until 전부 NULL |
| 처리 중 수동 version+1 | "version conflict, result discarded" (expected 2 / actual 3), 덮어쓰기 없음, 다음 폴링에서 재처리 → confirmed (version 7) |
| 임대 1s 설정 | 경고 후 6000ms 로 상향 |

## 2026-10-18 — 2단계: Alertmanager 알림 규칙

### 한 일
- 설계 합의 후 규칙 10개(`infra/monitoring/alert-rules.yml`): critical 2(TargetDown, BookingProcessingStalled), warning 5, info 3. 디스크 규칙은 node_exporter 도입 때까지 주석.
- Alertmanager v0.28.1: severity 별 라우팅(critical 30s/1h, warning 2m/4h, info 는 `null` 수신자로 UI 전용), inhibition 3개, Discord 내장 통합(`webhook_url_file`). 웹훅 URL 은 compose `secrets`(environment 소스)로 `/run/secrets/` 파일 마운트 — 설정 파일·이미지·git 어디에도 안 남는다.
- `docs/runbook.md` 신설: 알림별 의미 → 먼저 볼 것 → 조치 → 해제 조건, 억제 표, silence 사용법.

### 설계 메모 (면접 대비)
- "처리 정체" 를 `parsed 가 줄지 않음` 이 아니라 `parsed 에서 나가는 전이가 0` 으로 정의했다. 전자는 유입이 계속되면 처리 중에도 울리고, 후자는 포워더 장애(결국 failed 전이 발생)와 worker 정지를 구분한다.
- 비율 규칙은 전부 `and on() 분모 > 0` 을 붙였다. 트래픽 0 일 때 0/0 = NaN 으로 규칙이 이상 동작하는 것을 막는다.
- 재시도 횟수 알림은 의도적으로 뺐다. ErrorRate 와 같은 원인을 두 번 알리면 알림 피로만 늘린다.

### AI 실수와 수정
- `amtool alert add` 로 테스트 알림을 보낼 때 한국어 annotation 을 따옴표 없이 넘겨 파서 경고가 났다(UTF-8 매처 파서는 값에 따옴표 필요). 알림 자체는 등록되어 Discord 발송은 성공(`alertmanager_notifications_total{integration="discord"}`=1, failed=0). 교훈: 발송 성공 여부는 로그가 아니라 **Alertmanager 자체 지표**로 확인한다(성공은 INFO 로그에 안 남는다).
- **장애 미주입(2번째)**: `.env` 가 줄바꿈 없이 끝나 있어서, `cat .env; printf 'FWD_FAIL_RATE=0.5\n'` 로 만든 override 파일에서 새 변수가 마지막 줄(웹훅 URL) 뒤에 붙어 무시됐다. 11분 훈련 동안 `worker_attempts_total` 이 전부 `ok` 인 것으로 발견. `.env` 끝에 줄바꿈을 보장(`sed -i -e '$a\'`)하고 재실행. 교훈: 설정 파일을 이어 붙일 때는 **합친 결과를 `compose config` 로 먼저 확인**한다 — 이번엔 `FAIL_RATE: "0"` 이 그대로 보였다.

### 검증 결과 (알림)
| 항목 | 결과 |
|---|---|
| `promtool check rules` / `amtool check-config` | 10 rules, 3 inhibit rules, 2 receivers 통과 |
| Prometheus → Alertmanager | activeAlertmanagers 1, 규칙 3그룹 로드 |
| amtool 테스트 알림 | Discord 발송 1 / 실패 0 |
| 훈련 1번 재현 (FAIL_RATE 0.5, 20초마다 5건, 11분) | 포워더 `injected_fail`=174. 약 7분 뒤 `ForwarderErrorRateHigh`(비율 0.30) firing, 30초 뒤 `FailedBookingsIncreasing` firing(50%에서 5연속 실패 확률 3% × 170건 ≈ 5건). Discord 발송 누계 5 / 실패 0 |
| 억제 | 두 알림이 다른 사실(원인 / 결과)이라 억제 대상이 아님. `inhibitedBy` 비어 있음 — 설계 의도대로 |
- **스크린샷 시계 어긋남**: "최근 1시간" 으로 찍은 Prometheus·Grafana 화면이 비어 있었다. 원인은 훈련 중 Docker Desktop VM 시계가 호스트(WSL/Windows)보다 약 5시간 40분 뒤처져 있었던 것 — 샘플이 02:2x UTC 로 기록됐는데 브라우저의 "지금" 은 08:0x 였다. 처음엔 Chrome 헤드리스의 가상 시간 옵션을 의심해 옵션을 바꿔가며 두 번 헛찍었다. `date -u` 를 호스트와 컨테이너에서 나란히 찍어 확인한 뒤 구간을 명시해 해결. 교훈: **그래프가 비면 쿼리보다 먼저 시계를 의심한다.** 운영에서 이건 알림 시각이 통째로 어긋나는 문제이므로, 3단계 VM 에서는 시간 동기화(chrony) 점검을 healthcheck.sh 에 넣는다.
- **설정 자동 보정의 가시성**: 임대 하한 보정이 로그 WARN 한 줄에만 남아 알림으로 이어지지 않았다. `worker_config_adjusted{setting}` Gauge(정상 0 명시)를 추가하고 info 규칙 `ConfigAdjusted` 를 걸었다. 위반 설정(임대 1000ms)으로 기동하면 1, 정상 설정으로 재기동하면 0 으로 돌아오는 것을 확인.
- **알림 설계 가정 오류(검증으로 발견)**: 포스트모템에 "라이브락은 BookingProcessingStalled 가 잡는다" 고 적었지만, 재현 훈련에서 12분 49초 동안 한 번도 울리지 않았다. 새 프로세스는 전이 카운터 시계열이 아예 없어(absent) `and` 가 빈 결과가 되기 때문. Discord 에 온 것은 부수 증상인 ForwarderLatencyHigh 뿐. 교훈: **알림 규칙은 "울릴 것이다" 가 아니라 실제 장애를 주입해 도착 시간을 재야 한다.** 그리고 Counter 기반 "0 이면 이상" 규칙은 반드시 absent 를 함께 다뤄야 한다(`or vector(0)`, 또는 시작 시 0 으로 선등록). 상세와 후속 제안은 포스트모템 "감지 방법" 절.
- **빈 벡터 수정과 재검증**: 규칙 `or vector(0)` + 억제 규칙 + worker 전이 지표 0 선등록 적용. 재검증 2회차(지연 1.5s)는 라이브락이 유지되지 않아 무효였다 — 임대 만료 후 "첫 폴링 틱(1s)" 에야 재claim 되므로 호출 1.5s 가 그 전에 끝났다. 복제본 폴링을 250ms 로 줄여 3회차에서 재현. **Stalled pending +46s, firing +2m47s, Discord +3m18s.** 포워더 지연 warning 은 p95 1.95s 로 침묵해 Stalled 단독으로 도착했음을 확인. 새 포스트모템 `docs/postmortems/2026-10-18-alert-empty-vector.md`.
