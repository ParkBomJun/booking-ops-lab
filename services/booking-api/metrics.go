package main

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto" // 생성과 동시에 기본 레지스트리에 등록
)

// ---- 지표 정의 (docs/metrics 설계 그대로) ----
// promauto.New* 는 만들면서 기본 레지스트리에 등록한다. 이름이 중복되면 시작 시 패닉 -> 오타를 빨리 잡는다.

var (
	// 1. HTTP 요청 수. 에러율은 status 라벨로 같은 Counter 에서 뽑는다.
	httpRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "booking_http_requests_total",
		Help: "HTTP requests by method, route pattern and status code.",
	}, []string{"method", "route", "status"})

	// 2. HTTP 지연시간. 평균이 아니라 p95 를 보기 위한 Histogram.
	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "booking_http_request_duration_seconds",
		Help:    "HTTP request latency by route pattern.",
		Buckets: []float64{0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}, // DB only / Claude 경유 / 타임아웃 구간이 구분되게
	}, []string{"route"})

	// 3. 부킹 처리 결과. HTTP 는 201 로 정상이어도 needs_review 급증을 잡는다 (장애 훈련 2번).
	processedTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "booking_processed_total",
		Help: "Bookings processed by result: parsed, needs_review, duplicate.",
	}, []string{"result"})

	// 5. Claude 호출 결과. 라벨 값은 parser.go 의 Reason* 상수와 "ok".
	claudeRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "booking_claude_requests_total",
		Help: "Claude API calls by result.",
	}, []string{"result"})

	// 6. Claude 호출 지연시간. 타임아웃(10s) 직전 구간을 촘촘하게.
	claudeDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "booking_claude_request_duration_seconds",
		Help:    "Claude API call latency.",
		Buckets: []float64{0.25, 0.5, 1, 2, 3, 5, 8, 10},
	})

	// 7. Claude 토큰 사용량. 비용 폭주 감지 + cache_read 로 캐시 적중 확인.
	claudeTokensTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "booking_claude_tokens_total",
		Help: "Claude tokens consumed by type (input, output, cache_read) and model.",
	}, []string{"type", "model"})
)

// ---- 4. 검토 대기함 / 상태별 건수 (Gauge, 스크레이프 시점에 DB 조회) ----

// dbCollector: Prometheus 가 /metrics 를 긁을 때마다 Collect 가 호출된다.
// 요청마다 Gauge 를 갱신하는 대신 "그 순간의 진짜 값" 을 DB 에서 읽는다.
// 재시작해도 값이 0 으로 리셋되지 않고, 여러 인스턴스가 떠도 같은 값을 보여준다는 장점이 있다.
type dbCollector struct {
	db          *pgxpool.Pool
	needsReview *prometheus.Desc
	statusCount *prometheus.Desc
}

func newDBCollector(db *pgxpool.Pool) *dbCollector {
	return &dbCollector{
		db: db,
		needsReview: prometheus.NewDesc("booking_needs_review_count",
			"Bookings currently waiting for human review.", nil, nil),
		statusCount: prometheus.NewDesc("booking_status_count",
			"Bookings by current status.", []string{"status"}, nil),
	}
}

// Describe: 이 Collector 가 내보낼 지표의 "설명서" 를 등록 시점에 알려준다.
func (c *dbCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.needsReview
	ch <- c.statusCount
}

// Collect: 스크레이프마다 호출. DB 가 느려도 스크레이프 전체가 멈추지 않도록 2초 제한.
func (c *dbCollector) Collect(ch chan<- prometheus.Metric) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	rows, err := c.db.Query(ctx, `SELECT status, count(*) FROM bookings GROUP BY status`)
	if err != nil {
		// 지표 수집 실패는 서비스 장애가 아니다. 로그만 남기고 이번 스크레이프에서 이 지표를 빼면
		// Prometheus 쪽에서는 "값이 없음(absent)" 으로 보여 알림 규칙으로 잡을 수 있다.
		slog.Warn("metrics db query failed", "booking_id", "-", "err", err.Error())
		return
	}
	defer rows.Close()

	var needsReview float64
	for rows.Next() {
		var status string
		var n int64
		if err := rows.Scan(&status, &n); err != nil {
			return
		}
		ch <- prometheus.MustNewConstMetric(c.statusCount, prometheus.GaugeValue, float64(n), status)
		if status == "needs_review" {
			needsReview = float64(n)
		}
	}
	ch <- prometheus.MustNewConstMetric(c.needsReview, prometheus.GaugeValue, needsReview)
}

// ---- HTTP 미들웨어 (1·2번 지표) ----

// statusWriter: http.ResponseWriter 를 감싸 응답 코드를 기억한다.
// 표준 ResponseWriter 에는 "무슨 코드를 썼는지" 를 다시 읽는 방법이 없기 때문이다.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// metricsMiddleware: 모든 요청을 감싼다.
//
// 라우트 패턴을 꺼내는 원리:
//   - 이 미들웨어는 mux "바깥" 에 있으므로 next.ServeHTTP 호출 전에는 어떤 핸들러가 맞을지 모른다.
//   - next(=ServeMux).ServeHTTP 는 내부에서 findHandler 를 실행하며 결과를 r.Pattern 에 기록한다.
//     (net/http/server.go: `h, r.Pattern, r.pat, r.matches = mux.findHandler(r)`)
//   - r 은 포인터라 같은 객체를 우리도 들고 있다 -> next 가 끝난 뒤 r.Pattern 을 읽으면 된다.
//   - 매칭 실패(404/405) 면 Pattern 이 "" 이다 -> "unknown" 으로 묶어 카디널리티 폭발을 막는다.
//     (실제 요청 경로를 라벨에 넣으면 스캐너가 /admin, /.env ... 를 두드릴 때마다 시계열이 늘어난다)
func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK} // WriteHeader 를 안 부르면 200
		next.ServeHTTP(sw, r)

		route := "unknown"
		if r.Pattern != "" {
			// 패턴은 "GET /bookings/{id}" 형태. method 는 별도 라벨이 있으니 경로만 남긴다.
			if _, path, ok := strings.Cut(r.Pattern, " "); ok {
				route = path
			} else {
				route = r.Pattern
			}
		}

		httpRequestsTotal.WithLabelValues(r.Method, route, strconv.Itoa(sw.status)).Inc()
		httpDuration.WithLabelValues(route).Observe(time.Since(start).Seconds())
	})
}
