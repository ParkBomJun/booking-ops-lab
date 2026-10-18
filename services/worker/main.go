// Package main: worker. DB 에서 parsed/sent 부킹을 집어가 모의 포워더에 전송·확인한다.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal" // OS 신호(SIGTERM 등)를 받기 위한 표준 패키지
	"strconv"
	"sync"      // WaitGroup: 여러 goroutine 이 끝나길 기다리는 도구
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// config: 전부 환경변수에서. 기본값은 docs/architecture.md 의 설계값.
type config struct {
	pollInterval time.Duration
	concurrency  int
	httpTimeout  time.Duration
	maxAttempts  int
	backoffBase  time.Duration
	backoffMax   time.Duration
	lease        time.Duration
	confirmAfter time.Duration // sent 전이 후 첫 상태 조회까지 대기
}

type worker struct {
	cfg      config
	store    *Store
	fwd      *Forwarder
	lastPoll atomic.Int64 // 마지막 폴링 성공 시각(unix nano). 여러 goroutine 이 읽고 쓰므로 atomic
}

// ---- 폴러 + 처리기 ----

// run: 전체 수명. ctx 가 취소되면(SIGTERM) 깨끗하게 내려간다.
//
// 구조:
//
//	[poller goroutine] --claim--> DB
//	        │  jobs chan (버퍼 = concurrency)
//	        ▼
//	[worker goroutine] x N  --HTTP--> forwarder, --UPDATE--> DB
//
// channel 이 "한 건을 정확히 한 goroutine 에만" 전달하는 원리:
//   - Go 의 channel 은 큐다. 값을 보내면(jobs <- b) 한 번 저장되고, 받으면(<-jobs) 큐에서 꺼내진다.
//   - N 개의 goroutine 이 같은 channel 에서 `for b := range jobs` 로 받고 있을 때,
//     런타임이 수신 대기 중인 goroutine 중 하나만 깨워 값을 넘긴다. 복사본이 아니라 "꺼내기" 이므로
//     두 goroutine 이 같은 값을 받을 수 없다. 이 보장은 런타임 내부 락이 해주며 우리가 뮤텍스를 쓸 필요가 없다.
//   - 그래서 "집어온 행을 누가 처리하느냐" 를 조정하는 코드가 전혀 없다. 먼저 손 든 goroutine 이 가져간다.
//   - 버퍼 크기 N: 폴러가 N 건까지는 기다리지 않고 넣는다. N 건이 차 있으면 폴러가 멈춰 기다린다.
//     이것이 자연스러운 배압(backpressure) 이다. 포워더가 느려지면 폴러도 느려지고 DB 에서 더 안 집어간다.
func (w *worker) run(ctx context.Context) {
	jobs := make(chan Booking, w.cfg.concurrency)
	var wg sync.WaitGroup

	// 처리기 N 개. 각자 channel 에서 한 건씩 받아 처리한다.
	for i := 0; i < w.cfg.concurrency; i++ {
		wg.Add(1) // "기다릴 goroutine 이 하나 더 있다"
		go func(id int) {
			defer wg.Done() // 이 goroutine 이 끝날 때 "하나 끝났다"
			// range 는 channel 이 close 되고 버퍼까지 비면 자동으로 끝난다.
			// -> 종료 신호를 따로 보낼 필요가 없다. close(jobs) 하나가 N 개 모두에게 전달된다.
			for b := range jobs {
				w.process(b)
			}
			slog.Info("worker goroutine exited", "worker", id)
		}(i)
	}

	ticker := time.NewTicker(w.cfg.pollInterval)
	defer ticker.Stop()

	// 폴러는 run 을 호출한 goroutine(main) 에서 직접 돈다.
	for {
		select {
		case <-ctx.Done():
			// ---- graceful shutdown 순서 ----
			// 1. 여기 도달 = SIGTERM. 더는 DB 에서 집어오지 않는다 (아래 claim 코드가 더 실행되지 않음).
			// 2. close(jobs): 버퍼에 남은 건은 처리기들이 계속 꺼내 가고, 비면 range 가 끝나 goroutine 이 종료한다.
			//    close 는 반드시 "보내는 쪽" 이 한다. 받는 쪽이 닫으면 폴러가 닫힌 channel 에 보내다 패닉한다.
			// 3. wg.Wait(): N 개가 전부 Done 할 때까지 막힌다. 진행 중인 HTTP 호출(최대 3초)과 그 결과 UPDATE 가 끝난다.
			//    process 는 shutdown ctx 가 아니라 자체 타임아웃을 쓰므로 종료 신호에 중간에 끊기지 않는다.
			//    즉 "포워더엔 보냈는데 DB 엔 sent 라고 못 쓴" 반쪽 상태로 죽지 않는다.
			// 4. 돌아가면 main 이 HTTP 서버와 DB 풀을 닫는다.
			close(jobs)
			wg.Wait()
			slog.Info("all workers drained")
			return

		case <-ticker.C:
			claimCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			claimed, err := w.store.Claim(claimCtx, w.cfg.concurrency, w.cfg.lease)
			cancel()
			if err != nil {
				slog.Error("claim failed", "err", err.Error())
				continue // DB 가 잠깐 죽어도 폴러는 죽지 않는다. 다음 틱에 다시 시도.
			}
			w.lastPoll.Store(time.Now().UnixNano())
			for _, b := range claimed {
				// 버퍼가 꽉 차 있으면 여기서 기다린다. 그 사이 SIGTERM 이 오면 대기 중인 행은 그냥 버린다.
				// 임대(claimed_until)가 만료되면 다음 기동 때 다시 집히므로 유실이 아니다.
				select {
				case jobs <- b:
				case <-ctx.Done():
				}
			}
		}
	}
}

