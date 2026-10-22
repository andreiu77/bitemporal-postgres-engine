-- =============================================================================
-- A1: The Database Manages Transaction Time Itself
-- =============================================================================
-- PART 1: Transaction Time Clock Resolver
-- Reads session simulated clock ('app.sim_now') if set; otherwise system clock.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_current_tx_time()
RETURNS TIMESTAMP(6) WITH TIME ZONE AS $$
BEGIN
    IF NULLIF(current_setting('app.sim_now', true), '') IS NOT NULL THEN
        RETURN current_setting('app.sim_now')::TIMESTAMP(6) WITH TIME ZONE;
    ELSE
        RETURN CURRENT_TIMESTAMP(6);
    END IF;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- PART 2: Guard Triggers on Bitemporal Tables
-- Enforces Rule 6 & Invariant I4:
--   1. Physical DELETE is strictly forbidden.
--   2. Modifying an already closed row (tx_to < sentinel) is forbidden.
--   3. Direct UPDATE of business columns (subscriber_id, plan_id, valid_from, valid_to) is forbidden.
--   4. Modifying tx_from is forbidden.
--   5. The ONLY allowed UPDATE is closing tx_to from sentinel to current time via the Write API.
-- =============================================================================
CREATE OR REPLACE FUNCTION trg_guard_subscription_version()
RETURNS TRIGGER AS $$
DECLARE
    v_allow_write TEXT := current_setting('app.allow_tt_write', true);
BEGIN
    -- 1. Disallow any physical DELETE (unless authorized)
    IF TG_OP = 'DELETE' THEN
        IF v_allow_write = 'cleanup' THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'Physical DELETE is strictly forbidden on bitemporal tables.';
    END IF;

    -- 2. On INSERT: enforce that inserts occur via the Write API
    IF TG_OP = 'INSERT' THEN
        IF v_allow_write IS DISTINCT FROM 'true' THEN
            RAISE EXCEPTION 'Direct INSERT into subscription_version is forbidden. Use the Write API.';
        END IF;
        NEW.tx_to := '9999-12-31 23:59:59.999999';
        RETURN NEW;
    END IF;

    -- 3. On UPDATE:
    IF TG_OP = 'UPDATE' THEN
        -- Check API authorization
        IF v_allow_write IS DISTINCT FROM 'true' THEN
            RAISE EXCEPTION 'Direct UPDATE is forbidden. Use the Write API procedures.';
        END IF;

        -- Invariant I4: Cannot modify an already closed historical row
        IF OLD.tx_to < '9999-12-31 23:59:59.999999' THEN
            RAISE EXCEPTION 'Cannot modify an already closed historical row';
        END IF;

        -- Cannot update business columns
        IF NEW.subscriber_id <> OLD.subscriber_id OR NEW.plan_id <> OLD.plan_id
         OR NEW.valid_from <> OLD.valid_from OR NEW.valid_to <> OLD.valid_to THEN
            RAISE EXCEPTION 'Direct UPDATE of business columns (subscriber_id, plan_id, valid_from, valid_to) is forbidden.';
        END IF;

        -- Cannot modify tx_from or tx_id
        IF NEW.tx_from <> OLD.tx_from OR NEW.tx_id <> OLD.tx_id THEN
            RAISE EXCEPTION 'Modifying tx_from or tx_id is forbidden.';
        END IF;

        -- The permitted update: closing tx_to on current version
        IF OLD.tx_to = '9999-12-31 23:59:59.999999' AND NEW.tx_to < OLD.tx_to THEN
            RETURN NEW;
        END IF;

        RAISE EXCEPTION 'Unrecognized or forbidden update pattern.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach trigger to subscription_version
DROP TRIGGER IF EXISTS trg_subscription_guard ON subscription_version;
CREATE TRIGGER trg_subscription_guard
BEFORE INSERT OR UPDATE OR DELETE ON subscription_version
FOR EACH ROW EXECUTE FUNCTION trg_guard_subscription_version();
 

-- =============================================================================
-- PART 3: The Write API

