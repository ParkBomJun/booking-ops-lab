// Package main: mock-forwarder. 실제 포워더 시스템을 흉내 내는 모의 외부 서비스.
// 환경변수로 장애(실패율, 지연, 응답 유실, 순서 역전)를 주입해 worker 의 대응을 시험한다.
package main

import (
	"encoding/json"
	"log/slog"
	"math/rand/v2" // Go 1.22+ 의 새 난수 패키지. 시드 없이 바로 쓸 수 있다.
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// faults: 주입할 장애 설정. 시작 시 환경변수에서 한 번 읽는다. 바꾸려면 컨테이너를 다시 띄운다.
type faults struct {
	failRate     float64       // FAIL_RATE: 이 확률로 500 반환 (저장 안 함)
	delay        time.Duration // DELAY_MS: 모든 응답 앞에 지연. worker 타임아웃(3s) 재현용
	dupRate      float64       // DUP_RATE: 저장은 하고 500 반환 (응답 유실). worker 가 재전송하면 같은 ref 로 200
	outOfOrder   bool          // OUT_OF_ORDER: GET 이 확률적으로 이전 상태(pending)를 돌려줌
	confirmAfter time.Duration // CONFIRM_AFTER_MS: POST 후 이 시간이 지나면 pending -> confirmed
}

// record: 포워더가 기억하는 부킹 하나.
type record struct {
	Ref        string    `json:"ref"`
	ReceivedAt time.Time `json:"received_at"`
}

// store: in-memory 저장소. 두 개의 map 과 그것을 지키는 뮤텍스.
//
// 왜 뮤텍스가 필요한가: net/http 는 요청마다 goroutine 을 하나씩 띄운다.
// Go 의 map 은 동시 쓰기에 안전하지 않아 ("concurrent map writes" 로 즉시 크래시),
// 여러 요청이 동시에 map 을 만지면 반드시 잠금으로 직렬화해야 한다.
type store struct {
	mu    sync.Mutex
	byKey map[string]*record // Idempotency-Key -> record. 중복 전송 감지용
	byRef map[string]*record // ref -> record. GET 조회용
}

var (
	reqTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "forwarder_requests_total",
		Help: "Requests by route and outcome (ok, injected_fail, injected_dup, duplicate, not_found).",
	}, []string{"route", "outcome"})
	stored = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "forwarder_bookings_stored",
		Help: "Bookings currently held in memory.",
	})
)

type server struct {
	f  faults
	st *store
}

// postBooking: POST /bookings. 부킹을 받아 ref 를 발급한다.
func (s *server) postBooking(w http.ResponseWriter, r *http.Request) {
	time.Sleep(s.f.delay) // 지연 주입. 저장 전에 자므로 타임아웃된 요청도 아래 로직까지 도달한다 (실제 시스템과 같음)

	key := r.Header.Get("Idempotency-Key")
	if key == "" {
		reqTotal.WithLabelValues("/bookings", "bad_request").Inc()
		http.Error(w, `{"error":"Idempotency-Key header required"}`, http.StatusBadRequest)
		return
	}

	// FAIL_RATE: 저장하지 않고 실패. "포워더가 아예 못 받은" 상황.
	if rand.Float64() < s.f.failRate {
		reqTotal.WithLabelValues("/bookings", "injected_fail").Inc()
		http.Error(w, `{"error":"injected failure"}`, http.StatusInternalServerError)
		return
	}

	s.st.mu.Lock()
	rec, exists := s.st.byKey[key]
	if !exists {
		rec = &record{Ref: "FWD-" + strconv.FormatInt(time.Now().UnixNano(), 36), ReceivedAt: time.Now()}
		s.st.byKey[key] = rec
		s.st.byRef[rec.Ref] = rec
		stored.Set(float64(len(s.st.byKey)))
	}
	s.st.mu.Unlock()

	// DUP_RATE: 저장은 끝났는데 응답이 유실된 상황. 클라이언트는 실패로 보고 재전송하게 된다.
	// 새로 저장한 경우에만 적용한다. 이미 있던 키에 또 유실을 주면 영원히 성공하지 못할 수 있다.
	if !exists && rand.Float64() < s.f.dupRate {
		reqTotal.WithLabelValues("/bookings", "injected_dup").Inc()
		http.Error(w, `{"error":"injected response loss"}`, http.StatusInternalServerError)
		return
	}

	// 이미 받은 키면 200 + 같은 ref. 처음이면 202(Accepted: 받았고 처리는 비동기).
	status := http.StatusAccepted
	outcome := "ok"
	if exists {
		status = http.StatusOK
		outcome = "duplicate"
	}
	reqTotal.WithLabelValues("/bookings", outcome).Inc()
	slog.Info("booking received", "booking_id", key, "ref", rec.Ref, "duplicate", exists)
	writeJSON(w, status, map[string]string{"ref": rec.Ref, "state": s.stateOf(rec, false)})
}

