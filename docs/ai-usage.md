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
| **실제 키로 파싱 성공 경로** | **미검증** — 작업자가 `.env`에 키를 넣은 뒤 확인 필요 |

### 추가 (같은 날) — 실제 키 테스트에서 400, 로그 설계 실수 발견
- **증상**: 실제 키를 넣고 호출하자 Claude API가 400. `review_reason=claude_error`로 폴백은 정상 동작했지만 원인을 알 수 없었다.
- **로그 설계 실수(AI)**: "키가 섞여 들어갈 수 있다"는 이유로 API 에러 로그에 `status`와 `request_id`만 남기게 했다.
  그 결과 장애 원인 파악에 curl로 **재현**이 필요했다. SDK 소스를 확인하니 `apiErr.Error()`는 메서드·URL·상태·요청ID·응답 본문만 담고
  요청 헤더(키)는 포함하지 않아 로그에 남겨도 안전했다. → 에러 메시지를 로그에 포함하도록 수정.
  교훈: **비밀값 보호와 진단 가능성은 상충하지 않는다. 무엇이 비밀인지 정확히 확인하고 그것만 가린다.**
- **실제 원인**: 발급한 키가 특정 워크스페이스에 묶이지 않은 조직 범위 키여서 `anthropic-workspace-id` 헤더가 필요했다.
  코드에 `ANTHROPIC_WORKSPACE_ID`(선택) 지원을 추가. 권장은 **워크스페이스 범위 키를 새로 발급**하는 것 — 최소 권한 원칙에도 맞고 헤더가 필요 없다.
