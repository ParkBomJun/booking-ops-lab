package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

// ParsedBooking: Claude 가 돌려줘야 하는 JSON 의 형태. DB 의 parsed(JSONB) 에 그대로 저장된다.
type ParsedBooking struct {
	Shipper          string `json:"shipper"`
	Consignee        string `json:"consignee"`
	OriginPort       string `json:"origin_port"`
	DestinationPort  string `json:"destination_port"`
	ContainerType    string `json:"container_type"`
	ContainerCount   int    `json:"container_count"`
	CargoDescription string `json:"cargo_description"`
	RequestedETD     string `json:"requested_etd"`
}

// 파싱 실패 원인. DB 의 review_reason 컬럼과 지표 라벨에 그대로 쓰인다.
// 상수로 모아두면 오타로 라벨이 쪼개지는 사고를 막을 수 있다.
const (
	ReasonTimeout     = "claude_timeout"
	ReasonAPIError    = "claude_error"
	ReasonInvalidJSON = "invalid_json"
	ReasonValidation  = "validation_failed"
)

// ParseError: 실패 원인(Reason)을 함께 들고 다니는 에러 타입.
// 호출 쪽은 errors.As 로 Reason 을 꺼내 needs_review 사유로 기록한다.
type ParseError struct {
	Reason string
	Err    error
}

func (e *ParseError) Error() string { return e.Reason + ": " + e.Err.Error() }
func (e *ParseError) Unwrap() error { return e.Err }

// Parser: Claude API 호출을 감싼다. 핸들러는 이 구조체만 알면 된다.
type Parser struct {
	client  anthropic.Client
	model   string
	timeout time.Duration
}

// NewParser: apiKey 는 여기서 클라이언트에 넘기고 끝. 구조체에 보관하지 않으므로
// 실수로 로그에 찍힐 경로 자체가 없다.
// workspaceID: 조직 전체 범위의 키를 쓸 때만 필요. 워크스페이스에 묶인 키면 빈 문자열.
func NewParser(apiKey, workspaceID, model string, timeout time.Duration) *Parser {
	opts := []option.RequestOption{
		option.WithAPIKey(apiKey),
		// SDK 자체 재시도는 끈다. 재시도 정책은 우리가 ctx 타임아웃으로 통제하고,
		// 실패하면 재시도 대신 "검토 대기함" 으로 보내는 것이 이 서비스의 설계다.
		option.WithMaxRetries(0),
	}
	if workspaceID != "" {
		opts = append(opts, option.WithHeader("anthropic-workspace-id", workspaceID))
	}
	return &Parser{
		client:  anthropic.NewClient(opts...),
		model:   model,
		timeout: timeout,
	}
}

// 시스템 프롬프트. 매 요청 동일하므로 Claude 쪽 프롬프트 캐시 대상이 된다.
const systemPrompt = `You extract ocean freight booking requests into JSON.
Return ONLY a JSON object with exactly these keys and nothing else (no markdown, no prose):
{"shipper":"","consignee":"","origin_port":"","destination_port":"","container_type":"","container_count":0,"cargo_description":"","requested_etd":""}
Rules:
- origin_port / destination_port: 5-letter UN/LOCODE (e.g. KRPUS, USLAX). If unknown, use "".
- container_type: one of 20GP, 40GP, 40HC, 45HC, 20RF, 40RF. If unknown, use "".
- container_count: integer, 0 if unknown.
- requested_etd: YYYY-MM-DD, "" if unknown.
- Never invent values. Use "" or 0 when the text does not say.`

var locodeRe = regexp.MustCompile(`^[A-Z]{5}$`)

