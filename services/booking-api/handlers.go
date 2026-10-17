package main

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// 요청 본문 상한. 파싱 비용(토큰)과 메모리를 함께 보호한다.
const maxBodyBytes = 16 * 1024

type createBookingRequest struct {
	Text string `json:"text"`
}

// createBooking: POST /bookings
// 흐름: 멱등키 확인 -> 이미 있으면 바로 반환 -> Claude 파싱(실패해도 계속) -> 저장 -> 201/200
func (a *app) createBooking(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if key == "" || len(key) > 128 {
		writeError(w, http.StatusBadRequest, "Idempotency-Key header is required (1-128 chars)")
		return
	}

	var req createBookingRequest
	body := http.MaxBytesReader(w, r.Body, maxBodyBytes)
	if err := json.NewDecoder(body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body: "+err.Error())
		return
	}
	req.Text = strings.TrimSpace(req.Text)
	if req.Text == "" {
		writeError(w, http.StatusBadRequest, "text is required")
		return
	}

	ctx := r.Context()

	// 1) 멱등성 선조회. 같은 키가 이미 있으면 Claude 를 다시 부르지 않는다 (비용·지연 절약).
	//    단, 이 조회만으로는 동시 요청의 경쟁을 막지 못한다 -> 최종 방어는 Insert 의 UNIQUE 제약.
	if existing, err := a.store.GetByKey(ctx, key); err != nil {
		slog.Error("lookup failed", "booking_key", key, "err", err.Error())
		writeError(w, http.StatusInternalServerError, "database error")
		return
	} else if existing != nil {
		slog.Info("booking duplicate", "booking_id", existing.ID, "booking_key", key, "stage", "idempotency")
		writeJSON(w, http.StatusOK, existing)
		return
	}

	// 2) 파싱. 실패는 에러가 아니라 "검토 대기" 라는 정상 경로다.
	parsed, err := a.parser.Parse(ctx, key, req.Text)
	reason := ""
	if err != nil {
		var pe *ParseError
		if errors.As(err, &pe) {
			reason = pe.Reason
		} else {
			reason = ReasonAPIError
		}
	}

	// 3) 저장 (멱등)
	b, created, err := a.store.Insert(ctx, key, req.Text, parsed, reason)
	if err != nil {
		slog.Error("insert failed", "booking_key", key, "err", err.Error())
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}

	slog.Info("booking processed",
		"booking_id", b.ID, "booking_key", key, "stage", "store",
		"status", b.Status, "needs_review", b.NeedsReview, "created", created,
		"elapsed_ms", time.Since(start).Milliseconds())

	if created {
		writeJSON(w, http.StatusCreated, b)
	} else {
		writeJSON(w, http.StatusOK, b) // 경쟁에서 진 쪽: 먼저 저장된 행을 그대로 돌려준다
	}
}

// getBooking: GET /bookings/{id}
func (a *app) getBooking(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64) // Go 1.22 의 경로 변수
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	b, err := a.store.GetByID(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}
	if b == nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	writeJSON(w, http.StatusOK, b)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
