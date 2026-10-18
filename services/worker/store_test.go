package main

import (
	"testing"
	"time"
)

// 상태 전이 표: 역행과 종결 상태에서의 탈출이 모두 막히는지 확인한다.
func TestTransitionAllowed(t *testing.T) {
	cases := []struct {
		from, to string
		want     bool
	}{
		{"parsed", "sent", true},
		{"parsed", "failed", true},
		{"sent", "confirmed", true},
		{"sent", "failed", true},
		{"confirmed", "sent", false},   // 역행 (OUT_OF_ORDER 가 노리는 것)
		{"confirmed", "failed", false}, // 종결 상태 탈출
		{"failed", "parsed", false},
		{"sent", "parsed", false},
		{"received", "sent", false}, // worker 가 건너뛰어 전송하면 안 됨
		{"needs_review", "sent", false},
	}
	for _, c := range cases {
		if got := transitionAllowed(c.from, c.to); got != c.want {
			t.Errorf("%s -> %s: got %v want %v", c.from, c.to, got, c.want)
		}
	}
}

// 백오프: 지수 증가, 상한, 지터 범위.
func TestBackoff(t *testing.T) {
	w := &worker{cfg: config{backoffBase: time.Second, backoffMax: 30 * time.Second}}
	expect := []time.Duration{1 * time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	for i, base := range expect {
		got := w.backoff(i + 1)
		lo, hi := time.Duration(float64(base)*0.8), time.Duration(float64(base)*1.2)
		if got < lo || got > hi {
			t.Errorf("attempt %d: got %s, want within [%s, %s]", i+1, got, lo, hi)
		}
	}
	// 매우 큰 attempt 에서 시프트 오버플로가 나도 상한으로 수렴해야 한다.
	if got := w.backoff(70); got > 36*time.Second {
		t.Errorf("attempt 70: got %s, want <= max*1.2", got)
	}
}

// 재시도 분류: 4xx 만 비재시도.
func TestRetryable(t *testing.T) {
	for _, r := range []string{ResultTimeout, ResultConnError, ResultHTTP5xx, ResultPending} {
		if !retryable(r) {
			t.Errorf("%s should be retryable", r)
		}
	}
	for _, r := range []string{ResultHTTP4xx, ResultOK, ResultDuplicate} {
		if retryable(r) {
			t.Errorf("%s should not be retryable", r)
		}
	}
}
