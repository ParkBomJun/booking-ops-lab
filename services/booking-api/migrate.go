package main

import (
	"context"
	"embed" // 파일을 바이너리 안에 포함시키는 표준 기능 (Go 1.16+)
	"fmt"
	"log/slog"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"
)

// go:embed 지시문: 빌드 시 migrations/ 아래 .sql 파일을 바이너리에 통째로 넣는다.
// 덕분에 distroless 컨테이너에 SQL 파일을 따로 복사할 필요가 없고, 바이너리 하나가 곧 배포 단위가 된다.
//
//go:embed migrations/*.sql
var migrationFiles embed.FS

// 두 인스턴스가 동시에 떠도 마이그레이션이 한 번만 돌게 하는 advisory lock 의 키.
// 임의의 고정 정수. pg_advisory_lock 은 "이 숫자를 잡은 세션이 있으면 대기" 하는 세션 수준 잠금.
const migrationLockKey = 724_001

// runMigrations: schema_migrations 에 기록되지 않은 파일을 이름순으로 적용한다.
func runMigrations(ctx context.Context, pool *pgxpool.Pool) error {
	// 풀이 아니라 단일 연결을 빌려온다. advisory lock 은 "세션(연결)" 에 묶이므로
	// 잠금을 잡은 연결과 SQL 을 실행하는 연결이 같아야 한다.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire conn: %w", err)
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", migrationLockKey); err != nil {
		return fmt.Errorf("advisory lock: %w", err)
	}
	// 함수가 어떻게 끝나든 잠금을 풀어준다.
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", migrationLockKey) //nolint:errcheck

	_, err = conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version    TEXT        PRIMARY KEY,
		applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`)
	if err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	entries, err := migrationFiles.ReadDir("migrations")
	if err != nil {
		return fmt.Errorf("read embedded migrations: %w", err)
	}
	// ReadDir 은 이름순 정렬을 보장하지만, "순서가 핵심" 임을 코드로 드러내기 위해 명시한다.
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })

	for _, e := range entries {
		name := e.Name()
		version := name[:len(name)-len(".sql")] // "001_create_bookings"

		var exists bool
		err := conn.QueryRow(ctx,
			"SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)", version).Scan(&exists)
		if err != nil {
			return fmt.Errorf("check %s: %w", version, err)
		}
		if exists {
			continue
		}

		sqlBytes, err := migrationFiles.ReadFile("migrations/" + name)
		if err != nil {
			return fmt.Errorf("read %s: %w", name, err)
		}

		// 한 파일 = 한 트랜잭션. 중간에 실패하면 그 파일의 변경은 전부 롤백되고 기록도 남지 않는다.
		// 다음 시작 때 같은 파일을 처음부터 다시 시도하게 된다.
		tx, err := conn.Begin(ctx)
		if err != nil {
			return fmt.Errorf("begin %s: %w", version, err)
		}
		if _, err := tx.Exec(ctx, string(sqlBytes)); err != nil {
			tx.Rollback(ctx) //nolint:errcheck
			return fmt.Errorf("apply %s: %w", version, err)
		}
		if _, err := tx.Exec(ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", version); err != nil {
			tx.Rollback(ctx) //nolint:errcheck
			return fmt.Errorf("record %s: %w", version, err)
		}
		if err := tx.Commit(ctx); err != nil {
			return fmt.Errorf("commit %s: %w", version, err)
		}
		slog.Info("migration applied", "version", version)
	}
	return nil
}