// Parse: 원문 -> ParsedBooking. 실패하면 반드시 *ParseError 를 돌려준다.
// usage(토큰 사용량) 는 성공·실패와 관계없이 응답을 받았다면 로그에 남긴다 -> 나중에 비용 지표로 쓴다.
func (p *Parser) Parse(ctx context.Context, bookingID string, raw string) (*ParsedBooking, error) {
	ctx, cancel := context.WithTimeout(ctx, p.timeout)
	defer cancel()

	start := time.Now()
	resp, err := p.client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     anthropic.Model(p.model),
		MaxTokens: 1024, // 결과 JSON 은 수백 토큰이면 충분하다
		System:    []anthropic.TextBlockParam{{Text: systemPrompt}},
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(raw)),
		},
		// 추출 작업은 단순하므로 생각 깊이는 낮게. 비용·지연 모두 줄어든다.
		OutputConfig: anthropic.OutputConfigParam{Effort: anthropic.OutputConfigEffortLow},
	})
	elapsed := time.Since(start)

	if err != nil {
		// 타임아웃과 그 외 API 에러를 구분한다. 장애 훈련 2번(Claude 타임아웃)에서 이 라벨로 지표가 튄다.
		reason := ReasonAPIError
		if errors.Is(err, context.DeadlineExceeded) {
			reason = ReasonTimeout
		}
		var apiErr *anthropic.Error
		attrs := []any{"booking_id", bookingID, "stage", "parse", "reason", reason, "elapsed_ms", elapsed.Milliseconds()}
		if errors.As(err, &apiErr) {
			// apiErr.Error() 는 메서드·URL·상태·요청ID·응답 본문만 담고 요청 헤더(API 키)는 포함하지 않는다.
			// 처음엔 status 만 남겼다가 400 원인을 알 수 없어 재현이 필요했다 -> 메시지도 남긴다 (ai-usage.md 참고).
			attrs = append(attrs, "status", apiErr.StatusCode, "request_id", apiErr.RequestID, "err", apiErr.Error())
		} else {
			attrs = append(attrs, "err", err.Error())
		}
		slog.Error("claude parse failed", attrs...)
		return nil, &ParseError{Reason: reason, Err: err}
	}

	// 토큰 사용량 로그. 요청당 한 줄. 2단계에서 이 값을 Prometheus 카운터로도 올린다.
	slog.Info("claude usage",
		"booking_id", bookingID, "stage", "parse", "model", p.model,
		"input_tokens", resp.Usage.InputTokens,
		"output_tokens", resp.Usage.OutputTokens,
		"cache_read_tokens", resp.Usage.CacheReadInputTokens,
		"stop_reason", resp.StopReason,
		"elapsed_ms", elapsed.Milliseconds(),
	)

	if resp.StopReason == anthropic.StopReasonMaxTokens || resp.StopReason == anthropic.StopReasonRefusal {
		return nil, &ParseError{Reason: ReasonInvalidJSON, Err: fmt.Errorf("stop_reason=%s", resp.StopReason)}
	}

	// 응답에서 텍스트 블록만 모은다.
	var sb strings.Builder
	for _, block := range resp.Content {
		if tb, ok := block.AsAny().(anthropic.TextBlock); ok {
			sb.WriteString(tb.Text)
		}
	}
	text := strings.TrimSpace(sb.String())
	// 모델이 ```json ... ``` 으로 감싸는 경우를 관대하게 처리한다.
	text = strings.TrimPrefix(text, "```json")
	text = strings.TrimPrefix(text, "```")
	text = strings.TrimSuffix(text, "```")

	var out ParsedBooking
	if err := json.Unmarshal([]byte(strings.TrimSpace(text)), &out); err != nil {
		slog.Warn("claude returned non-json", "booking_id", bookingID, "stage", "parse", "err", err.Error())
		return nil, &ParseError{Reason: ReasonInvalidJSON, Err: err}
	}
	if err := out.validate(); err != nil {
		return nil, &ParseError{Reason: ReasonValidation, Err: err}
	}
	return &out, nil
}

// validate: 모델 출력을 믿지 않는다. 최소 조건을 Go 에서 다시 검사한다.
func (b *ParsedBooking) validate() error {
	var problems []string
	if !locodeRe.MatchString(b.OriginPort) {
		problems = append(problems, "origin_port")
	}
	if !locodeRe.MatchString(b.DestinationPort) {
		problems = append(problems, "destination_port")
	}
	if b.ContainerCount < 1 {
		problems = append(problems, "container_count")
	}
	if b.Shipper == "" {
		problems = append(problems, "shipper")
	}
	if len(problems) > 0 {
		return fmt.Errorf("missing or invalid: %s", strings.Join(problems, ","))
	}
	return nil
}
