-- 04_views.sql: Temporal Questions (Q0-Q8)
-- Views and SQL table functions for querying the bitemporal data.

-- ============================================================================
-- Q0: Integrity Violations
-- Returns every row that breaks I1, I2, or I3.
-- Must return ZERO rows on clean data.
-- ============================================================================
CREATE OR REPLACE VIEW v_integrity_violations AS

-- I1: Temporal entity integrity (subscription)
-- Among current-TT rows, valid periods for the same subscriber must not overlap.
SELECT 'I1'::TEXT AS invariant, 'subscription_version'::TEXT AS table_name,
       a.version_id AS row_a, b.version_id AS row_b,
       ('Overlapping valid periods for subscriber_id=' || a.subscriber_id)::TEXT AS description
FROM subscription_version a
JOIN subscription_version b
    ON a.subscriber_id = b.subscriber_id
    AND a.version_id < b.version_id
    AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to
WHERE a.tx_to = '9999-12-31 23:59:59.999999'
  AND b.tx_to = '9999-12-31 23:59:59.999999'

UNION ALL

-- I1: Temporal entity integrity (title licence)
-- Among current-TT rows, valid periods for the same (title_id, region_id) must not overlap.
SELECT 'I1', 'title_licence_version',
       a.version_id, b.version_id,
       'Overlapping valid periods for title_id=' || a.title_id || ', region_id=' || a.region_id
FROM title_licence_version a
JOIN title_licence_version b
    ON a.title_id = b.title_id AND a.region_id = b.region_id
    AND a.version_id < b.version_id
    AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to
WHERE a.tx_to = '9999-12-31 23:59:59.999999'
  AND b.tx_to = '9999-12-31 23:59:59.999999'

UNION ALL

-- I2: Temporal referential integrity
-- A subscription's entire [valid_from, valid_to) must be covered by the union of
-- plan_price_version rows.
SELECT 'I2', 'subscription_version',
       sv.version_id, NULL::BIGINT,
       'Subscription period not fully covered by plan prices for plan_id=' || sv.plan_id
FROM subscription_version sv
WHERE sv.tx_to = '9999-12-31 23:59:59.999999'
  AND (
      NOT EXISTS (
          SELECT 1 FROM plan_price_version ppv
          WHERE ppv.plan_id = sv.plan_id
            AND ppv.tx_to = '9999-12-31 23:59:59.999999'
            AND ppv.valid_from <= sv.valid_from
            AND sv.valid_from < ppv.valid_to
      )
      OR NOT EXISTS (
          SELECT 1 FROM plan_price_version ppv
          WHERE ppv.plan_id = sv.plan_id
            AND ppv.tx_to = '9999-12-31 23:59:59.999999'
            AND ppv.valid_from < sv.valid_to
            AND sv.valid_to <= ppv.valid_to
      )
  )

UNION ALL

-- I3: Single role holder
-- At most one price per plan at any valid instant (among current-TT rows).
SELECT 'I3', 'plan_price_version',
       a.version_id, b.version_id,
       'Multiple prices for plan_id=' || a.plan_id
FROM plan_price_version a
JOIN plan_price_version b
    ON a.plan_id = b.plan_id
    AND a.version_id < b.version_id
    AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to
WHERE a.tx_to = '9999-12-31 23:59:59.999999'
  AND b.tx_to = '9999-12-31 23:59:59.999999';


-- ============================================================================
-- Q1: Current facts for one subscriber
-- Valid today AND current in TT.
-- ============================================================================
CREATE OR REPLACE FUNCTION v_current_facts(p_subscriber_id INT)
RETURNS TABLE (
    version_id    BIGINT,
    subscriber_id INT,
    plan_id       INT,
    plan_name     VARCHAR(50),
    valid_from    DATE,
    valid_to      DATE
) AS $$
    SELECT sv.version_id, sv.subscriber_id, sv.plan_id, p.name,
           sv.valid_from, sv.valid_to
    FROM subscription_version sv
    JOIN plan p ON sv.plan_id = p.plan_id
    WHERE sv.subscriber_id = p_subscriber_id
      AND sv.valid_from <= CURRENT_DATE
      AND CURRENT_DATE < sv.valid_to
      AND sv.tx_to = '9999-12-31 23:59:59.999999';
$$ LANGUAGE SQL;


