package main

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Booking: DB 한 행. API 응답으로도 그대로 내보낸다.
type Booking struct {
	ID             int64           `json:"id"`
	IdempotencyKey string          `json:"idempotency_key"`
	RawText        string          `json:"raw_text"`
	Parsed         json.RawMessage `json:"parsed,omitempty"` // JSONB 를 다시 파싱하지 않고 그대로 전달
	Status         string          `json:"status"`
	NeedsReview    bool            `json:"needs_review"`
	ReviewReason   *string         `json:"review_reason,omitempty"` // NULL 가능 -> 포인터
	Version        int             `json:"version"`
	CreatedAt      time.Time       `json:"created_at"`
	UpdatedAt      time.Time       `json:"updated_at"`
}

// Store: bookings 테이블 접근을 모아둔다. 핸들러에 SQL 이 흩어지지 않게 한다.
type Store struct{ db *pgxpool.Pool }

const bookingColumns = `id, idempotency_key, raw_text, parsed, status, needs_review, review_reason, version, created_at, updated_at`

// Insert: 멱등 저장의 핵심.
// ON CONFLICT (idempotency_key) DO NOTHING -> 같은 키가 이미 있으면 아무것도 안 하고 0행 반환.
// 그 경우 기존 행을 조회해 돌려주고 created=false 로 알린다.
// 두 요청이 동시에 들어와도 UNIQUE 제약이 DB 레벨에서 한 쪽만 통과시키므로 애플리케이션 락이 필요 없다.
func (s *Store) Insert(ctx context.Context, key, raw string, parsed *ParsedBooking, reviewReason string) (*Booking, bool, error) {
	status := "parsed"
	needsReview := false
	var parsedJSON []byte
	var reasonArg *string

	if parsed == nil {
		status = "needs_review"
		needsReview = true
		reasonArg = &reviewReason
	} else {
		b, err := json.Marshal(parsed)
		if err != nil {
			return nil, false, fmt.Errorf("marshal parsed: %w", err)
		}
		parsedJSON = b
	}

	rows, err := s.db.Query(ctx, `
		INSERT INTO bookings (idempotency_key, raw_text, parsed, status, needs_review, review_reason)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (idempotency_key) DO NOTHING
		RETURNING `+bookingColumns,
		key, raw, parsedJSON, status, needsReview, reasonArg)
	if err != nil {
		return nil, false, fmt.Errorf("insert: %w", err)
	}
	b, err := scanOne(rows)
	if err != nil {
		return nil, false, err
	}
	if b != nil {
		return b, true, nil // 새로 저장됨
	}

	// 충돌 -> 기존 행 반환
	existing, err := s.GetByKey(ctx, key)
	if err != nil {
		return nil, false, err
	}
	return existing, false, nil
}

func (s *Store) GetByKey(ctx context.Context, key string) (*Booking, error) {
	rows, err := s.db.Query(ctx, `SELECT `+bookingColumns+` FROM bookings WHERE idempotency_key = $1`, key)
	if err != nil {
		return nil, fmt.Errorf("select: %w", err)
	}
	return scanOne(rows)
}

func (s *Store) GetByID(ctx context.Context, id int64) (*Booking, error) {
	rows, err := s.db.Query(ctx, `SELECT `+bookingColumns+` FROM bookings WHERE id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("select: %w", err)
	}
	return scanOne(rows)
}

// scanOne: 0행이면 (nil, nil), 1행이면 그 행. 호출 쪽이 "없음" 과 "에러" 를 구분할 수 있다.
func scanOne(rows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
	Close()
}) (*Booking, error) {
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	var b Booking
	if err := rows.Scan(&b.ID, &b.IdempotencyKey, &b.RawText, &b.Parsed, &b.Status,
		&b.NeedsReview, &b.ReviewReason, &b.Version, &b.CreatedAt, &b.UpdatedAt); err != nil {
		return nil, fmt.Errorf("scan: %w", err)
	}
	return &b, nil
}
