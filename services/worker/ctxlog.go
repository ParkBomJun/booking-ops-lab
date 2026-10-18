package main

import (
	"context"
	"log/slog"
)

// 요청 범위 로거를 context 에 실어 보내기 위한 키. 비공개 타입이라 다른 패키지와 충돌하지 않는다.
type loggerKey struct{}

// withLogger: booking_id 같은 공통 속성이 붙은 로거를 ctx 에 넣는다.
func withLogger(ctx context.Context, l *slog.Logger) context.Context {
	return context.WithValue(ctx, loggerKey{}, l)
}

// logFrom: ctx 에 로거가 있으면 그것을, 없으면 기본 로거를 돌려준다.
// parser / store 는 booking_id 를 인자로 받지 않고 이 함수로 로거를 꺼내 쓴다.
// -> "모든 로그 줄에 booking_id" 를 함수 시그니처 변경 없이 보장한다.
func logFrom(ctx context.Context) *slog.Logger {
	if l, ok := ctx.Value(loggerKey{}).(*slog.Logger); ok {
		return l
	}
	return slog.Default()
}
