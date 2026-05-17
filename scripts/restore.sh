#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BACKUPS_DIR="${PROJECT_ROOT}/backups"
LOGS_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOGS_DIR}/restore.log"

ENV_FILE="${PROJECT_ROOT}/.env"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres}"

BACKUP_FILE="${1:-}"

init_environment() {
    mkdir -p "$LOGS_DIR"
    touch "$LOG_FILE"
}

log_message() {
    local level="$1"
    local message="$2"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
}

log_info() {
    log_message "INFO" "$1"
    echo "[INFO] $1"
}

log_success() {
    log_message "SUCCESS" "$1"
    echo "[SUCCESS] $1"
}

log_error() {
    log_message "ERROR" "$1"
    echo "[ERROR] $1" >&2
}

check_dependencies() {
    command -v docker >/dev/null 2>&1 || {
        log_error "docker is not installed"
        exit 1
    }
}

find_latest_backup() {
    local latest

    latest=$(ls -t "$BACKUPS_DIR"/backup_*.sql 2>/dev/null | head -n 1)

    if [[ -z "$latest" ]]; then
        log_error "No backup files found"
        exit 1
    fi

    echo "$latest"
}

validate_backup_file() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file does not exist"
        return 1
    fi

    if [[ ! -r "$backup_file" ]]; then
        log_error "Backup file is not readable"
        return 1
    fi

    if [[ ! -s "$backup_file" ]]; then
        log_error "Backup file is empty"
        return 1
    fi

    return 0
}

restore_docker() {
    local backup_file="$1"

    log_info "Starting Docker PostgreSQL restore"

    docker exec -i \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        "$POSTGRES_CONTAINER" \
        psql \
            --username="$POSTGRES_USER" \
            --dbname="$POSTGRES_DB" \
            --quiet \
            < "$backup_file" \
            2>>"$LOG_FILE"
}


verify_restore() {
    log_info "Verifying database connection"

    docker exec \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        "$POSTGRES_CONTAINER" \
        psql \
            --username="$POSTGRES_USER" \
            --dbname="$POSTGRES_DB" \
            --command='\dt' \
            --quiet \
            >/dev/null 2>&1
}

main() {
    init_environment

    log_info "Restore process started"

    check_dependencies

    if [[ -z "$BACKUP_FILE" ]]; then
        BACKUP_FILE="$(find_latest_backup)"
        log_info "Using latest backup"
    fi

    log_info "Backup file: $BACKUP_FILE"

    if ! validate_backup_file "$BACKUP_FILE"; then
        log_error "Backup validation failed"
        exit 1
    fi

    if ! restore_docker "$BACKUP_FILE"; then
        log_error "Restore failed"
        exit 1
    fi

    if ! verify_restore; then
        log_error "Restore verification failed"
        exit 1
    fi

    log_success "Restore completed successfully"
    log_info "Database restored from: $BACKUP_FILE"
}

main "$@"