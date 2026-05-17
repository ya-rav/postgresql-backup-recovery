#!/usr/bin/env bash

set -euo pipefail

# Configuration — reads from .env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-mydb}"
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

CONTAINER_NAME="${CONTAINER_NAME:-postgres_db}"   # docker compose service name

LOG_DIR="$PROJECT_DIR/logs"
BACKUP_DIR="$PROJECT_DIR/backups"
SNAPSHOT_DIR="$PROJECT_DIR/logs/snapshots"

RESTORE_LOG="$LOG_DIR/restore.log"
VERIFY_LOG="$LOG_DIR/verify.log"

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# -------------------------------------------------------------
# Helpers
# -------------------------------------------------------------
log()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$VERIFY_LOG"; }
info()   { log "${CYAN}[INFO]${NC}  $*"; }
ok()     { log "${GREEN}[OK]${NC}    $*"; }
warn()   { log "${YELLOW}[WARN]${NC}  $*"; }
error()  { log "${RED}[ERROR]${NC} $*"; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; log "=== $* ==="; }

mkdir -p "$LOG_DIR" "$SNAPSHOT_DIR"

# Wrapper: run psql inside the docker container
psql_exec() {
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A "$@"
}

# Run a single SQL statement and return output
sql() {
    psql_exec -c "$1"
}

# Check that the container is running
check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        error "Container '$CONTAINER_NAME' is not running. Start it with: docker compose up -d"
        exit 1
    fi
}

# 1. SNAPSHOT — save current DB state
take_snapshot() {
    header "TAKING DATABASE SNAPSHOT"
    check_container

    local snap_file="$SNAPSHOT_DIR/snapshot_${TIMESTAMP}.txt"

    info "Writing snapshot to: $snap_file"

    {
        echo "# DB Snapshot — $TIMESTAMP"
        echo "# database: $POSTGRES_DB"
        echo ""

        # Row counts for every table
        echo "## Row counts"
        psql_exec -c "
            SELECT tablename, (xpath('/row/cnt/text()',
                query_to_xml(format('SELECT COUNT(*) AS cnt FROM %I', tablename), false, true, ''))
            )[1]::text::int AS row_count
            FROM pg_tables
            WHERE schemaname = 'public'
            ORDER BY tablename;
        " 2>/dev/null || \
        psql_exec -c "
            SELECT relname AS tablename, n_live_tup AS row_count
            FROM pg_stat_user_tables
            ORDER BY relname;
        "

        echo ""
        echo "## Table sizes"
        psql_exec -c "
            SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS size
            FROM pg_class
            WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace
            ORDER BY relname;
        "

        echo ""
        echo "## Sequences"
        psql_exec -c "
            SELECT sequence_name, last_value, is_called
            FROM information_schema.sequences
            WHERE sequence_schema = 'public'
            ORDER BY sequence_name;
        " 2>/dev/null || echo "(no sequences)"

    } > "$snap_file"

    ok "Snapshot saved → $snap_file"
    echo "$snap_file"   # return path for compare
}