-- -----------------------------------------------------------------------------
-- 1. sp_assert_subscription
-- Asserts that a subscriber has a given plan starting at p_valid_from.
-- Handles both brand-new subscribers and plan switches (upgrades/downgrades).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_assert_subscription(
    p_subscriber_id INT,
    p_plan_id       INT,
    p_valid_from    DATE,
    p_author        VARCHAR(100),
    p_reason        VARCHAR(255)
)
LANGUAGE plpgsql AS $$
DECLARE
    v_now      TIMESTAMP(6) WITH TIME ZONE := fn_current_tx_time();
    v_tx_id    BIGINT;
    v_old_id   BIGINT;
    v_old_plan INT;
    v_old_from DATE;
BEGIN
    PERFORM set_config('app.allow_tt_write', 'true', true);

    -- 1. Open transaction in tx_registry
    INSERT INTO tx_registry (tx_time, author, reason)
    VALUES (v_now, p_author, p_reason)
    RETURNING tx_id INTO v_tx_id;

    -- 2. Check if subscriber currently has an active open-ended belief
    SELECT version_id, plan_id, valid_from
    INTO v_old_id, v_old_plan, v_old_from
    FROM subscription_version
    WHERE subscriber_id = p_subscriber_id
     AND tx_to = '9999-12-31 23:59:59.999999'
     AND valid_to = '9999-12-31';

    IF FOUND THEN
        -- Close the current belief in transaction time
        UPDATE subscription_version
        SET tx_to = v_now
        WHERE version_id = v_old_id;

        -- Insert capped prior period [old_from, p_valid_from)
        INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
        VALUES (p_subscriber_id, v_old_plan, v_old_from, p_valid_from, v_now, v_tx_id);

        -- Insert new plan period [p_valid_from, infinity)
        INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
        VALUES (p_subscriber_id, p_plan_id, p_valid_from, '9999-12-31', v_now, v_tx_id);
    ELSE
        -- Brand new subscription or restarting after a gap
        INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
        VALUES (p_subscriber_id, p_plan_id, p_valid_from, '9999-12-31', v_now, v_tx_id);
    END IF;
END;
$$;


-- -----------------------------------------------------------------------------
-- 2. sp_end_subscription
-- Records a real-world end/cancellation taking effect at p_valid_to.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_end_subscription(
    p_subscriber_id INT,
    p_valid_to      DATE,
    p_author        VARCHAR(100),
    p_reason        VARCHAR(255)
)
LANGUAGE plpgsql AS $$
DECLARE
    v_now    TIMESTAMP(6) WITH TIME ZONE := fn_current_tx_time();
    v_tx_id  BIGINT;
    v_old_id BIGINT;
    v_old_plan INT;
    v_old_from DATE;
BEGIN
    PERFORM set_config('app.allow_tt_write', 'true', true);

    INSERT INTO tx_registry (tx_time, author, reason)
    VALUES (v_now, p_author, p_reason)
    RETURNING tx_id INTO v_tx_id;

    SELECT version_id, plan_id, valid_from
    INTO v_old_id, v_old_plan, v_old_from
    FROM subscription_version
    WHERE subscriber_id = p_subscriber_id
     AND tx_to = '9999-12-31 23:59:59.999999'
     AND valid_to = '9999-12-31';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No open active subscription found to end for subscriber_id=%', p_subscriber_id;
    END IF;

    -- Close old belief in TT
    UPDATE subscription_version
    SET tx_to = v_now
    WHERE version_id = v_old_id;

    -- Insert new belief with finite valid_to
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
    VALUES (p_subscriber_id, v_old_plan, v_old_from, p_valid_to, v_now, v_tx_id);
END;
$$;


-- -----------------------------------------------------------------------------
-- 3. sp_correct_subscription
-- Corrects a previously recorded transition date.
-- Moves the boundary date between an adjoining plan change.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_correct_subscription(
    p_subscriber_id   INT,
    p_new_boundary    DATE,
    p_author          VARCHAR(100),
    p_reason          VARCHAR(255)
)
LANGUAGE plpgsql AS $$
DECLARE
    v_now    TIMESTAMP(6) WITH TIME ZONE := fn_current_tx_time();
    v_tx_id  BIGINT;
    v_vid1   BIGINT;
    v_vid2   BIGINT;
