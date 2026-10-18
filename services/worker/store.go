package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Booking: worker 가 필요로 하는 컬럼만 담는다. API 의 Booking 과 같은 테이블이지만 관심사가 다르다.
type Booking struct {
	ID           int64
	Key          string // idempotency_key. 로그의 booking_id 이자 포워더에 보내는 Idempotency-Key
	Parsed       json.RawMessage
	Status       string
	Version      int // claim 직후의 version. 이후 모든 쓰기는 이 값과 일치해야 적용된다
	Attempts     int
	ForwarderRef *string
}

// ---- 상태 전이 규칙 ----
// 표에 없는 전이는 어떤 경우에도 적용하지 않는다. 포워더가 뒤늦게 옛 상태를 돌려줘도 여기서 막힌다.
var allowedTransitions = map[string][]string{
	"parsed": {"sent", "failed"},
	"sent":   {"confirmed", "failed"},
	// confirmed, failed: 종결 상태. 나가는 전이 없음.
	// received -> parsed/needs_review 와 needs_review -> parsed 는 API/사람의 몫이라 worker 표에 없다.
}

func transitionAllowed(from, to string) bool {
	for _, t := range allowedTransitions[from] {
		if t == to {
			return true
		}
	}
	return false
}

// ErrVersionConflict: 쓰려던 행의 version 이 우리가 기억한 값과 다르다.
// 방침: 덮어쓰지 않고, 쓰기를 재시도하지 않고, 이번 건 처리를 여기서 끝낸다.
var ErrVersionConflict = errors.New("version conflict")

// ErrTransitionRejected: 전이 표에 없는 상태 변경 요청.
var ErrTransitionRejected = errors.New("transition rejected")

type Store struct{ db *pgxpool.Pool }

// Claim: 처리 대상 행을 최대 n 건 집어온다. 트랜잭션은 이 UPDATE 하나로 끝난다.
//
//   - 대상: parsed/sent 이면서 next_attempt_at 이 지났고, 임대가 없거나 만료된 행
//   - FOR UPDATE SKIP LOCKED: 다른 트랜잭션이 잠근 행은 기다리지 않고 건너뛴다.
//     worker 가 여러 개여도 같은 행을 두 번 집는 일이 DB 레벨에서 막힌다.
//   - claimed_until 을 lease 만큼 미래로 찍고 version 을 올린다. 이 version 이 "우리 차례" 의 증표다.
//   - HTTP 호출 동안 DB 락을 들고 있지 않는다. 락은 이 문장이 커밋되는 순간 풀린다.
func (s *Store) Claim(ctx context.Context, n int, lease time.Duration) ([]Booking, error) {
	rows, err := s.db.Query(ctx, `
		UPDATE bookings
		   SET claimed_until = now() + $2, version = version + 1
		 WHERE id IN (
		       SELECT id FROM bookings
		        WHERE status IN ('parsed','sent')
		          AND next_attempt_at <= now()
		          AND (claimed_until IS NULL OR claimed_until < now())
		        ORDER BY next_attempt_at
		        LIMIT $1
		        FOR UPDATE SKIP LOCKED)
		RETURNING id, idempotency_key, parsed, status, version, attempts, forwarder_ref`,
		n, lease)
	if err != nil {
		return nil, fmt.Errorf("claim: %w", err)
	}
	defer rows.Close()

	var out []Booking
	for rows.Next() {
		var b Booking
		if err := rows.Scan(&b.ID, &b.Key, &b.Parsed, &b.Status, &b.Version, &b.Attempts, &b.ForwarderRef); err != nil {
			return nil, fmt.Errorf("claim scan: %w", err)
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// Transition: 상태를 바꾸는 유일한 경로.
//   - 전이 표 검사 (Go 쪽) -> 거부 지표 + ErrTransitionRejected
//   - UPDATE ... WHERE id AND version = 기억한 값 (DB 쪽 낙관적 잠금)
//   - 새 단계이므로 attempts=0, 임대 해제, nextAt 은 다음 단계의 첫 시도 시각 (sent 면 5초 뒤 확인)
func (s *Store) Transition(ctx context.Context, b *Booking, to string, nextAt time.Time, forwarderRef *string, lastErr *string) error {
	if !transitionAllowed(b.Status, to) {
		transitionRejected.WithLabelValues(b.Status, to).Inc()
		logFrom(ctx).Warn("transition rejected", "from", b.Status, "to", to)
		return ErrTransitionRejected
	}
	tag, err := s.db.Exec(ctx, `
		UPDATE bookings
		   SET status = $3, version = version + 1, attempts = 0, next_attempt_at = $4,
		       claimed_until = NULL,
		       forwarder_ref = COALESCE($5, forwarder_ref),
		       last_error = $6
		 WHERE id = $1 AND version = $2`,
		b.ID, b.Version, to, nextAt, forwarderRef, lastErr)
	if err != nil {
		return fmt.Errorf("transition: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return s.conflict(ctx, b)
	}
	transitionsTotal.WithLabelValues(b.Status, to).Inc()
	logFrom(ctx).Info("transition applied", "from", b.Status, "to", to, "version", b.Version+1)
	return nil
}

// Reschedule: 이번 시도는 실패했고 다음에 다시 한다. 상태는 그대로, attempts+1, next_attempt_at 을 미룬다.
// 백오프 대기는 goroutine 이 자는 게 아니라 이 컬럼에 기록된다. 재시작해도 대기 시간이 유지된다.
func (s *Store) Reschedule(ctx context.Context, b *Booking, nextAt time.Time, lastErr string) error {
	tag, err := s.db.Exec(ctx, `
		UPDATE bookings
		   SET attempts = attempts + 1, next_attempt_at = $3, claimed_until = NULL,
		       last_error = $4, version = version + 1
		 WHERE id = $1 AND version = $2`,
		b.ID, b.Version, nextAt, lastErr)
	if err != nil {
		return fmt.Errorf("reschedule: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return s.conflict(ctx, b)
	}
	return nil
}

// conflict: 0행 갱신의 뒤처리. 행을 다시 읽어 "기대 version / 실제 version / 실제 status" 를 로그에 남긴다.
// 원인 분석에 필요한 정보는 남기되 어떤 복구 쓰기도 하지 않는다.
// 그 행이 아직 처리 대상이면 다음 폴링이 (새 version 으로) 다시 집어간다.
func (s *Store) conflict(ctx context.Context, b *Booking) error {
	versionConflicts.Inc()
	var curVersion int
	var curStatus string
	err := s.db.QueryRow(ctx, `SELECT version, status FROM bookings WHERE id = $1`, b.ID).Scan(&curVersion, &curStatus)
	if err != nil {
		logFrom(ctx).Warn("version conflict (re-read failed)", "expected_version", b.Version, "err", err.Error())
		return ErrVersionConflict
	}
	logFrom(ctx).Warn("version conflict, result discarded",
		"expected_version", b.Version, "actual_version", curVersion, "actual_status", curStatus)
	return ErrVersionConflict
}