-- ============================================================================
-- Q2: Full history of a role holder for one central object
-- Price history for one plan, as known today, with tenure length.
-- Adjacent periods with the same price are coalesced.
-- ============================================================================
CREATE OR REPLACE FUNCTION v_role_history(p_plan_id INT)
RETURNS TABLE (
    plan_id     INT,
    price_eur   DECIMAL(10,2),
    valid_from  DATE,
    valid_to    DATE,
    tenure_days INT
) AS $$
    WITH ordered_prices AS (
        -- Step 1: compute LAG values in isolation (cannot nest window functions)
        SELECT ppv.plan_id, ppv.price_eur, ppv.valid_from, ppv.valid_to,
               LAG(ppv.price_eur) OVER (ORDER BY ppv.valid_from) AS prev_price,
               LAG(ppv.valid_to)  OVER (ORDER BY ppv.valid_from) AS prev_valid_to
        FROM plan_price_version ppv
        WHERE ppv.plan_id = p_plan_id
          AND ppv.tx_to = '9999-12-31 23:59:59.999999'
    ),
    current_prices AS (
        -- Step 2: assign island group using the pre-computed LAG values
        SELECT plan_id, price_eur, valid_from, valid_to,
               SUM(CASE
                    WHEN price_eur = prev_price AND valid_from = prev_valid_to THEN 0 
                    ELSE 1
                   END
                  ) OVER (ORDER BY valid_from) AS grp
        FROM ordered_prices
    )
    -- Step 3: compute the final result by aggregating per group
    SELECT cp.plan_id, cp.price_eur, MIN(cp.valid_from)::DATE, MAX(cp.valid_to)::DATE,
           CASE 
            WHEN MAX(cp.valid_to) = '9999-12-31'::DATE THEN NULL
            ELSE (MAX(cp.valid_to) - MIN(cp.valid_from))::INT
           END
    FROM current_prices cp
    GROUP BY cp.plan_id, cp.price_eur, cp.grp
    ORDER BY MIN(cp.valid_from);
$$ LANGUAGE SQL;


