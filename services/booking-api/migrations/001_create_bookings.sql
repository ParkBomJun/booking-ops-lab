-- 001: bookings 테이블. 승인된 스키마 그대로.
CREATE TABLE IF NOT EXISTS bookings (
    id               BIGSERIAL PRIMARY KEY,
    idempotency_key  TEXT        NOT NULL UNIQUE,
    raw_text         TEXT        NOT NULL,
    parsed           JSONB,
    status           TEXT        NOT NULL DEFAULT 'received'
                     CHECK (status IN ('received','parsed','needs_review','sent','confirmed','failed')),
    needs_review     BOOLEAN     NOT NULL DEFAULT FALSE,
    review_reason    TEXT,
    version          INTEGER     NOT NULL DEFAULT 1,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bookings_needs_review ON bookings (created_at) WHERE needs_review;
CREATE INDEX IF NOT EXISTS idx_bookings_status ON bookings (status, created_at);

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_bookings_updated_at ON bookings;
CREATE TRIGGER trg_bookings_updated_at
BEFORE UPDATE ON bookings FOR EACH ROW EXECUTE FUNCTION set_updated_at();
