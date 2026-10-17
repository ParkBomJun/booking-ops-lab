// Package main: booking-api 서비스의 시작점.
package main

import (
	"context"       // 타임아웃·취소 신호를 함수 호출 체인에 전달하는 표준 도구
	"encoding/json" // 응답을 JSON 으로 만들기 위한 표준 라이브러리
	"log/slog"      // 구조화(JSON) 로그
	"net/http"      // HTTP 서버
	"os"            // 환경변수, 표준출력
	"strconv"       // 문자열 -> 숫자 변환 (환경변수 파싱)
	"time"          // 타임아웃 설정

	// pgxpool: PostgreSQL 커넥션 풀. 요청마다 새 연결을 만들지 않고 미리 열어둔
	// 연결을 재사용한다. 외부 의존성은 이것 하나뿐이다.
	"github.com/jackc/pgx/v5/pgxpool"
)

// healthResponse: /healthz 응답 형태.
// Checks 에 의존성별 상태를 담는다. 지금은 "db" 하나지만 나중에 늘어난다.
type healthResponse struct {
	Status string            `json:"status"`
	Checks map[string]string `json:"checks"`
}

// app: 핸들러들이 공유해야 하는 것(DB 풀 등)을 담는 구조체.
// Go 에는 전역 변수 대신 이렇게 의존성을 묶어 메서드로 핸들러를 만드는 관례가 있다.
type app struct {
	db     *pgxpool.Pool
	store  *Store
	parser *Parser
}

// healthz: GET /healthz. DB 에 실제로 쿼리를 날려서 살아 있는지 확인한다.
// 앞에 (a *app) 가 붙은 함수를 "메서드" 라고 부른다. a.db 로 풀에 접근할 수 있다.
func (a *app) healthz(w http.ResponseWriter, r *http.Request) {
	// 헬스체크가 DB 장애에 끌려가 무한 대기하면 안 된다. 2초 안에 답이 없으면 실패 처리.
	// defer cancel(): 이 함수가 끝날 때 반드시 cancel 을 호출해 자원을 정리한다.
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	resp := healthResponse{Status: "ok", Checks: map[string]string{}}
	status := http.StatusOK

	// Ping: 풀에서 연결 하나를 꺼내 ";" 같은 가벼운 쿼리로 응답을 확인한다.
	if err := a.db.Ping(ctx); err != nil {
		resp.Status = "degraded"
		resp.Checks["db"] = "fail: " + err.Error()
		status = http.StatusServiceUnavailable // 503. 로드밸런서·compose 가 "비정상" 으로 인식.
		slog.Error("healthz db check failed", "err", err)
	} else {
		resp.Checks["db"] = "ok"
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(resp)
}

// mustEnv: 필수 환경변수를 읽는다. 없으면 즉시 종료.
// 설정이 빠진 채로 조용히 떠서 나중에 터지는 것보다, 시작 시점에 크게 실패하는 것이 운영상 낫다.
func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		slog.Error("required environment variable is missing", "key", key)
		os.Exit(1)
	}
	return v
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// DATABASE_URL 형식: postgres://user:password@host:5432/dbname?sslmode=disable
	// 비밀값(비밀번호)이 들어 있으므로 코드에 쓰지 않고 .env 에서만 주입한다.
	dsn := mustEnv("DATABASE_URL")

	// 풀 생성에도 타임아웃을 둔다. DB 가 아직 안 떴으면 5초 후 실패하고 종료한다.
	// compose 의 restart 정책이 다시 띄워주므로, 여기서 재시도 루프를 직접 짜지 않는다.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// pgxpool.New 는 설정만 파싱하고 실제 연결은 지연(lazy) 생성한다.
	// 그래서 바로 Ping 을 한 번 날려 시작 시점에 DB 도달 가능 여부를 확인한다.
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		slog.Error("invalid DATABASE_URL", "err", err)
		os.Exit(1)
	}
	if err := pool.Ping(ctx); err != nil {
		slog.Error("cannot reach database", "err", err)
		os.Exit(1)
	}
	defer pool.Close() // main 이 끝날 때 연결을 정리한다.
	slog.Info("database connected")

	// 스키마 마이그레이션. 실패하면 떠 있어도 의미가 없으므로 종료한다.
	if err := runMigrations(ctx, pool); err != nil {
		slog.Error("migration failed", "err", err)
		os.Exit(1)
	}

	// Claude 설정. 키는 mustEnv 로 읽어 NewParser 에만 넘기고 어디에도 저장·출력하지 않는다.
	apiKey := mustEnv("ANTHROPIC_API_KEY")
	workspaceID := os.Getenv("ANTHROPIC_WORKSPACE_ID") // 선택
	model := os.Getenv("CLAUDE_MODEL")
	if model == "" {
		model = "claude-opus-5-5"
	}
	parseTimeout := 10 * time.Second
	if v := os.Getenv("CLAUDE_TIMEOUT_MS"); v != "" {
		if ms, err := strconv.Atoi(v); err == nil && ms > 0 {
			parseTimeout = time.Duration(ms) * time.Millisecond
		}
	}
	// 시작 로그에 키는 절대 찍지 않는다. "설정됨" 여부와 길이만으로 디버깅은 충분하다.
	slog.Info("claude configured", "model", model, "timeout_ms", parseTimeout.Milliseconds(), "api_key_set", apiKey != "", "workspace_id_set", workspaceID != "")

	a := &app{
		db:     pool,
		store:  &Store{db: pool},
		parser: NewParser(apiKey, workspaceID, model, parseTimeout),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.healthz)
	mux.HandleFunc("POST /bookings", a.createBooking)
	mux.HandleFunc("GET /bookings/{id}", a.getBooking)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second, // Claude 호출(최대 10초) 포함 여유
		IdleTimeout:       60 * time.Second,
	}

	slog.Info("booking-api starting", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
