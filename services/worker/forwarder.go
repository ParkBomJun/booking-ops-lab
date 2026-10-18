package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// 호출 결과 분류. worker_attempts_total 의 result 라벨 값. 상수로 모아 오타를 막는다.
const (
	ResultOK        = "ok"
	ResultDuplicate = "duplicate"  // 포워더가 이미 받은 키. 성공으로 취급
	ResultTimeout   = "timeout"    // 우리 타임아웃(ctx) 초과
	ResultConnError = "conn_error" // 연결 거부, DNS 실패 등 응답 자체가 없음
	ResultHTTP5xx   = "http_5xx"   // 재시도 대상
	ResultHTTP4xx   = "http_4xx"   // 재시도 안 함 -> failed
	ResultPending   = "pending"    // confirm 단계: 아직 확정 전. 나중에 다시 조회
)

// retryable: 다시 시도하면 성공할 수 있는 결과인가.
// 4xx 는 우리 요청이 잘못된 것이라 반복해도 같다 -> false.
func retryable(result string) bool {
	switch result {
	case ResultTimeout, ResultConnError, ResultHTTP5xx, ResultPending:
		return true
	}
	return false
}

// Forwarder: mock-forwarder HTTP 클라이언트. 호출당 타임아웃을 ctx 로 건다.
type Forwarder struct {
	base    string
	timeout time.Duration
	client  *http.Client
}

func NewForwarder(base string, timeout time.Duration) *Forwarder {
	return &Forwarder{
		base:    base,
		timeout: timeout,
		// 커넥션 풀 상한. 동시 goroutine 수(4)보다 넉넉하게. 기본값은 호스트당 2개라 병목이 된다.
		client: &http.Client{Transport: &http.Transport{MaxIdleConnsPerHost: 16}},
	}
}

type fwdResponse struct {
	Ref   string `json:"ref"`
	State string `json:"state"`
}

// Send: POST /bookings. 반환: (ref, result, 사람이 읽을 에러 설명)
func (f *Forwarder) Send(ctx context.Context, key string, parsed json.RawMessage) (string, string, string) {
	body := bytes.NewReader(parsed)
	req, _ := http.NewRequest(http.MethodPost, f.base+"/bookings", body)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", key) // 재전송돼도 포워더가 같은 건으로 인식하게 한다

	resp, result, detail := f.do(ctx, req, "send")
	if resp == nil {
		return "", result, detail
	}
	switch {
	case resp.StatusCode == http.StatusAccepted:
		return resp.Ref, ResultOK, ""
	case resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusConflict:
		return resp.Ref, ResultDuplicate, "" // 이미 받은 건. 포워더가 준 ref 를 그대로 쓴다
	}
	return "", result, detail
}

// Status: GET /bookings/{ref}. 반환: (포워더 상태 문자열, result, 설명)
func (f *Forwarder) Status(ctx context.Context, ref string) (string, string, string) {
	req, _ := http.NewRequest(http.MethodGet, f.base+"/bookings/"+ref, nil)
	resp, result, detail := f.do(ctx, req, "confirm")
	if resp == nil {
		return "", result, detail
	}
	if resp.StatusCode == http.StatusOK {
		return resp.State, ResultOK, ""
	}
	return "", result, detail
}

type parsedResp struct {
	fwdResponse
	StatusCode int
}

// do: 공통 호출부. 타임아웃·지연시간 지표·결과 분류를 한 곳에서 한다.
func (f *Forwarder) do(ctx context.Context, req *http.Request, stage string) (*parsedResp, string, string) {
	// 호출당 타임아웃. 부모 ctx 가 먼저 취소되면 그것도 따른다.
	ctx, cancel := context.WithTimeout(ctx, f.timeout)
	defer cancel()
	req = req.WithContext(ctx)

	start := time.Now()
	res, err := f.client.Do(req)
	forwarderDuration.WithLabelValues(stage).Observe(time.Since(start).Seconds())

	if err != nil {
		// errors.Is 는 감싸진 에러 체인 어디에든 해당 값이 있는지 본다.
		// 타임아웃은 *url.Error 안에 context.DeadlineExceeded 로 들어 있다.
		if errors.Is(err, context.DeadlineExceeded) {
			return nil, ResultTimeout, fmt.Sprintf("timeout after %s", f.timeout)
		}
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			return nil, ResultTimeout, err.Error()
		}
		return nil, ResultConnError, err.Error()
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10)) // 응답 크기 상한 64KB. 외부 입력은 믿지 않는다

	out := &parsedResp{StatusCode: res.StatusCode}
	if res.StatusCode >= 500 {
		return out, ResultHTTP5xx, fmt.Sprintf("HTTP %d: %s", res.StatusCode, truncate(raw, 200))
	}
	if res.StatusCode >= 400 && res.StatusCode != http.StatusConflict {
		return out, ResultHTTP4xx, fmt.Sprintf("HTTP %d: %s", res.StatusCode, truncate(raw, 200))
	}
	if err := json.Unmarshal(raw, &out.fwdResponse); err != nil {
		return out, ResultHTTP5xx, "invalid JSON from forwarder: " + err.Error() // 깨진 응답은 포워더 쪽 문제로 보고 재시도
	}
	return out, ResultOK, ""
}

func truncate(b []byte, n int) string {
	if len(b) > n {
		return string(b[:n]) + "..."
	}
	return string(b)
}
