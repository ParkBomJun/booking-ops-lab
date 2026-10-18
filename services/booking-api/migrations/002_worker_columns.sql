-- 002: worker 가 포워더 전송·확인을 처리하는 데 필요한 컬럼.
-- status 에는 새 값을 추가하지 않는다. "처리 중" 은 claimed_until(임대) 로만 표현하고,
-- status 는 비즈니스 상태(parsed/sent/confirmed/failed ...)만 담는다.

-- attempts: 현재 단계(send 또는 confirm)에서 시도한 횟수. 단계가 바뀌면 0 으로 되돌린다.
-- next_attempt_at: 이 시각 전에는 worker 가 집어가지 않는다. 지수 백오프를 DB 에 저장하는 자리.
--   DEFAULT now() 이므로 API 가 새로 넣은 행(status=parsed)은 즉시 대상이 된다.
-- claimed_until: 임대 만료 시각. NULL 이면 아무도 처리 중이 아님. 값이 있고 미래면 다른 worker 가 처리 중.
--   worker 가 HTTP 호출 중 죽어도 이 시각이 지나면 자동으로 다시 대상이 된다 (복구 로직 불필요).
-- forwarder_ref: 포워더가 POST 응답으로 준 참조번호. sent 이후 상태 조회(GET)에 쓴다.
-- last_error: 마지막 실패 사유. failed 행의 원인 분석용. 성공하면 NULL 로 지운다.
ALTER TABLE bookings
    ADD COLUMN IF NOT EXISTS attempts        INTEGER     NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS claimed_until   TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS forwarder_ref   TEXT,
    ADD COLUMN IF NOT EXISTS last_error      TEXT;

-- worker 의 claim 쿼리는 "status IN (parsed, sent) AND next_attempt_at <= now()" 로 찾는다.
-- 부분 인덱스(WHERE 절): 대상이 될 수 있는 두 상태의 행만 색인한다.
-- confirmed/failed 가 쌓여 테이블이 커져도 이 인덱스는 작게 유지되어 폴링 비용이 일정하다.
CREATE INDEX IF NOT EXISTS idx_bookings_worker_eligible
    ON bookings (next_attempt_at)
    WHERE status IN ('parsed', 'sent');