BEGIN
    PERFORM set_config('app.allow_tt_write', 'true', true);

    INSERT INTO tx_registry (tx_time, author, reason)
    VALUES (v_now, p_author, p_reason)
    RETURNING tx_id INTO v_tx_id;

    -- Find the active capped old plan and the active open new plan
    SELECT version_id INTO v_vid1
    FROM subscription_version
    WHERE subscriber_id = p_subscriber_id
     AND valid_to <> '9999-12-31'
     AND tx_to = '9999-12-31 23:59:59.999999'
    ORDER BY valid_to DESC LIMIT 1;

    SELECT version_id INTO v_vid2
    FROM subscription_version
    WHERE subscriber_id = p_subscriber_id
     AND valid_to = '9999-12-31'
     AND tx_to = '9999-12-31 23:59:59.999999';

    IF v_vid1 IS NULL OR v_vid2 IS NULL THEN
        RAISE EXCEPTION 'Could not locate adjoining subscription rows to correct for subscriber_id=%', p_subscriber_id;
    END IF;

    -- Close both old beliefs in TT
    UPDATE subscription_version 
    SET tx_to = v_now 
    WHERE version_id IN (v_vid1, v_vid2);

    -- Re-insert period 1 with corrected end date
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
    SELECT subscriber_id, plan_id, valid_from, p_new_boundary, v_now, v_tx_id
    FROM subscription_version WHERE version_id = v_vid1;

    -- Re-insert period 2 with corrected start date
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
    SELECT subscriber_id, plan_id, p_new_boundary, valid_to, v_now, v_tx_id
    FROM subscription_version WHERE version_id = v_vid2;
END;
$$;


-- -----------------------------------------------------------------------------
-- 4. sp_retract_subscription
-- Undoes a mistake that was "never true" (E8).
-- Closes the mistaken belief in TT with NO replacement and restores the original.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_retract_subscription(
    p_subscriber_id INT,
    p_author        VARCHAR(100),
    p_reason        VARCHAR(255)
)
LANGUAGE plpgsql AS $$
DECLARE
    v_now        TIMESTAMP(6) WITH TIME ZONE := fn_current_tx_time();
    v_tx_id      BIGINT;
    v_mistake_id BIGINT;
    v_prior_id   BIGINT;
BEGIN
    PERFORM set_config('app.allow_tt_write', 'true', true);

    INSERT INTO tx_registry (tx_time, author, reason)
    VALUES (v_now, p_author, p_reason)
    RETURNING tx_id INTO v_tx_id;

    -- 1. Identify the mistaken current row
    SELECT version_id INTO v_mistake_id
    FROM subscription_version
    WHERE subscriber_id = p_subscriber_id
     AND tx_to = '9999-12-31 23:59:59.999999'
     AND valid_to = '9999-12-31';

    -- 2. Identify the capped prior row
    SELECT version_id INTO v_prior_id
    FROM subscription_version
    WHERE subscriber_id = p_subscriber_id
     AND tx_to = '9999-12-31 23:59:59.999999'
     AND valid_to <> '9999-12-31'
    ORDER BY valid_to DESC LIMIT 1;

    IF v_mistake_id IS NULL OR v_prior_id IS NULL THEN
        RAISE EXCEPTION 'Could not locate mistaken and prior rows for retraction (subscriber_id=%)', p_subscriber_id;
    END IF;

    -- Close both in transaction time
    UPDATE subscription_version 
    SET tx_to = v_now 
    WHERE version_id IN (v_mistake_id, v_prior_id);

    -- Restore original belief as open-ended
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id)
    SELECT subscriber_id, plan_id, valid_from, '9999-12-31', v_now, v_tx_id
    FROM subscription_version WHERE version_id = v_prior_id;
END;
$$;


-- =============================================================================
-- PART 4: Negative Test Suite (Proving Forbidden Operations Fail)
-- =============================================================================

\echo '========================================================================'
\echo 'A1 Negative Tests: Verifying that all forbidden operations are rejected'
\echo '========================================================================'