-- ============================================================================
-- Q3: Classified changes (Late, Proactive, Correction)
-- Shows delay in days and old vs new value side by side.
-- Every E2, E3, and E4 event from the story log appears, correctly labelled.
-- ============================================================================
CREATE OR REPLACE VIEW v_classified_changes AS
WITH raw_price_changes AS (
    SELECT
        'plan_price'::TEXT   AS entity,
        new_v.plan_id        AS key_id,
        CASE
            -- Correction type A: replaces a non-E1 row with same price (date fix)
            WHEN old_v.tx_id > 1 AND new_v.price_eur = old_v.price_eur THEN 'Correction'
            -- Correction type B: same valid period, different value (price fix)
            WHEN new_v.valid_from = old_v.valid_from
                 AND new_v.valid_to = old_v.valid_to
                 AND new_v.price_eur != old_v.price_eur THEN 'Correction'
            -- Proactive: takes effect in the future
            WHEN new_v.valid_from > new_v.tx_from::DATE THEN 'Proactive'
            -- Late: recorded 7+ days after it happened
            WHEN new_v.tx_from::DATE - new_v.valid_from >= 7 THEN 'Late'
            ELSE 'Normal'
        END                   AS change_type,
        -- Corrections: days between original entry and fix (new_v.tx_from - old_v.tx_from)
        -- Late/Proactive: days between real-world date and recording (tx_from - valid_from)
        CASE
            WHEN (old_v.tx_id > 1 AND new_v.price_eur = old_v.price_eur)
              OR (new_v.valid_from = old_v.valid_from
                  AND new_v.valid_to = old_v.valid_to
                  AND new_v.price_eur != old_v.price_eur)
            THEN (new_v.tx_from::DATE - old_v.tx_from::DATE)
            ELSE ABS(new_v.tx_from::DATE - new_v.valid_from)
        END                   AS delay_days,
        old_v.price_eur::TEXT AS old_value,
        new_v.price_eur::TEXT AS new_value,
        old_v.valid_from      AS old_valid_from,
        old_v.valid_to        AS old_valid_to,
        new_v.valid_from      AS new_valid_from,
        new_v.valid_to        AS new_valid_to,
        new_v.tx_from
    FROM plan_price_version new_v
    JOIN plan_price_version old_v
        ON new_v.plan_id = old_v.plan_id
        AND old_v.tx_to = new_v.tx_from
    WHERE new_v.tx_id > 1
      -- Exclude capped old rows (same price, same start, shorter end)
      AND NOT (new_v.valid_from = old_v.valid_from
               AND new_v.price_eur = old_v.price_eur
               AND new_v.valid_to < old_v.valid_to)
      -- For different-price pairs, require genuine succession: new period must start within the old period
      AND (new_v.price_eur = old_v.price_eur
           OR (new_v.valid_from >= old_v.valid_from
               AND new_v.valid_from <= old_v.valid_to))
),
raw_sub_changes AS (
    SELECT
        'subscription'::TEXT AS entity,
        new_v.subscriber_id  AS key_id,
        CASE
            -- Correction: replaces a non-E1 row with same plan and different boundary
            WHEN old_v.tx_id > 1
                 AND new_v.plan_id = old_v.plan_id
                 AND (new_v.valid_from != old_v.valid_from OR new_v.valid_to != old_v.valid_to)
                 AND NOT (new_v.valid_to = '9999-12-31' AND old_v.valid_to != '9999-12-31')
                 THEN 'Correction'
            -- Plan change (upgrade/downgrade): new period must start within old period
            -- (same succession constraint as plan_price to avoid cross-join false positives)
            WHEN new_v.plan_id != old_v.plan_id
                 AND new_v.valid_from >= old_v.valid_from
                 AND new_v.valid_from <= old_v.valid_to THEN
                CASE
                    WHEN new_v.valid_from > new_v.tx_from::DATE THEN 'Proactive'
                    WHEN new_v.tx_from::DATE - new_v.valid_from >= 7 THEN 'Late'
                    ELSE 'Normal'
                END
            ELSE -- Cancellation: same plan, shorter valid_to
                CASE
                    WHEN new_v.valid_to::DATE > new_v.tx_from::DATE THEN 'Proactive'
                    ELSE 'Normal'
                END
        END                  AS change_type,
        -- Corrections: days between original entry and fix
        CASE
            WHEN old_v.tx_id > 1
                 AND new_v.plan_id = old_v.plan_id
                 AND (new_v.valid_from != old_v.valid_from OR new_v.valid_to != old_v.valid_to)
                 AND NOT (new_v.valid_to = '9999-12-31' AND old_v.valid_to != '9999-12-31')
                THEN (new_v.tx_from::DATE - old_v.tx_from::DATE)
            WHEN new_v.plan_id != old_v.plan_id
                THEN ABS(new_v.tx_from::DATE - new_v.valid_from)
            WHEN new_v.valid_to != '9999-12-31'
                THEN ABS(new_v.tx_from::DATE - new_v.valid_to::DATE)
            ELSE ABS(new_v.tx_from::DATE - new_v.valid_from)
        END                  AS delay_days,
        old_v.plan_id::TEXT  AS old_value,
        new_v.plan_id::TEXT  AS new_value,
        old_v.valid_from     AS old_valid_from,
        old_v.valid_to       AS old_valid_to,
        new_v.valid_from     AS new_valid_from,
        new_v.valid_to       AS new_valid_to,
        new_v.tx_from
    FROM subscription_version new_v
    JOIN subscription_version old_v
        ON new_v.subscriber_id = old_v.subscriber_id
        AND old_v.tx_to = new_v.tx_from
    WHERE new_v.tx_id > 1
      AND (
          -- Plan change: genuine succession (new period starts within old period)
          (new_v.plan_id != old_v.plan_id
           AND new_v.valid_from >= old_v.valid_from
           AND new_v.valid_from <= old_v.valid_to)
          -- Cancellation: same plan, valid period shortened
          OR (new_v.valid_to < old_v.valid_to AND new_v.plan_id = old_v.plan_id)
          -- Correction: same plan, boundary changed, not a sentinel restoration
          OR (old_v.tx_id > 1
              AND new_v.plan_id = old_v.plan_id
              AND (new_v.valid_from != old_v.valid_from OR new_v.valid_to != old_v.valid_to)
              AND NOT (new_v.valid_to = '9999-12-31' AND old_v.valid_to != '9999-12-31'))
      )
)
-- Only show Proactive, Late, and Correction rows (filter out Normal E5/E7/E8/E9)
SELECT * FROM raw_price_changes  WHERE change_type IN ('Proactive', 'Late', 'Correction')
UNION ALL
SELECT * FROM raw_sub_changes    WHERE change_type IN ('Proactive', 'Late', 'Correction')
ORDER BY tx_from, entity;


-- ============================================================================
-- Q4: Relationships valid during a named period
-- Two columns: at_some_point (overlap) vs throughout (containment).
-- ============================================================================
CREATE OR REPLACE FUNCTION v_during_period(p_start DATE, p_end DATE)
RETURNS TABLE (
    subscriber_id INT,
    plan_id       INT,
    plan_name     VARCHAR(50),
    at_some_point BOOLEAN,
    throughout    BOOLEAN
) AS $$
    SELECT
        sv.subscriber_id,
        sv.plan_id,
        p.name,
        TRUE,
        (sv.valid_from <= p_start AND p_end <= sv.valid_to)
    FROM subscription_version sv
    JOIN plan p ON sv.plan_id = p.plan_id
    WHERE sv.tx_to = '9999-12-31 23:59:59.999999'
      AND sv.valid_from < p_end
      AND p_start < sv.valid_to
    ORDER BY sv.subscriber_id, sv.plan_id;
$$ LANGUAGE SQL;


