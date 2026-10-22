# Bitemporal Database Engine (PostgreSQL 19)

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-19beta4-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)

A PostgreSQL 19 implementation of a bitemporal data model (Valid Time + Transaction Time) for a streaming platform domain. Tracks both real-world state and database knowledge independently to support time-travel queries, retroactive corrections, and audit logging without physical row updates or deletes.

---

## The Two Clocks

| Dimension | Column | Type | Meaning |
| :--- | :--- | :--- | :--- |
| **Valid Time (VT)** | `valid_from`, `valid_to` | `DATE` | When the fact occurred in reality (e.g. subscription period, price effective date). |
| **Transaction Time (TT)** | `tx_from`, `tx_to` | `TIMESTAMPTZ(6)` (UTC) | When the system asserted, modified, or closed the record. |

Open-ended intervals use sentinel values rather than `NULL`:
- `valid_to` default: `'9999-12-31'`
- `tx_to` default: `'9999-12-31 23:59:59.999999'`

Sentinels keep range predicates simple (`valid_from <= x AND x < valid_to`), avoid ternary SQL `NULL` logic, and remain indexable via standard B-Tree and GiST indexes.

---

## Core Behavior: One Query, Three Answers (Q6)

Demonstrates how late-arriving data and subsequent audit corrections produce three distinct, historically accurate answers for the exact same valid date:

1. **Jan 01:** Subscriber 5 is on Plan 1 (Basic).
2. **Mar 10 (Late Entry):** Clerk records Subscriber 5 upgraded to Plan 5 (Crew) back on **March 1st** (9 days late).
3. **Mar 15 (Correction):** Auditor discovers the upgrade was actually on **March 3rd** and issues a correction.

**Query:** *"What plan did Subscriber 5 have on March 2nd?"*

```sql
-- 1. As known on March 5 (before late entry was recorded):
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-05 10:00:00+00');
-- Result: Plan 1 (Basic)

-- 2. As known on March 12 (after late entry, before correction):
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-12 10:00:00+00');
-- Result: Plan 5 (Crew)

-- 3. As known on March 16 / Today (after audit correction):
SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-16 10:00:00+00');
-- Result: Plan 1 (Basic)
```

No data is deleted or overwritten. All versions remain queryable via `(valid_at, known_at)`.

---

## Architecture & Data Model

### Anchor / Version Split

- **Anchors (`subscriber`, `plan`, `title`, `region`):** Hold immutable surrogate keys and permanent identities. Foreign keys target anchors only.
- **Version Tables (`subscription_version`, `plan_price_version`, `title_licence_version`):** Hold time-varying business attributes along with `valid_from`, `valid_to`, `tx_from`, `tx_to`, and `tx_id`.
- **Transaction Registry (`tx_registry`):** Groups multi-table modifications under an atomic `tx_id` stamped with timestamp, author, and reason.

### Append-Only Write Protocol

Modifications never update payload columns in-place:
1. Current active record's `tx_to` is closed to `now()`.
2. New record is inserted with `tx_from = now()`, `tx_to = '9999-12-31...'`, and the new payload/valid period.
3. Both operations share the same `tx_id` from `tx_registry`.

---

## Advanced Tracks

### A1: Engine-Managed Transaction Time
- **Guard Triggers (`trg_guard_subscription_version`):** Hard blocks direct `DELETE` and direct `UPDATE` on business columns or `tx_from`. Only allowed write is closing `tx_to` via the Write API.
- **Write API:** Stored procedures (`fn_create_subscription`, etc.) handle transaction registration, row closing, and insertion.
- **Clock Resolver:** Function `fn_current_tx_time()` reads `app.sim_now` session variable if set, enabling deterministic time simulation and event replay.

### A2: PostgreSQL Native Temporal Features
- Implements equivalent functions using PostgreSQL range types:
  ```sql
  daterange(valid_from, valid_to) @> p_valid_at 
  AND tstzrange(tx_from, tx_to)   @> p_known_at
  ```
- Evaluates native temporal operators and GiST exclusion constraints for non-overlapping valid periods.