\echo '--- Test N1: Attempting physical DELETE ---'
DO $$
BEGIN
    DELETE FROM subscription_version WHERE subscriber_id = 1;
    RAISE EXCEPTION 'TEST FAILED: Physical DELETE should have been rejected!';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Physical DELETE is strictly forbidden%' THEN
            RAISE NOTICE 'SUCCESS: Physical DELETE was blocked. Caught: %', SQLERRM;
        ELSE
            RAISE;
        END IF;
END $$;


\echo '--- Test N2: Attempting direct UPDATE of plan_id ---'
DO $$
BEGIN
    UPDATE subscription_version SET plan_id = 5 WHERE subscriber_id = 1;
    RAISE EXCEPTION 'TEST FAILED: Direct business UPDATE should have been rejected!';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Direct UPDATE is forbidden%' OR SQLERRM LIKE '%Direct UPDATE of business columns is forbidden%' THEN
            RAISE NOTICE 'SUCCESS: Direct business column UPDATE was blocked. Caught: %', SQLERRM;
        ELSE
            RAISE;
        END IF;
END $$;


\echo '--- Test N3: Attempting to modify an already closed historical row ---'
DO $$
BEGIN
    -- version_id = 5 was closed back in E3 (tx_to is in the past)
    UPDATE subscription_version SET tx_to = CURRENT_TIMESTAMP WHERE version_id = 5;
    RAISE EXCEPTION 'TEST FAILED: Updating closed row should have been rejected!';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Cannot modify an already closed historical row%' OR SQLERRM LIKE '%Direct UPDATE is forbidden%' THEN
            RAISE NOTICE 'SUCCESS: Modifying closed history was blocked. Caught: %', SQLERRM;
        ELSE
            RAISE;
        END IF;
END $$;


\echo '--- Test N4: Attempting direct INSERT bypassing the Write API ---'
DO $$
BEGIN
    INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, tx_from, tx_id)
    VALUES (1, 3, '2026-01-01', CURRENT_TIMESTAMP, 1);
    RAISE EXCEPTION 'TEST FAILED: Direct INSERT should have been rejected!';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Direct INSERT into subscription_version is forbidden%' THEN
            RAISE NOTICE 'SUCCESS: Direct INSERT was blocked. Caught: %', SQLERRM;
        ELSE
            RAISE;
        END IF;
END $$;


-- =============================================================================
-- PART 5: Write API demo

\echo ''
\echo '========================================================================'
\echo 'A1 Positive Test: Demonstrating Write API operations on a test subscriber'
\echo '========================================================================'

-- Insert a test subscriber anchor
INSERT INTO subscriber (subscriber_id, email, join_date)
VALUES (999, 'test_a1@example.com', '2026-01-01');

-- 1. Assert: New subscription on Plan 1 starting 2026-01-01
CALL sp_assert_subscription(999, 1, '2026-01-01', 'clerk', 'A1 Demo: initial subscription');

-- 2. Assert: Upgrade to Plan 3 starting 2026-04-01
CALL sp_assert_subscription(999, 3, '2026-04-01', 'clerk', 'A1 Demo: upgrade to Plan 3');

-- 3. Correct: Auditor notices upgrade was actually on 2026-04-05
CALL sp_correct_subscription(999, '2026-04-05', 'auditor', 'A1 Demo: correct upgrade boundary to Apr 5');

-- 4. End: Cancellation effective 2026-10-01
CALL sp_end_subscription(999, '2026-10-01', 'user', 'A1 Demo: cancellation effective Oct 1');

\echo '--- Final historical versions created automatically for Subscriber 999: ---'
SELECT version_id, subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_to, tx_id
FROM subscription_version
WHERE subscriber_id = 999
ORDER BY version_id;

-- Cleanup the test subscriber so database remains clean
DO $$
BEGIN
    PERFORM set_config('app.allow_tt_write', 'cleanup', true);
    DELETE FROM subscription_version WHERE subscriber_id = 999;
    DELETE FROM subscriber WHERE subscriber_id = 999;
    RAISE NOTICE 'A1 Demo: Cleaned up test subscriber 999 successfully.';
END $$;