# 2. COMPARE — diff two snapshots
compare_snapshots() {
    header "COMPARING DATABASE STATE"

    local snapshots
    mapfile -t snapshots < <(ls -t "$SNAPSHOT_DIR"/snapshot_*.txt 2>/dev/null)

    if [[ ${#snapshots[@]} -lt 2 ]]; then
        warn "Need at least 2 snapshots to compare. Run --snapshot before and after restore."
        exit 1
    fi

    local before="${snapshots[1]}"   # second-newest = before restore
    local after="${snapshots[0]}"    # newest        = after restore

    info "BEFORE: $before"
    info "AFTER:  $after"
    echo ""

    if diff -u "$before" "$after" > /tmp/snapshot_diff.txt; then
        ok "✔ Snapshots are IDENTICAL — full data integrity confirmed."
    else
        warn "Differences found between snapshots:"
        cat /tmp/snapshot_diff.txt | tee -a "$VERIFY_LOG"
        echo ""
        warn "Lines with '-' existed BEFORE restore but are MISSING after."
        warn "Lines with '+' are NEW after restore (unexpected)."
    fi
}

# 3. FULL VERIFICATION — runs verify.sql
run_verification() {
    header "RUNNING SQL VERIFICATION QUERIES"
    check_container

    local verify_sql="$SCRIPT_DIR/verify.sql"

    if [[ ! -f "$verify_sql" ]]; then
        error "verify.sql not found at: $verify_sql"
        exit 1
    fi

    info "Executing verify.sql against database '$POSTGRES_DB'..."
    echo ""

    docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER_NAME" \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -v timestamp="$TIMESTAMP" \
        2>&1 < "$verify_sql" | tee -a "$VERIFY_LOG"

    echo ""
    ok "Verification complete. Full output written to: $VERIFY_LOG"
}

# 4. CORRUPTION / DATA LOSS SCENARIOS

# Helper: find the latest backup file
latest_backup() {
    ls -t "$BACKUP_DIR"/*.sql.gz 2>/dev/null | head -1
}

# Scenario A: DROP TABLE — simulates structural corruption
scenario_corrupt() {
    header "SCENARIO: DATA CORRUPTION (DROP TABLE)"

    local tables
    mapfile -t tables < <(psql_exec -c "
        SELECT tablename FROM pg_tables
        WHERE schemaname = 'public' ORDER BY tablename LIMIT 3;
    ")

    if [[ ${#tables[@]} -eq 0 ]]; then
        warn "No tables found in schema 'public'. Is the database initialised?"
        return 1
    fi

    local target="${tables[0]}"
    info "Target table: $target"

    # Snapshot before
    info "Taking pre-corruption snapshot..."
    take_snapshot > /dev/null

    # Count rows before
    local before_count
    before_count=$(sql "SELECT COUNT(*) FROM $target;")
    info "Rows in '$target' before corruption: $before_count"

    # DROP the table
    warn "Dropping table '$target' to simulate corruption..."
    sql "DROP TABLE IF EXISTS ${target} CASCADE;"

    # Confirm it's gone
    local exists
    exists=$(sql "SELECT COUNT(*) FROM pg_tables WHERE schemaname='public' AND tablename='${target}';")
    if [[ "$exists" == "0" ]]; then
        warn "✔ Table '$target' successfully DROPPED (corruption simulated)."
    fi

    log "SCENARIO: corrupt — table '$target' dropped at $TIMESTAMP"
}

# Scenario B: DELETE rows — simulates partial data loss
scenario_dataloss() {
    header "SCENARIO: DATA LOSS (DELETE ROWS)"

    local tables
    mapfile -t tables < <(psql_exec -c "
        SELECT tablename FROM pg_tables
        WHERE schemaname = 'public' ORDER BY tablename LIMIT 3;
    ")

    local target="${tables[0]}"
    info "Target table: $target"

    # Snapshot before
    info "Taking pre-loss snapshot..."
    take_snapshot > /dev/null

    # Count rows before
    local before_count
    before_count=$(sql "SELECT COUNT(*) FROM ${target};")
    info "Rows in '$target' before deletion: $before_count"

    if [[ "$before_count" -eq 0 ]]; then
        warn "Table is already empty. Skipping."
        return 1
    fi

    # Delete ~50% of rows using ctid (works on any table)
    warn "Deleting ~50% of rows from '$target'..."
    sql "
        DELETE FROM ${target}
        WHERE ctid IN (
            SELECT ctid FROM ${target}
            LIMIT (SELECT COUNT(*)/2 FROM ${target})
        );
    "

    local after_count
    after_count=$(sql "SELECT COUNT(*) FROM ${target};")
    warn "Rows remaining: $after_count (deleted $((before_count - after_count)))"

    log "SCENARIO: dataloss — deleted $((before_count - after_count)) rows from '$target' at $TIMESTAMP"
}

# Restore and verify after a scenario
restore_and_verify() {
    header "RESTORE & VERIFY"

    local backup_file
    backup_file=$(latest_backup)

    if [[ -z "$backup_file" ]]; then
        error "No backup found in $BACKUP_DIR. Run backup.sh first."
        exit 1
    fi

    info "Restoring from: $backup_file"

    # Call the team's restore script
    local restore_script="$SCRIPT_DIR/restore.sh"
    if [[ -f "$restore_script" ]]; then
        bash "$restore_script" "$backup_file"
    else
        warn "restore.sh not found — performing manual restore..."
        # Fallback manual restore
        gunzip -c "$backup_file" | docker exec -i \
            -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER_NAME" \
            psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
    fi

    ok "Restore finished."

    # Snapshot after and compare
    take_snapshot > /dev/null
    compare_snapshots

    # Run SQL verification
    run_verification
}

# Run all scenarios sequentially
scenario_all() {
    header "RUNNING ALL SCENARIOS"

    # Ensure a backup exists first
    local backup_file
    backup_file=$(latest_backup)
    if [[ -z "$backup_file" ]]; then
        error "No backup file found in $BACKUP_DIR"
        error "Please run: bash scripts/backup.sh"
        exit 1
    fi
    info "Using backup: $backup_file"
    echo ""

    # --- Scenario A ---
    scenario_corrupt
    info "Sleeping 3s before restore..."
    sleep 3
    restore_and_verify
    echo ""

    # --- Scenario B ---
    scenario_dataloss
    info "Sleeping 3s before restore..."
    sleep 3
    restore_and_verify
    echo ""

    ok "All scenarios completed. See logs at: $VERIFY_LOG"
}

# 5. MAIN — argument dispatch
main() {
    header "VERIFY.SH — PostgreSQL Integrity & Testing"
    info "Project dir : $PROJECT_DIR"
    info "Database    : $POSTGRES_DB @ $POSTGRES_HOST:$POSTGRES_PORT"
    info "Container   : $CONTAINER_NAME"
    info "Log file    : $VERIFY_LOG"
    echo ""

    case "${1:-}" in
        --snapshot)
            check_container
            take_snapshot
            ;;
        --compare)
            compare_snapshots
            ;;
        --scenario)
            check_container
            case "${2:-}" in
                corrupt)   scenario_corrupt ;;
                dataloss)  scenario_dataloss ;;
                all)       scenario_all ;;
                *)
                    error "Unknown scenario '${2:-}'. Use: corrupt | dataloss | all"
                    exit 1
                    ;;
            esac
            ;;
        ""|--verify)
            check_container
            take_snapshot > /dev/null
            run_verification
            ;;
        --help|-h)
            echo ""
            echo "Usage: $0 [OPTION]"
            echo ""
            echo "  (no args)              Run SQL verification and save snapshot"
            echo "  --snapshot             Save current DB state to snapshot file"
            echo "  --compare              Diff the two most recent snapshots"
            echo "  --scenario corrupt     DROP a table, then restore & verify"
            echo "  --scenario dataloss    DELETE 50% rows, then restore & verify"
            echo "  --scenario all         Run all scenarios with restore between each"
            echo "  --help                 Show this message"
            ;;
        *)
            error "Unknown option '${1}'. Run with --help for usage."
            exit 1
            ;;
    esac
}

main "$@"