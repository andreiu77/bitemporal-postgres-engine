-- 05_tests.sql: Test suite for Temporal Questions (Q0-Q8)

\echo '========================================================================'
\echo 'Q0: Integrity Violations Check (Must return 0 rows on clean data)'
\echo '========================================================================'
SELECT * FROM v_integrity_violations;

\echo ''
\echo '--- Deliberately breaking Invariant I1 in a transaction to prove Q0 detects it ---'
BEGIN;
-- Introduce overlap (Sub 1 rejoins on 2025-06-01 in 03_timeline)
INSERT INTO subscription_version (subscriber_id, plan_id, valid_from, valid_to, tx_from, tx_id) 
VALUES (1, 2, '2025-05-01', '2025-07-01', '2025-12-15 10:00:00+00', 1);

SELECT * FROM v_integrity_violations;
ROLLBACK;
\echo '--- Rolled back deliberate violation. Database clean again. ---'


\echo ''
\echo '========================================================================'
\echo 'Q1: Current Facts for Subscriber 1 (Valid Today AND Current in TT)'
\echo '========================================================================'
-- Subscriber 1 cancelled on Feb 1 (E2), then resubscribed to Plan 2 on Jun 1 (E6).
-- Today is after Jun 1, 2025, so we see their current Plan 2 subscription.
SELECT * FROM v_current_facts(1);


\echo ''
\echo '========================================================================'
\echo 'Q2: Full History of Plan 3 (Premium) Price with Coalesced Periods'
\echo '========================================================================'
-- Reflects Plan 3 price timeline: 14.99 from Jan 1 to Mar 3, then 17.99 from Mar 3 onward.
-- Coalesces adjacent periods and computes tenure lengths.
SELECT * FROM v_role_history(3);


\echo ''
\echo '========================================================================'
\echo 'Q3: Classified Changes (Proactive, Late, Correction)'
\echo '========================================================================'
-- Displays delays in days and side-by-side old vs new values.
SELECT entity, key_id, change_type, delay_days, old_value, new_value,
       old_valid_from, old_valid_to, new_valid_from, new_valid_to, tx_from
FROM v_classified_changes;


\echo ''
\echo '========================================================================'
\echo 'Q4: Relationships Valid During Q1 2025 (2025-01-01 to 2025-04-01) with LIMIT 15'
\echo '========================================================================'
-- at_some_point: overlaps Q1
-- throughout: spans the full quarter without interruption
SELECT * FROM v_during_period('2025-01-01', '2025-04-01')
LIMIT 15;


\echo ''
\echo '========================================================================'
\echo 'Q5: System Snapshot at Transaction Time: 2025-03-10 15:00:00'
\echo '========================================================================'
-- Captures system belief right after E3 (before E4 correction was recorded).
SELECT * FROM v_snapshot_at('2025-03-10 15:00:00+00');



\echo ''
\echo '========================================================================'
\echo 'Q6: Bitemporal Point Query: Plan for Subscriber 5 on Valid Date 2025-03-02'
\echo '========================================================================'
\echo '--- Answer 1: As known on 2025-03-05 10:00:00 (Before E3 late entry) -> Expect Plan 1 (Basic) ---'
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-05 10:00:00+00');

\echo '--- Answer 2: As known on 2025-03-12 10:00:00 (After E3 late entry, before E4) -> Expect Plan 5 (Crew) ---'
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-12 10:00:00+00');

\echo '--- Answer 3: As known on 2025-03-16 10:00:00 (After E4 audit correction) -> Expect Plan 1 (Basic) ---'
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-16 10:00:00+00');


\echo ''
\echo '========================================================================'
\echo 'Q6 Performance Test: EXPLAIN ANALYZE of Q6 With & Without Index'
\echo '========================================================================'
\echo '--- Execution plan WITH ix_subscription_asof index ---'
EXPLAIN ANALYZE
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-12 10:00:00+00');

DROP INDEX IF EXISTS ix_subscription_asof;

\echo ''
\echo '--- Execution plan WITHOUT ix_subscription_asof index ---'
EXPLAIN ANALYZE
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-12 10:00:00+00');

-- Recreate index so database remains in optimal indexed state
CREATE INDEX ix_subscription_asof ON subscription_version (subscriber_id, tx_to, valid_from);
\echo '--- Re-created ix_subscription_asof index ---'


\echo ''
\echo '========================================================================'
\echo 'Q7: Monthly Count of Active Subscriptions per Plan (Calendar CTE)'
\echo '========================================================================'
SELECT * FROM v_monthly_counts
LIMIT 20;


\echo ''
\echo '========================================================================'
\echo 'Q8: Detected Gaps Between Consecutive Subscriptions (E6 Events)'
\echo '========================================================================'
SELECT * FROM v_gaps;