-- ============================================================================
-- Q5: Snapshot at a transaction time
-- "What did the system know on <known_at>?" — all subscription rows, any valid time.
-- ============================================================================
CREATE OR REPLACE FUNCTION v_snapshot_at(p_known_at TIMESTAMP WITH TIME ZONE)
RETURNS TABLE (
    version_id    BIGINT,
    subscriber_id INT,
    plan_id       INT,
    plan_name     VARCHAR(50),
    valid_from    DATE,
    valid_to      DATE,
    tx_from       TIMESTAMP(6) WITH TIME ZONE,
    tx_to         TIMESTAMP(6) WITH TIME ZONE
) AS $$
    SELECT sv.version_id, sv.subscriber_id, sv.plan_id, p.name,
           sv.valid_from, sv.valid_to, sv.tx_from, sv.tx_to
    FROM subscription_version sv
    JOIN plan p ON sv.plan_id = p.plan_id
    WHERE sv.tx_from <= p_known_at
      AND p_known_at < sv.tx_to;
$$ LANGUAGE SQL;


-- ============================================================================
-- Q6: Bitemporal point query
-- Facts valid at valid_at as known at known_at.
-- Reproduces the three-answer Story from Part B for Subscriber 5.
-- Evaluated on subscription_version (the largest version table), so EXPLAIN
-- ANALYZE directly measures the as-of index ix_subscription_asof.
-- ============================================================================
CREATE OR REPLACE FUNCTION v_bitemporal_point(
    p_subscriber_id INT,
    p_valid_at      DATE,
    p_known_at      TIMESTAMP WITH TIME ZONE
)
RETURNS TABLE (
    version_id    BIGINT,
    subscriber_id INT,
    plan_id       INT,
    plan_name     VARCHAR(50),
    valid_from    DATE,
    valid_to      DATE,
    tx_from       TIMESTAMP(6) WITH TIME ZONE,
    tx_to         TIMESTAMP(6) WITH TIME ZONE
) AS $$
    SELECT sv.version_id, sv.subscriber_id, sv.plan_id, p.name,
           sv.valid_from, sv.valid_to, sv.tx_from, sv.tx_to
    FROM subscription_version sv
    JOIN plan p ON sv.plan_id = p.plan_id
    WHERE sv.subscriber_id = p_subscriber_id
      AND sv.valid_from <= p_valid_at AND p_valid_at < sv.valid_to
      AND sv.tx_from   <= p_known_at AND p_known_at < sv.tx_to;
$$ LANGUAGE SQL;


-- ============================================================================
-- Q7: Monthly count of active subscriptions per plan, as known today.
-- Uses a recursive CTE calendar. Months with zero still appear.
-- ============================================================================
CREATE OR REPLACE VIEW v_monthly_counts AS
WITH RECURSIVE months AS (
    SELECT DATE '2025-01-01' AS month_start
    UNION ALL
    SELECT (month_start + INTERVAL '1 month')::DATE
    FROM months WHERE month_start < '2025-12-01'
)
SELECT
    m.month_start,
    p.plan_id,
    p.name AS plan_name,
    COUNT(DISTINCT sv.subscriber_id) AS active_subscribers
FROM months m
CROSS JOIN plan p
LEFT JOIN subscription_version sv
    ON sv.plan_id = p.plan_id
    AND sv.tx_to = '9999-12-31 23:59:59.999999'
    AND sv.valid_from < (m.month_start + INTERVAL '1 month')::DATE
    AND m.month_start < sv.valid_to
GROUP BY m.month_start, p.plan_id, p.name
ORDER BY m.month_start, p.plan_id;


-- ============================================================================
-- Q8: Gaps between consecutive valid periods of the same (subscriber, plan) pair
-- Uses LAG window function. Finds every E6 event.
-- ============================================================================
CREATE OR REPLACE VIEW v_gaps AS
WITH current_subs AS (
    SELECT
        sv.subscriber_id,
        sv.plan_id,
        sv.valid_from,
        sv.valid_to,
        LAG(sv.valid_to) OVER (
            PARTITION BY sv.subscriber_id, sv.plan_id
            ORDER BY sv.valid_from
        ) AS prev_valid_to
    FROM subscription_version sv
    WHERE sv.tx_to = '9999-12-31 23:59:59.999999'
)
SELECT
    cs.subscriber_id,
    cs.plan_id,
    p.name AS plan_name,
    cs.prev_valid_to AS gap_start,
    cs.valid_from    AS gap_end,
    cs.valid_from - cs.prev_valid_to AS gap_days
FROM current_subs cs
JOIN plan p ON cs.plan_id = p.plan_id
WHERE cs.prev_valid_to IS NOT NULL
  AND cs.valid_from > cs.prev_valid_to
ORDER BY cs.subscriber_id, cs.plan_id, cs.prev_valid_to;
