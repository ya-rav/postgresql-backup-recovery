#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BACKUPS_DIR="${PROJECT_ROOT}/backups"
LOGS_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOGS_DIR}/backup.log"

ENV_FILE="${PROJECT_ROOT}/.env"

if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres}"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_FILE="${BACKUPS_DIR}/backup_${TIMESTAMP}.sql"

init_environment() {
    mkdir -p "$BACKUPS_DIR"
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

validate_backup() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file does not exist"
        return 1
    fi

    if [[ ! -s "$backup_file" ]]; then
        log_error "Backup file is empty"
        return 1
    fi

    return 0
}

cleanup_failed_backup() {
    local backup_file="$1"

    if [[ -f "$backup_file" ]]; then
        rm -f "$backup_file"
        log_info "Incomplete backup removed"
    fi
}

backup_docker() {
    log_info "Starting Docker PostgreSQL backup"

    docker exec \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        "$POSTGRES_CONTAINER" \
        pg_dump \
            --username="$POSTGRES_USER" \
            --dbname="$POSTGRES_DB" \
            --verbose \
            --format=plain \
            > "$BACKUP_FILE" 2>>"$LOG_FILE"
}

main() {
    init_environment

    log_info "Backup process started"
    log_info "Database: $POSTGRES_DB"
    log_info "Backup file: $BACKUP_FILE"

    check_dependencies

    if ! backup_docker; then
        cleanup_failed_backup "$BACKUP_FILE"
        log_error "Backup failed"
        exit 1
    fi

    if ! validate_backup "$BACKUP_FILE"; then
        cleanup_failed_backup "$BACKUP_FILE"
        log_error "Backup validation failed"
        exit 1
    fi

    FILE_SIZE="$(du -h "$BACKUP_FILE" | cut -f1)"

    log_success "Backup completed successfully"
    log_info "Backup size: $FILE_SIZE"
    log_info "Saved to: $BACKUP_FILE"
}

main "$@"