// getBooking: GET /bookings/{ref}. 현재 상태를 돌려준다.
func (s *server) getBooking(w http.ResponseWriter, r *http.Request) {
	time.Sleep(s.f.delay)
	ref := r.PathValue("ref")

	s.st.mu.Lock()
	rec, ok := s.st.byRef[ref]
	s.st.mu.Unlock()
	if !ok {
		reqTotal.WithLabelValues("/bookings/{ref}", "not_found").Inc()
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	reqTotal.WithLabelValues("/bookings/{ref}", "ok").Inc()
	writeJSON(w, http.StatusOK, map[string]string{"ref": rec.Ref, "state": s.stateOf(rec, true)})
}

// stateOf: 받은 지 confirmAfter 가 지났으면 confirmed, 아니면 pending.
// OUT_OF_ORDER 가 켜져 있으면 GET 응답의 30% 를 pending 으로 되돌린다.
// 실제 외부 시스템에서 "늦게 도착한 옛 응답" 이 나중 응답을 덮어쓰는 사고를 흉내 낸다.
// worker 는 confirmed -> sent 역행을 거부해야 한다.
func (s *server) stateOf(rec *record, allowRegress bool) string {
	if time.Since(rec.ReceivedAt) < s.f.confirmAfter {
		return "pending"
	}
	if allowRegress && s.f.outOfOrder && rand.Float64() < 0.3 {
		return "pending"
	}
	return "confirmed"
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}

// envFloat / envInt: 환경변수 파싱. 없거나 잘못되면 기본값. 장애 주입 설정이 틀렸다고 서비스가 안 뜨면 곤란하다.
func envFloat(key string, def float64) float64 {
	if v, err := strconv.ParseFloat(os.Getenv(key), 64); err == nil {
		return v
	}
	return def
}
func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	f := faults{
		failRate:     envFloat("FAIL_RATE", 0),
		delay:        time.Duration(envInt("DELAY_MS", 0)) * time.Millisecond,
		dupRate:      envFloat("DUP_RATE", 0),
		outOfOrder:   os.Getenv("OUT_OF_ORDER") == "true",
		confirmAfter: time.Duration(envInt("CONFIRM_AFTER_MS", 5000)) * time.Millisecond,
	}
	// 시작 로그에 설정을 찍어둔다. 장애 훈련 때 "지금 어떤 장애가 주입돼 있는가" 를 로그로 증명할 수 있다.
	slog.Info("mock-forwarder faults", "fail_rate", f.failRate, "delay_ms", f.delay.Milliseconds(),
		"dup_rate", f.dupRate, "out_of_order", f.outOfOrder, "confirm_after_ms", f.confirmAfter.Milliseconds())

	s := &server{f: f, st: &store{byKey: map[string]*record{}, byRef: map[string]*record{}}}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /bookings", s.postBooking)
	mux.HandleFunc("GET /bookings/{ref}", s.getBooking)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"}) // 외부 의존성이 없어 항상 ok
	})
	mux.Handle("GET /metrics", promhttp.Handler())

	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		// WriteTimeout 은 DELAY_MS 보다 커야 한다. 작으면 서버가 먼저 끊어 "지연" 이 아니라 "연결 끊김" 이 된다.
		WriteTimeout: 60 * time.Second,
	}
	slog.Info("mock-forwarder starting", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
