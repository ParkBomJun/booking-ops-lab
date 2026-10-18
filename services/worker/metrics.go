package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// ---- worker 지표. 전부 worker_ 접두어 (docs/metrics.md 설계 그대로) ----

var (
	// 1. 포워더 호출 시도 결과. 장애 훈련 1번의 1차 감지: result != "ok" 비율.
	attemptsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "worker_attempts_total",
		Help: "Forwarder call attempts by stage (send, confirm) and result.",
	}, []string{"stage", "result"})

	// 2. 재시도 예약 횟수. 백오프로 next_attempt_at 을 미룰 때마다 1.
	retriesTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "worker_retries_total",
		Help: "Retries scheduled (attempt failed, will try again later) by stage.",
	}, []string{"stage"})

	// 3. 포워더 호출 지연시간. 타임아웃 3s 바로 아래 구간을 촘촘하게.
	forwarderDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "worker_forwarder_request_duration_seconds",
		Help:    "Forwarder HTTP call latency by stage.",
		Buckets: []float64{0.05, 0.1, 0.25, 0.5, 1, 2, 3, 5},
	}, []string{"stage"})

	// 4. 적용된 상태 전이.
	transitionsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "worker_transitions_total",
		Help: "Booking status transitions applied.",
	}, []string{"from", "to"})

	// 5. 거부된 전이 (역행 방지 증거). 예: confirmed -> sent.
	transitionRejected = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "worker_transition_rejected_total",
		Help: "Status transitions rejected by the transition table.",
	}, []string{"from", "to"})

	// 6. 낙관적 잠금 충돌. 0이 정상. 올라가면 임대 만료 후 이중 처리가 있었다는 뜻.
	versionConflicts = promauto.NewCounter(prometheus.CounterOpts{
		Name: "worker_version_conflicts_total",
		Help: "Writes skipped because the row version changed under us.",
	})

	// 7. 처리 중 건수. 올리고 내리는 값이라 Gauge.
	inflight = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "worker_inflight",
		Help: "Bookings currently being processed by a worker goroutine.",
	})
)

// ---- 8·9. 적체 지표: 스크레이프 시점에 DB 조회 (booking-api 의 dbCollector 와 같은 방식) ----

type backlogCollector struct {
	db      *pgxpool.Pool
	backlog *prometheus.Desc
	oldest  *prometheus.Desc
}

func newBacklogCollector(db *pgxpool.Pool) *backlogCollector {
	return &backlogCollector{
		db: db,
		// 지금 당장 집어갈 수 있는 행 수. booking_status_count 와 다른 점: next_attempt_at 이 지난 것만 센다.
		backlog: prometheus.NewDesc("worker_backlog_count",
			"Rows eligible for processing right now, by status.", []string{"status"}, nil),
		// 가장 오래 기다린 건의 나이(초). 처리 지연을 한 숫자로 본다.
		oldest: prometheus.NewDesc("worker_oldest_eligible_age_seconds",
			"Age of the oldest row eligible for processing.", nil, nil),
	}
}

func (c *backlogCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.backlog
	ch <- c.oldest
}

func (c *backlogCollector) Collect(ch chan<- prometheus.Metric) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	rows, err := c.db.Query(ctx, `
		SELECT status, count(*), extract(epoch FROM now() - min(next_attempt_at))
		  FROM bookings
		 WHERE status IN ('parsed','sent') AND next_attempt_at <= now()
		   AND (claimed_until IS NULL OR claimed_until < now())
		 GROUP BY status`)
	if err != nil {
		slog.Warn("metrics db query failed", "err", err.Error())
		return
	}
	defer rows.Close()

	counts := map[string]float64{"parsed": 0, "sent": 0} // 0 도 내보내야 그래프가 끊기지 않는다
	var oldest float64
	for rows.Next() {
		var status string
		var n int64
		var age float64
		if err := rows.Scan(&status, &n, &age); err != nil {
			return
		}
		counts[status] = float64(n)
		if age > oldest {
			oldest = age
		}
	}
	for status, n := range counts {
		ch <- prometheus.MustNewConstMetric(c.backlog, prometheus.GaugeValue, n, status)
	}
	ch <- prometheus.MustNewConstMetric(c.oldest, prometheus.GaugeValue, oldest)
}
