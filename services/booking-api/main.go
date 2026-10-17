// Package main: booking-api 서비스의 시작점.
// Go 프로그램은 반드시 package main + func main() 에서 실행이 시작된다.
package main

import (
	"encoding/json" // 응답을 JSON 으로 만들기 위한 표준 라이브러리
	"log/slog"      // 구조화(JSON) 로그. CLAUDE.md 규칙: 모든 로그는 slog JSON
	"net/http"      // HTTP 서버. 외부 프레임워크 없이 표준 라이브러리만 사용
	"os"            // 환경변수 읽기, 표준출력
	"time"          // 서버 타임아웃 설정
)

// healthResponse: /healthz 가 돌려줄 응답의 형태.
// 뒤에 붙은 `json:"status"` 는 "구조체 태그". JSON 으로 바꿀 때 필드 이름을 정해준다.
// 지금은 status 하나지만, 다음 단계에서 DB 연결 상태 같은 의존성 항목을 추가할 자리다.
type healthResponse struct {
	Status string `json:"status"`
}

// healthzHandler: GET /healthz 요청을 처리하는 함수.
// Go 의 HTTP 핸들러는 항상 (ResponseWriter, *Request) 두 인자를 받는 형태로 고정이다.
//   - w: 응답을 써 넣는 곳
//   - r: 들어온 요청 정보
func healthzHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK) // 200. 나중에 DB가 죽으면 여기서 503 을 돌려준다.
	json.NewEncoder(w).Encode(healthResponse{Status: "ok"})
}

func main() {
	// slog 를 JSON 출력으로 설정하고 기본 로거로 등록한다.
	// 이후 slog.Info(...) 호출은 전부 한 줄짜리 JSON 으로 stdout 에 찍힌다.
	// -> 도커 로그 수집, 나중에 Loki/Grafana 연동 때 파싱이 쉬워진다.
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	// 포트는 환경변수 PORT 로 바꿀 수 있게 한다 (12-factor 방식). 없으면 8080.
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// 라우터(mux): URL 경로와 핸들러 함수를 연결하는 표.
	// "GET /healthz" 처럼 메서드까지 지정하는 문법은 Go 1.22 부터 지원된다.
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthzHandler)

	// http.ListenAndServe 를 바로 쓰지 않고 Server 구조체를 만드는 이유:
	// 타임아웃을 지정하기 위해서다. 타임아웃이 없으면 느린 클라이언트 하나가
	// 연결을 계속 붙잡아 서버 자원을 고갈시킬 수 있다 (운영 관점의 기본 방어).
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,  // 요청 헤더를 다 받기까지 허용 시간
		ReadTimeout:       10 * time.Second, // 요청 본문 포함 전체 읽기 시간
		WriteTimeout:      10 * time.Second, // 응답 쓰기 시간
		IdleTimeout:       60 * time.Second, // keep-alive 연결 유지 시간
	}

	slog.Info("booking-api starting", "addr", srv.Addr)

	// ListenAndServe 는 서버가 멈출 때까지 블로킹된다. 에러가 나면 로그 찍고 종료.
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
