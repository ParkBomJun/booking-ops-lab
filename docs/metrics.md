# 지표 설계

타입 선택 기준: **Counter** = 늘어나기만 하는 값, `rate()`로 변화율을 본다 / **Gauge** = 오르내리는 현재 값 / **Histogram** = 분포, p95를 본다. Summary는 인스턴스 간 합산이 불가능해 쓰지 않는다.

| # | 지표 | 타입 | 라벨 | 잡는 장애 |
|---|---|---|---|---|
| 1 | `booking_http_requests_total` | Counter | method, route, status | 에러율 급증(5xx 비율), 트래픽 급변. 에러율은 별도 지표가 아니라 status 라벨로 같은 Counter에서 계산 |
| 2 | `booking_http_request_duration_seconds` | Histogram | route | 에러 없이 느려지는 상황. 버킷 0.01~10s는 DB만/Claude 경유/타임아웃 구간이 구분되도록 |
| 3 | `booking_processed_total` | Counter | result=parsed\|needs_review\|duplicate | **장애 훈련 2번** 핵심 감지. HTTP 201이라 1번으로는 안 보임. duplicate는 **훈련 3번** 멱등성 증거 |
| 4 | `booking_needs_review_count`, `booking_status_count` | Gauge | (status) | 검토 대기함 적체. 3번은 유입 속도, 4번은 적체량. 스크레이프 시점에 DB 조회(Collector) |
| 5 | `booking_claude_requests_total` | Counter | result=ok\|claude_timeout\|claude_error\|invalid_json\|validation_failed | 외부 의존성 장애의 종류 구분. 라벨 값은 `parser.go` 상수 |
| 6 | `booking_claude_request_duration_seconds` | Histogram | - | 타임아웃 직전까지 느려지는 조용한 악화. p95 > 8s면 타임아웃 폭증 선행 신호 |
| 7 | `booking_claude_tokens_total` | Counter | type=input\|output\|cache_read, model | 비용 폭주. cache_read=0이면 프롬프트 캐시 미적중 |

## 라우트 라벨 규칙
- `route`는 실제 경로가 아니라 **ServeMux 패턴**(`/bookings/{id}`). 실제 ID를 넣으면 시계열이 무한히 늘어난다(카디널리티 폭발).
- 등록되지 않은 라우트(404/405)는 전부 `route="unknown"`. 스캐너가 `/admin`, `/.env`를 두드려도 시계열이 늘지 않는다.
- 패턴 추출 원리: `ServeMux.ServeHTTP`가 `r.Pattern`에 매칭 패턴을 기록하고(미매칭이면 빈 문자열), 미들웨어는 `next.ServeHTTP` 이후 같은 `*Request`에서 읽는다. `metrics.go`의 `metricsMiddleware` 참고.

## Prometheus 쪽 방어
- `sample_limit: 1000` — 한 스크레이프의 샘플 상한. 초과 시 그 스크레이프를 통째로 버리고 `up=0`이 된다. 현재 정상 샘플 수는 약 130.
- `scrape_timeout: 10s` < `scrape_interval: 15s`.

## 로그 규칙
- 요청 범위의 모든 로그 줄에 `booking_id`(= 클라이언트가 보낸 `Idempotency-Key`)가 붙는다. DB 숫자 id는 저장 후에야 생기므로 `row_id`로 별도 기록한다.
- 구현: 핸들러가 `slog.With("booking_id", key)`를 `context`에 넣고, parser/store는 `logFrom(ctx)`로 꺼내 쓴다.
- 시작·마이그레이션 로그처럼 요청 밖의 줄은 `booking_id`가 없다.

## worker 지표 (`worker_` 접두어)