---

## File Structure

```text
.
├── docker-compose.yml      # PostgreSQL 19 container setup
├── run-demo.sh             # Automated setup, test execution, and teardown
├── README.md               # Technical documentation
├── 01_schema.sql           # Tables, constraints, foreign keys, indexes
├── 02_data.sql             # Initial load (Event E1)
├── 03_timeline.sql         # 10 operational timeline events (Events E2–E9)
├── 04_views.sql            # Temporal query functions & views (Q0–Q8)
├── 05_tests.sql            # Test suite + index EXPLAIN ANALYZE checks
├── 06_advanced_a1.sql      # A1: Stored procedures, triggers, simulated clock
└── 06_advanced_a2.sql      # A2: Native PostgreSQL range type queries
```

---

## How to Run

### Requirements
- Docker and Docker Compose
- Bash (Linux/macOS or Git Bash/WSL on Windows)

### 1. Automated Run (One-Click)
Starts the container, waits for PostgreSQL to become ready, executes all 7 SQL scripts in sequence, runs all temporal tests, and tears down the container:

```bash
chmod +x run-demo.sh
./run-demo.sh
```

### 2. Manual Run (Interactive)
To inspect the database after running:

```bash
# Start container
docker compose up -d

# Execute scripts in sequence
docker exec -i pg19_bitemporal psql -U postgres -d assignment1 < 01_schema.sql
docker exec -i pg19_bitemporal psql -U postgres -d assignment1 < 02_data.sql
docker exec -i pg19_bitemporal psql -U postgres -d assignment1 < 03_timeline.sql
docker exec -i pg19_bitemporal psql -U postgres -d assignment1 < 04_views.sql
docker exec -i pg19_bitemporal psql -U postgres -d assignment1 < 05_tests.sql
docker exec -i pg19_bitemporal psql -U postgres -d assignment1 < 06_advanced_a2.sql
docker exec -i pg19_bitemporal psql -U postgres -d assignment1 < 06_advanced_a1.sql

# Connect to database
docker exec -it pg19_bitemporal psql -U postgres -d assignment1

# Stop container when done
docker compose down -v
```

---

## Core Temporal Query Functions (`04_views.sql`)

| Function / View | Purpose | Example |
| :--- | :--- | :--- |
| `v_integrity_violations` | Integrity check (must return 0 rows on valid data). | `SELECT * FROM v_integrity_violations;` |
| `v_current_facts(id)` | Current active facts for a subscriber (`valid_at = today`, `tx_at = now`). | `SELECT * FROM v_current_facts(1);` |
| `v_as_of_valid(id, date)` | Point-in-time valid query as known right now. | `SELECT * FROM v_as_of_valid(5, '2025-02-15');` |
| `v_snapshot_at(timestamp)` | Complete system state as known at a specific transaction time. | `SELECT * FROM v_snapshot_at('2025-03-10 15:00:00+00');` |
| `v_bitemporal_point(id, date, timestamp)` | Full bitemporal point query evaluated at `(valid_at, known_at)`. | `SELECT * FROM v_bitemporal_point(5, '2025-03-02', '2025-03-12 10:00:00+00');` |
| `v_during_period(start, end)` | Relationships valid at some point vs. throughout a given time window. | `SELECT * FROM v_during_period('2025-01-01', '2025-04-01');` |
| `v_gaps` | Detects resubscription gaps between non-contiguous intervals (E6). | `SELECT * FROM v_gaps;` |
| `v_classified_changes` | Classifies historical writes (proactive, late, correction) with delays. | `SELECT * FROM v_classified_changes;` |

---

## Performance Note

An index on `(subscriber_id, tx_to, valid_from)` is defined on `subscription_version`:

```sql
CREATE INDEX ix_subscription_asof 
ON subscription_version (subscriber_id, tx_to, valid_from);
```

Tested in `05_tests.sql` via `EXPLAIN ANALYZE`: converts the full bitemporal point lookup (`v_bitemporal_point`) from a sequential scan across all historical revisions into a direct index scan.
