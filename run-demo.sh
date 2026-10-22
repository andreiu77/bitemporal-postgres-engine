#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$BASE_DIR"
SQL_DIR="$BASE_DIR"

CONTAINER="pg19_bitemporal"
DB_NAME="assignment1"
DB_USER="postgres"

echo "=========================================================="
echo " Starting clean PostgreSQL 19 environment from scratch..."
echo "=========================================================="

# Cleanup any previous instances/volumes
docker compose -f "$PROJECT_DIR/docker-compose.yml" down -v > /dev/null 2>&1 || true

# Always tear down and delete container on script completion or error
cleanup() {
    echo ""
    echo "=========================================================="
    echo " Tearing down and deleting container at end..."
    echo "=========================================================="
    docker compose -f "$PROJECT_DIR/docker-compose.yml" down -v
    echo "Done! Container and volumes deleted."
}
trap cleanup EXIT

# Start container
docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d

# Wait for PostgreSQL to be ready
echo -n "Waiting for PostgreSQL to be ready"
until docker exec "$CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" > /dev/null 2>&1; do
    echo -n "."
    sleep 1
done
echo " Ready!"

# Function to execute each SQL script via stdin
run_sql() {
    local file="$1"
    local desc="$2"
    echo ""
    echo "=========================================================="
    echo " Running $desc: $(basename "$file")"
    echo "=========================================================="
    docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" < "$file"
}

# Execute scripts in sequence: 01 to 05, then A2, then A1
run_sql "$SQL_DIR/01_schema.sql" "Step 1 (Schema & Constraints)"
run_sql "$SQL_DIR/02_data.sql" "Step 2 (Initial Load E1)"
run_sql "$SQL_DIR/03_timeline.sql" "Step 3 (Timeline Events E2-E9)"
run_sql "$SQL_DIR/04_views.sql" "Step 4 (Temporal Views & Functions)"
run_sql "$SQL_DIR/05_tests.sql" "Step 5 (Core Temporal Tests Q0-Q8)"
run_sql "$SQL_DIR/06_advanced_a2.sql" "Step 6 (Advanced A2: Native Temporal Features)"
run_sql "$SQL_DIR/06_advanced_a1.sql" "Step 7 (Advanced A1: Engine-Managed Transaction Time)"

echo ""
echo "=========================================================="
echo " SUCCESS: All 7 scripts executed in order without error!"
echo "=========================================================="