| 지표 | 타입 | 라벨 | 잡는 것 |
|---|---|---|---|
| `worker_attempts_total` | Counter | stage=send\|confirm, result=ok\|duplicate\|timeout\|conn_error\|http_5xx\|http_4xx\|pending | **훈련 1번 1차 감지.** result≠ok 비율. 라벨 값은 `forwarder.go` 의 `Result*` 상수 |
| `worker_retries_total` | Counter | stage | 재시도 예약 횟수. 폭증 알림 대상 |
| `worker_forwarder_request_duration_seconds` | Histogram | stage | 버킷 0.05~5s. 타임아웃 3s 직전 구간 구분 |
| `worker_transitions_total` | Counter | from, to | 적용된 상태 전이 |
| `worker_transition_rejected_total` | Counter | from, to | 역행 차단 증거 (OUT_OF_ORDER 훈련) |
| `worker_version_conflicts_total` | Counter | | 낙관적 잠금 충돌. 0 이 정상 |
| `worker_inflight` | Gauge | | 처리 중 건수 |
| `worker_backlog_count` | Gauge(Collector) | status=parsed\|sent | **지금 집어갈 수 있는** 행 수. `booking_status_count` 와 달리 `next_attempt_at` 이 지난 것만 |
| `worker_oldest_eligible_age_seconds` | Gauge(Collector) | | 가장 오래 기다린 건의 나이. 처리 지연 |
| `worker_config_adjusted` | Gauge | setting=lease_ms | 시작 시 설정 자동 보정 여부(0/1). ConfigAdjusted(info) 알림 |

실패함 건수는 기존 `booking_status_count{status="failed"}` 를 쓴다 (중복 노출 안 함).

## mock-forwarder 지표 (`forwarder_` 접두어)
- `forwarder_requests_total{route, outcome}`: outcome=ok|duplicate|injected_fail|injected_dup|not_found|bad_request. 주입한 장애가 실제로 발동했는지 증명하는 용도.
- `forwarder_bookings_stored`: 메모리에 보관 중인 건수.

## worker 로그 규칙
- 모든 처리 로그에 `booking_id`(멱등키), `row_id`, `attempt`, `stage`(send|confirm), `result`, `duration_ms`.
- 전이 적용 시 `from`, `to`, `version`. version 충돌 시 `expected_version`, `actual_version`, `actual_status`.

## 장애 훈련 ↔ 지표
| 훈련 | 1차 감지 | 원인 분석 |
|---|---|---|
| 1. 포워더 실패율 50% | `worker_attempts_total{result!="ok"}` 비율, `worker_retries_total` 급증 | `forwarder_requests_total{outcome="injected_fail"}`, `worker_backlog_count`, `booking_status_count{status="failed"}` |
| 2. Claude 타임아웃 | 3번 needs_review 유입 급증 | 5번 claude_timeout 비율, 6번 p95 |
| 3. 중복 전송 | 3번 duplicate 증가, 4번 변화 없음 | DB 행 수 불변 |
| 4. 잘못된 배포 | /healthz 실패 (CD) | 1번 5xx 비율 |

## 알림 규칙 ↔ 지표
규칙 파일 `infra/monitoring/alert-rules.yml`, 대응 절차 `docs/runbook.md`.

| 규칙 | severity | 지표 | 훈련 |
|---|---|---|---|
| TargetDown | critical | `up` | 4 |
| BookingProcessingStalled | critical | `booking_status_count{parsed}` + `worker_transitions_total{from="parsed"}` | 처리 정체 |
| ForwarderErrorRateHigh | warning | `worker_attempts_total` result 비율 | 1 |
| ForwarderLatencyHigh | warning | `worker_forwarder_request_duration_seconds` p95 | 1 변형 |
| FailedBookingsIncreasing | warning | `booking_status_count{failed}` delta | 1 결과 |
| NeedsReviewRatioHigh | warning | `booking_processed_total` result 비율 | 2 |
| HttpErrorRateHigh | warning | `booking_http_requests_total` 5xx 비율 | 일반 |
| BacklogAging / VersionConflictsObserved / ConfigAdjusted / NeedsReviewBacklog | info | `worker_oldest_eligible_age_seconds` / `worker_version_conflicts_total` / `booking_needs_review_count` | 선행·기록 |

## 로컬 접속
- Prometheus: http://localhost:9090 (Status → Targets에서 booking-api up 확인)
- Alertmanager: http://localhost:9093 (firing 알림, inhibited 표시, silence, info 등급은 여기서만)
- Grafana: http://localhost:3000 (admin / `.env`의 `GRAFANA_ADMIN_PASSWORD`) → Booking Ops 폴더 → "Booking API — 서비스 지표"
- 장애 재현: `CLAUDE_TIMEOUT_MS=1 docker compose up -d booking-api` 후 요청 몇 건 → 3번·5번 패널이 튄다
