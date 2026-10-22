-- =============================================================================
-- A2: Native Temporal Features
-- Re-implements Q1, Q5, and Q6 using PostgreSQL native temporal syntax and
-- proves each returns identical rows to the core version in 04_views.sql.
-- =============================================================================


-- =============================================================================
-- Q1
-- Native rewrite:
--   daterange(valid_from, valid_to) @> CURRENT_DATE   -- valid period contains today
--   AND tstzrange(tx_from, tx_to)  @> now()           -- tx period contains now
-- =============================================================================
CREATE OR REPLACE FUNCTION v_current_facts_native(p_subscriber_id INT)
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
      AND daterange(sv.valid_from, sv.valid_to) @> CURRENT_DATE
      AND tstzrange(sv.tx_from,    sv.tx_to)    @> now();
$$ LANGUAGE SQL;

-- =============================================================================
-- Q5:
-- Native rewrite:
--   tstzrange(tx_from, tx_to) @> p_known_at
-- =============================================================================
CREATE OR REPLACE FUNCTION v_snapshot_at_native(
    p_known_at TIMESTAMP WITH TIME ZONE
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
    WHERE tstzrange(sv.tx_from, sv.tx_to) @> p_known_at;
$$ LANGUAGE SQL;


-- =============================================================================
-- Q6
-- Native rewrite:
--   daterange(valid_from, valid_to) @> p_valid_at
--   AND tstzrange(tx_from, tx_to)   @> p_known_at
-- =============================================================================
CREATE OR REPLACE FUNCTION v_bitemporal_point_native(
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
      AND daterange(sv.valid_from, sv.valid_to) @> p_valid_at
      AND tstzrange(sv.tx_from,    sv.tx_to)    @> p_known_at;
$$ LANGUAGE SQL;


-- =============================================================================
-- VERIFICATION: prove native functions return identical rows to core functions
-- Each pair of EXCEPT queries must return zero rows.
-- =============================================================================

\echo '========================================================================'
\echo 'A2 Verification: Native vs Core'
\echo '========================================================================'

\echo ''
\echo '--- Q1: v_current_facts vs v_current_facts_native (subscriber_id = 1) ---'
\echo 'Core result:'
SELECT * FROM v_current_facts(1);

\echo 'Native result:'
SELECT * FROM v_current_facts_native(1);

\echo 'Core EXCEPT Native (expect 0 rows):'
SELECT version_id FROM v_current_facts(1)
EXCEPT
SELECT version_id FROM v_current_facts_native(1);

\echo 'Native EXCEPT Core (expect 0 rows):'
SELECT version_id FROM v_current_facts_native(1)
EXCEPT
SELECT version_id FROM v_current_facts(1);


\echo ''
\echo '--- Q5: v_snapshot_at vs v_snapshot_at_native (2025-03-10 15:00:00+00) ---'
\echo 'Core result (first 10 rows):'
SELECT version_id, subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_to
FROM v_snapshot_at('2025-03-10 15:00:00+00')
ORDER BY version_id
LIMIT 10;

\echo 'Native result (first 10 rows):'
SELECT version_id, subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_to
FROM v_snapshot_at_native('2025-03-10 15:00:00+00')
ORDER BY version_id
LIMIT 10;

\echo 'Core EXCEPT Native (expect 0 rows):'
SELECT version_id FROM v_snapshot_at('2025-03-10 15:00:00+00')
EXCEPT
SELECT version_id FROM v_snapshot_at_native('2025-03-10 15:00:00+00');

\echo 'Native EXCEPT Core (expect 0 rows):'
SELECT version_id FROM v_snapshot_at_native('2025-03-10 15:00:00+00')
EXCEPT
SELECT version_id FROM v_snapshot_at('2025-03-10 15:00:00+00');


\echo ''
\echo '--- Q6: v_bitemporal_point vs v_bitemporal_point_native ---'
\echo '    Subscriber 5, valid_at 2025-03-02, three known_at values'
\echo ''
\echo 'Answer 1 — known_at 2025-03-05 (before E3): expect Plan 1'
\echo 'Core:'
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-05 10:00:00+00');
\echo 'Native:'
SELECT * FROM v_bitemporal_point_native(5, '2025-03-02', '2025-03-05 10:00:00+00');

\echo ''
\echo 'Answer 2 — known_at 2025-03-12 (after E3, before E4): expect Plan 5'
\echo 'Core:'
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-12 10:00:00+00');
\echo 'Native:'
SELECT * FROM v_bitemporal_point_native(5, '2025-03-02', '2025-03-12 10:00:00+00');

\echo ''
\echo 'Answer 3 — known_at 2025-03-16 (after E4): expect Plan 1'
\echo 'Core:'
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-16 10:00:00+00');
\echo 'Native:'
SELECT * FROM v_bitemporal_point_native(5, '2025-03-02', '2025-03-16 10:00:00+00');

\echo ''
\echo 'Q6 EXCEPT checks across all three known_at values (expect 0 rows each):'

\echo 'known_at 2025-03-05 — Core EXCEPT Native:'
SELECT version_id FROM v_bitemporal_point(5, '2025-03-02', '2025-03-05 10:00:00+00')
EXCEPT
SELECT version_id FROM v_bitemporal_point_native(5, '2025-03-02', '2025-03-05 10:00:00+00');

\echo 'known_at 2025-03-05 — Native EXCEPT Core:'
SELECT version_id FROM v_bitemporal_point_native(5, '2025-03-02', '2025-03-05 10:00:00+00')
EXCEPT
SELECT version_id FROM v_bitemporal_point(5, '2025-03-02', '2025-03-05 10:00:00+00');

\echo 'known_at 2025-03-12 — Core EXCEPT Native:'
SELECT version_id FROM v_bitemporal_point(5, '2025-03-02', '2025-03-12 10:00:00+00')
EXCEPT
SELECT version_id FROM v_bitemporal_point_native(5, '2025-03-02', '2025-03-12 10:00:00+00');

\echo 'known_at 2025-03-12 — Native EXCEPT Core:'
SELECT version_id FROM v_bitemporal_point_native(5, '2025-03-02', '2025-03-12 10:00:00+00')
EXCEPT
SELECT version_id FROM v_bitemporal_point(5, '2025-03-02', '2025-03-12 10:00:00+00');

\echo 'known_at 2025-03-16 — Core EXCEPT Native:'
SELECT version_id FROM v_bitemporal_point(5, '2025-03-02', '2025-03-16 10:00:00+00')
EXCEPT
SELECT version_id FROM v_bitemporal_point_native(5, '2025-03-02', '2025-03-16 10:00:00+00');

\echo 'known_at 2025-03-16 — Native EXCEPT Core:'
SELECT version_id FROM v_bitemporal_point_native(5, '2025-03-02', '2025-03-16 10:00:00+00')
EXCEPT
SELECT version_id FROM v_bitemporal_point(5, '2025-03-02', '2025-03-16 10:00:00+00');