// process: 한 건 처리. 상태에 따라 send 또는 confirm.
// shutdown ctx 를 받지 않는 것이 의도다. 시작한 건은 자체 타임아웃 안에서 끝까지 간다.
func (w *worker) process(b Booking) {
	inflight.Inc()
	defer inflight.Dec()

	ctx := withLogger(context.Background(), slog.With("booking_id", b.Key, "row_id", b.ID, "attempt", b.Attempts+1))
	start := time.Now()

	switch b.Status {
	case "parsed":
		w.send(ctx, &b)
	case "sent":
		w.confirm(ctx, &b)
	default:
		logFrom(ctx).Error("claimed row in unexpected status", "status", b.Status) // Claim 쿼리가 막아주지만 방어
	}
	logFrom(ctx).Info("processed", "stage", b.Status, "duration_ms", time.Since(start).Milliseconds())
}

// send: parsed -> sent | failed | (재시도)
func (w *worker) send(ctx context.Context, b *Booking) {
	ref, result, detail := w.fwd.Send(ctx, b.Key, b.Parsed)
	attemptsTotal.WithLabelValues("send", result).Inc()
	log := logFrom(ctx).With("stage", "send", "result", result)

	switch {
	case result == ResultOK || result == ResultDuplicate:
		log.Info("forwarder accepted", "ref", ref)
		// 다음 단계(confirm) 의 첫 조회 시각을 예약한다.
		w.finish(ctx, b, "sent", time.Now().Add(w.cfg.confirmAfter), &ref, nil)
	case retryable(result):
		w.retryOrFail(ctx, b, "send", detail)
	default: // 4xx: 반복해도 같다. 즉시 실패함.
		log.Warn("non-retryable failure", "detail", detail)
		w.finish(ctx, b, "failed", time.Now(), nil, &detail)
	}
}

// confirm: sent -> confirmed | failed | (재조회)
func (w *worker) confirm(ctx context.Context, b *Booking) {
	if b.ForwarderRef == nil {
		detail := "sent without forwarder_ref" // 데이터 불일치. 재시도해도 해결되지 않는다.
		w.finish(ctx, b, "failed", time.Now(), nil, &detail)
		return
	}
	state, result, detail := w.fwd.Status(ctx, *b.ForwarderRef)
	if result == ResultOK && state == "pending" {
		result = ResultPending
	}
	attemptsTotal.WithLabelValues("confirm", result).Inc()
	log := logFrom(ctx).With("stage", "confirm", "result", result, "forwarder_state", state)

	switch {
	case result == ResultOK && state == "confirmed":
		w.finish(ctx, b, "confirmed", time.Now(), nil, nil)
	case result == ResultOK && state == "rejected":
		detail := "rejected by forwarder"
		w.finish(ctx, b, "failed", time.Now(), nil, &detail)
	case result == ResultOK:
		// 모르는 상태 문자열. 포워더 쪽 계약 위반이므로 재시도 대상으로 둔다.
		w.retryOrFail(ctx, b, "confirm", "unknown forwarder state: "+state)
	case retryable(result):
		if result == ResultPending {
			detail = "still pending"
		}
		w.retryOrFail(ctx, b, "confirm", detail)
	default:
		log.Warn("non-retryable failure", "detail", detail)
		w.finish(ctx, b, "failed", time.Now(), nil, &detail)
	}
}

