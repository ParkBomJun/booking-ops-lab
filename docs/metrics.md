# 지표 설계 (booking-api)

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

## 장애 훈련 ↔ 지표
| 훈련 | 1차 감지 | 원인 분석 |
|---|---|---|
| 2. Claude 타임아웃 | 3번 needs_review 유입 급증 | 5번 claude_timeout 비율, 6번 p95 |
| 3. 중복 전송 | 3번 duplicate 증가, 4번 변화 없음 | DB 행 수 불변 |
| 4. 잘못된 배포 | /healthz 실패 (CD) | 1번 5xx 비율 |

## 로컬 접속
- Prometheus: http://localhost:9090 (Status → Targets에서 booking-api up 확인)
- Grafana: http://localhost:3000 (admin / `.env`의 `GRAFANA_ADMIN_PASSWORD`) → Booking Ops 폴더 → "Booking API — 서비스 지표"
- 장애 재현: `CLAUDE_TIMEOUT_MS=1 docker compose up -d booking-api` 후 요청 몇 건 → 3번·5번 패널이 튄다