// retryOrFail: 재시도 예산이 남았으면 백오프 예약, 아니면 failed.
func (w *worker) retryOrFail(ctx context.Context, b *Booking, stage, detail string) {
	nextAttempt := b.Attempts + 1 // 지금 실패한 것까지 포함한 시도 수
	if nextAttempt >= w.cfg.maxAttempts {
		msg := "max attempts (" + strconv.Itoa(w.cfg.maxAttempts) + ") exceeded at " + stage + ": " + detail
		logFrom(ctx).Error("giving up", "stage", stage, "detail", detail)
		w.finish(ctx, b, "failed", time.Now(), nil, &msg)
		return
	}
	delay := w.backoff(nextAttempt)
	retriesTotal.WithLabelValues(stage).Inc()
	logFrom(ctx).Warn("retry scheduled", "stage", stage, "detail", detail, "retry_in_ms", delay.Milliseconds())
	if err := w.store.Reschedule(ctx, b, time.Now().Add(delay), detail); err != nil && !errors.Is(err, ErrVersionConflict) {
		logFrom(ctx).Error("reschedule failed", "err", err.Error())
	}
	// ErrVersionConflict 는 store 가 이미 로그·지표를 남겼다. 여기서는 추가로 할 일이 없다 (방침: 덮어쓰지 않음).
}

// finish: 상태 전이 + 에러 처리 공통부.
func (w *worker) finish(ctx context.Context, b *Booking, to string, nextAt time.Time, ref *string, lastErr *string) {
	err := w.store.Transition(ctx, b, to, nextAt, ref, lastErr)
	switch {
	case err == nil, errors.Is(err, ErrVersionConflict), errors.Is(err, ErrTransitionRejected):
		// 세 경우 모두 store 가 로그·지표를 남겼고, 더 할 일이 없다.
	default:
		logFrom(ctx).Error("transition failed", "to", to, "err", err.Error())
	}
}

// backoff: base * 2^(attempt-1), 상한 backoffMax, ±20% 지터.
// 지터를 두는 이유: 포워더가 잠깐 죽었다 살아날 때 모든 재시도가 같은 순간에 몰리는(thundering herd) 것을 막는다.
func (w *worker) backoff(attempt int) time.Duration {
	d := w.cfg.backoffBase << (attempt - 1) // 1s, 2s, 4s, 8s, 16s ...
	if d > w.cfg.backoffMax || d <= 0 {       // <=0 은 시프트 오버플로 방어
		d = w.cfg.backoffMax
	}
	jitter := 0.8 + rand.Float64()*0.4 // 0.8 ~ 1.2
	return time.Duration(float64(d) * jitter)
}

// ---- /healthz ----

// healthz: DB 와 "폴러가 살아 있는가" 두 가지. 포워더 장애는 worker 장애가 아니므로 포함하지 않는다.
func (w *worker) healthz(db *pgxpool.Pool) http.HandlerFunc {
	return func(rw http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		checks := map[string]string{"db": "ok", "poller": "ok"}
		status := http.StatusOK
		if err := db.Ping(ctx); err != nil {
			checks["db"] = "fail: " + err.Error()
			status = http.StatusServiceUnavailable
		}
		// 마지막 폴링 성공이 3틱 이상 전이면 폴러가 멈춘 것으로 본다.
		if last := w.lastPoll.Load(); last == 0 || time.Since(time.Unix(0, last)) > 3*w.cfg.pollInterval {
			checks["poller"] = "stale"
			status = http.StatusServiceUnavailable
		}
		rw.Header().Set("Content-Type", "application/json")
		rw.WriteHeader(status)
		json.NewEncoder(rw).Encode(map[string]any{"status": map[bool]string{true: "ok", false: "degraded"}[status == 200], "checks": checks}) //nolint:errcheck
	}
}

// ---- 설정 ----

func envDur(key string, defMs int) time.Duration {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil && v > 0 {
		return time.Duration(v) * time.Millisecond
	}
	return time.Duration(defMs) * time.Millisecond
}
func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil && v > 0 {
		return v
	}
	return def
}
func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		slog.Error("required environment variable is missing", "key", key)
		os.Exit(1)
	}
	return v
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	cfg := config{
		pollInterval: envDur("WORKER_POLL_INTERVAL_MS", 1000),
		concurrency:  envInt("WORKER_CONCURRENCY", 4),
		httpTimeout:  envDur("WORKER_HTTP_TIMEOUT_MS", 3000),
		maxAttempts:  envInt("WORKER_MAX_ATTEMPTS", 5),
		backoffBase:  envDur("WORKER_BACKOFF_BASE_MS", 1000),
		backoffMax:   envDur("WORKER_BACKOFF_MAX_MS", 30000),
		lease:        envDur("WORKER_LEASE_MS", 60000),
		confirmAfter: envDur("WORKER_CONFIRM_AFTER_MS", 5000),
	}
	// 불변식: 임대 > HTTP 타임아웃 (+ DB 쓰기 여유). 임대가 호출보다 먼저 만료되면 매 틱마다 같은 행이 재claim 되고
	// 모든 마무리 쓰기가 version 충돌로 버려져 행이 영원히 끝나지 않는다 (검증 중 실제로 재현된 라이브락).
	// 잘못된 설정은 조용히 받아들이지 않고 안전한 값으로 올린 뒤 경고를 남긴다.
	configAdjusted.WithLabelValues("lease_ms").Set(0) // 기본값 0 을 먼저 내보낸다
	if minLease := 2 * cfg.httpTimeout; cfg.lease < minLease {
		slog.Warn("WORKER_LEASE_MS too short for WORKER_HTTP_TIMEOUT_MS; raising",
			"configured_ms", cfg.lease.Milliseconds(), "raised_to_ms", minLease.Milliseconds())
		cfg.lease = minLease
		configAdjusted.WithLabelValues("lease_ms").Set(1) // 로그 + 지표. 알림 규칙 ConfigAdjusted 가 이 값을 본다
	}
	slog.Info("worker config", "poll_ms", cfg.pollInterval.Milliseconds(), "concurrency", cfg.concurrency,
		"http_timeout_ms", cfg.httpTimeout.Milliseconds(), "max_attempts", cfg.maxAttempts,
		"backoff_base_ms", cfg.backoffBase.Milliseconds(), "backoff_max_ms", cfg.backoffMax.Milliseconds(),
		"lease_ms", cfg.lease.Milliseconds())

	// signal.NotifyContext: SIGINT/SIGTERM 이 오면 ctx 가 취소된다. compose stop / docker stop 은 SIGTERM 을 보내고
	// 기본 10초 뒤 SIGKILL 한다. 우리 드레인(HTTP 3초 + DB 쓰기)은 그 안에 끝나도록 설계돼 있다.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	dbCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	pool, err := pgxpool.New(dbCtx, mustEnv("DATABASE_URL"))
	if err == nil {
		err = pool.Ping(dbCtx)
	}
	cancel()
	if err != nil {
		slog.Error("cannot reach database", "err", err)
		os.Exit(1) // compose 의 restart 정책이 다시 띄운다. 마이그레이션은 booking-api 가 담당.
	}
	defer pool.Close()

	w := &worker{
		cfg:   cfg,
		store: &Store{db: pool},
		fwd:   NewForwarder(mustEnv("FORWARDER_URL"), cfg.httpTimeout),
	}
	prometheus.MustRegister(newBacklogCollector(pool))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", w.healthz(pool))
	mux.Handle("GET /metrics", promhttp.Handler())
	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}
	srv := &http.Server{Addr: ":" + port, Handler: mux, ReadHeaderTimeout: 5 * time.Second}

	// HTTP 서버는 별도 goroutine. ListenAndServe 가 블로킹이라 메인 goroutine 은 폴러에 쓴다.
	go func() {
		slog.Info("worker http starting", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("http server stopped", "err", err)
			os.Exit(1)
		}
	}()

	w.run(ctx) // SIGTERM 까지 블로킹. 돌아오면 처리기들은 이미 전부 끝난 상태.

	// 마지막으로 /metrics 서버를 닫는다. 지표 서버를 처리기보다 먼저 닫으면 종료 중 상태를 긁어갈 수 없다.
	shutdownCtx, cancel2 := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel2()
	srv.Shutdown(shutdownCtx) //nolint:errcheck
	slog.Info("worker stopped")
}
