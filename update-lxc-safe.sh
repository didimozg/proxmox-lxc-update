#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================
# Proxmox LXC safe updater
# ============================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
readonly DEFAULT_UPDATE_SCRIPT="${SCRIPT_DIR}/update-lxc.sh"
readonly DEFAULT_LOG_FILE="/var/log/pve-lxc-safe-update.log"
readonly DEFAULT_TIMEOUT=1800
readonly DEFAULT_SNAPSHOT_PREFIX="preupdate"
readonly SEPARATOR="----------------------------------------"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Options
DRY_RUN=0
INCLUDE_CTS=""
EXCLUDE_CTS=""
LOG_FILE="$DEFAULT_LOG_FILE"
LOG_READY=0
USE_COLOR=1
PER_CONTAINER_TIMEOUT="$DEFAULT_TIMEOUT"
APT_MODE="upgrade"
UPDATE_SCRIPT="$DEFAULT_UPDATE_SCRIPT"
SNAPSHOT_PREFIX="$DEFAULT_SNAPSHOT_PREFIX"
SNAPSHOT_NAME=""
KEEP_SNAPSHOT=0
ROLLBACK_ON_FAILURE=1
START_AFTER_ROLLBACK=1

TOTAL_COUNT=0
SNAPSHOT_CREATED_COUNT=0
SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
ROLLED_BACK_COUNT=0
SNAPSHOT_KEPT_COUNT=0
FAILED_CONTAINERS=()
SKIPPED_CONTAINERS=()
ROLLED_BACK_CONTAINERS=()
SNAPSHOT_KEPT_CONTAINERS=()

# --------------------------------------------
# Logging
# --------------------------------------------
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_raw() {
    local level="$1"
    local color="$2"
    local message="$3"

    if [[ "$USE_COLOR" -eq 1 && -t 2 ]]; then
        printf '%b[%s]%b %s\n' "$color" "$level" "$NC" "$message" >&2
    else
        printf '[%s] %s\n' "$level" "$message" >&2
    fi

    if [[ "$LOG_READY" -eq 1 ]]; then
        printf '[%s] [%s] %s\n' "$(timestamp)" "$level" "$message" >> "$LOG_FILE"
    fi
}

log_info()    { log_raw "INFO"    "$BLUE"   "$1"; }
log_success() { log_raw "SUCCESS" "$GREEN"  "$1"; }
log_warning() { log_raw "WARNING" "$YELLOW" "$1"; }
log_error()   { log_raw "ERROR"   "$RED"    "$1"; }

# --------------------------------------------
# Helpers
# --------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: $SCRIPT_NAME [options]

Safely update running LXC containers by creating a pre-update snapshot for each
container, running ${DEFAULT_UPDATE_SCRIPT##*/}, and optionally rolling back
when the update fails.

Options:
  --dry-run                     Show what would be executed
  --ct 101,102,103              Process only selected container IDs
  --exclude 104,105             Exclude selected container IDs
  --log-file PATH               Custom log file path (default: ${DEFAULT_LOG_FILE})
  --no-color                    Disable colored console output
  --timeout SECONDS             Forwarded to ${DEFAULT_UPDATE_SCRIPT##*/}
  --apt-mode MODE               upgrade | dist-upgrade (default: upgrade)
  --update-script PATH          Custom path to ${DEFAULT_UPDATE_SCRIPT##*/}
  --snapshot-prefix PREFIX      Prefix for generated snapshot names (default: ${DEFAULT_SNAPSHOT_PREFIX})
  --snapshot-name NAME          Explicit snapshot name for all selected containers
  --keep-snapshot               Keep snapshots after a successful update
  --no-rollback                 Do not roll back when the update fails
  --no-start-after-rollback     Leave the container stopped after rollback
  -h, --help                    Show this help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --ct 101,102 --apt-mode dist-upgrade
  $SCRIPT_NAME --exclude 105 --keep-snapshot
  $SCRIPT_NAME --snapshot-name before-maintenance --no-rollback
EOF
}

contains_csv_id() {
    local csv="$1"
    local id="$2"

    [[ ",${csv}," == *",${id},"* ]]
}

normalize_csv_ids() {
    local value="${1//[[:space:]]/}"

    value="${value#,}"
    value="${value%,}"
    printf '%s' "$value"
}

validate_csv_ids() {
    local option_name="$1"
    local value="$2"

    if [[ -z "$value" || ! "$value" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        log_error "Invalid ${option_name} value: expected a comma-separated list of IDs, for example 101,102,103"
        exit 1
    fi
}

validate_snapshot_name() {
    local value="$1"

    if [[ -z "$value" || ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        log_error "Invalid snapshot name: use letters, digits, dot, underscore, or dash"
        exit 1
    fi
}

ensure_log_file() {
    touch "$LOG_FILE" 2>/dev/null || {
        echo "Failed to create log file: $LOG_FILE" >&2
        exit 1
    }

    LOG_READY=1
}

check_permissions() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_dependencies() {
    local missing=0
    local required_commands=(pct awk grep mktemp cat bash)
    local cmd

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            missing=1
        fi
    done

    if [[ ! -f "$UPDATE_SCRIPT" ]]; then
        log_error "Update script not found: $UPDATE_SCRIPT"
        missing=1
    fi

    if [[ "$missing" -ne 0 ]]; then
        exit 1
    fi
}

parse_args() {
    local explicit_snapshot_name=0
    local explicit_snapshot_prefix=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --ct)
                INCLUDE_CTS="$(normalize_csv_ids "${2:-}")"
                validate_csv_ids "--ct" "$INCLUDE_CTS"
                shift 2
                ;;
            --exclude)
                EXCLUDE_CTS="$(normalize_csv_ids "${2:-}")"
                validate_csv_ids "--exclude" "$EXCLUDE_CTS"
                shift 2
                ;;
            --log-file)
                LOG_FILE="${2:-}"
                [[ -z "$LOG_FILE" || "$LOG_FILE" == --* ]] && { log_error "Empty or invalid value for --log-file"; exit 1; }
                shift 2
                ;;
            --no-color)
                USE_COLOR=0
                shift
                ;;
            --timeout)
                PER_CONTAINER_TIMEOUT="${2:-}"
                [[ ! "$PER_CONTAINER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] && {
                    log_error "Invalid timeout: $PER_CONTAINER_TIMEOUT"
                    exit 1
                }
                shift 2
                ;;
            --apt-mode)
                APT_MODE="${2:-}"
                [[ "$APT_MODE" != "upgrade" && "$APT_MODE" != "dist-upgrade" ]] && {
                    log_error "Allowed --apt-mode values: upgrade | dist-upgrade"
                    exit 1
                }
                shift 2
                ;;
            --update-script)
                UPDATE_SCRIPT="${2:-}"
                [[ -z "$UPDATE_SCRIPT" || "$UPDATE_SCRIPT" == --* ]] && { log_error "Empty or invalid value for --update-script"; exit 1; }
                shift 2
                ;;
            --snapshot-prefix)
                SNAPSHOT_PREFIX="${2:-}"
                validate_snapshot_name "$SNAPSHOT_PREFIX"
                explicit_snapshot_prefix=1
                shift 2
                ;;
            --snapshot-name)
                SNAPSHOT_NAME="${2:-}"
                validate_snapshot_name "$SNAPSHOT_NAME"
                explicit_snapshot_name=1
                shift 2
                ;;
            --keep-snapshot)
                KEEP_SNAPSHOT=1
                shift
                ;;
            --no-rollback)
                ROLLBACK_ON_FAILURE=0
                shift
                ;;
            --no-start-after-rollback)
                START_AFTER_ROLLBACK=0
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ "$explicit_snapshot_name" -eq 1 && "$explicit_snapshot_prefix" -eq 1 ]]; then
        log_error "Use either --snapshot-name or --snapshot-prefix, not both"
        exit 1
    fi
}

resolve_snapshot_name() {
    if [[ -n "$SNAPSHOT_NAME" ]]; then
        return 0
    fi

    SNAPSHOT_NAME="${SNAPSHOT_PREFIX}-$(date +%Y%m%d-%H%M%S)"
}

warn_overlapping_filters() {
    [[ -z "$INCLUDE_CTS" || -z "$EXCLUDE_CTS" ]] && return 0

    local overlaps=()
    local include_ids=()
    local ct

    IFS=',' read -r -a include_ids <<< "$INCLUDE_CTS"

    for ct in "${include_ids[@]}"; do
        if contains_csv_id "$EXCLUDE_CTS" "$ct"; then
            overlaps+=("$ct")
        fi
    done

    if [[ "${#overlaps[@]}" -gt 0 ]]; then
        log_warning "The same IDs were specified in both --ct and --exclude; --exclude takes precedence: ${overlaps[*]}"
    fi
}

get_config_value() {
    local ctid="$1"
    local key="$2"

    pct config "$ctid" 2>/dev/null | awk -F': ' -v k="$key" '$1==k {print $2; exit}'
}

get_container_name() {
    local ctid="$1"
    get_config_value "$ctid" "hostname"
}

get_container_lock() {
    local ctid="$1"
    get_config_value "$ctid" "lock"
}

get_container_status() {
    local ctid="$1"

    pct status "$ctid" 2>/dev/null | awk -F': ' '$1=="status" {print $2; exit}'
}

is_container_running() {
    local ctid="$1"
    pct status "$ctid" 2>/dev/null | grep -q '^status: running$'
}

get_lxc_containers() {
    local containers
    containers="$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" && $1 ~ /^[0-9]+$/ {print $1}')"

    if [[ -z "$containers" ]]; then
        return 1
    fi

    local filtered=()
    local ct

    for ct in $containers; do
        if [[ -n "$INCLUDE_CTS" ]] && ! contains_csv_id "$INCLUDE_CTS" "$ct"; then
            continue
        fi

        if [[ -n "$EXCLUDE_CTS" ]] && contains_csv_id "$EXCLUDE_CTS" "$ct"; then
            continue
        fi

        filtered+=("$ct")
    done

    if [[ "${#filtered[@]}" -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${filtered[@]}"
    return 0
}

warn_requested_container_states() {
    [[ -z "$INCLUDE_CTS" ]] && return 0

    local include_ids=()
    local ct
    local status

    IFS=',' read -r -a include_ids <<< "$INCLUDE_CTS"

    for ct in "${include_ids[@]}"; do
        status="$(get_container_status "$ct")"

        if [[ -z "$status" ]]; then
            log_warning "Container $ct from --ct was not found"
            continue
        fi

        if [[ "$status" != "running" ]]; then
            log_warning "Container $ct from --ct has status=$status and will be skipped"
        fi
    done
}

append_file_to_log() {
    local title="$1"
    local path="$2"

    [[ ! -f "$path" ]] && return 0

    printf '[%s] [INFO] %s\n' "$(timestamp)" "$SEPARATOR" >> "$LOG_FILE"
    printf '[%s] [INFO] %s\n' "$(timestamp)" "$title" >> "$LOG_FILE"
    cat "$path" >> "$LOG_FILE"
    printf '[%s] [INFO] END %s\n' "$(timestamp)" "$title" >> "$LOG_FILE"
}

run_update_script() {
    local ctid="$1"
    local update_log="$2"
    local rc=0
    local cmd=(
        bash "$UPDATE_SCRIPT"
        --ct "$ctid"
        --log-file "$update_log"
        --timeout "$PER_CONTAINER_TIMEOUT"
        --apt-mode "$APT_MODE"
    )

    if [[ "$USE_COLOR" -eq 0 ]]; then
        cmd+=(--no-color)
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        cmd+=(--dry-run)
    fi

    printf '[%s] [INFO] BEGIN UPDATE CT %s\n' "$(timestamp)" "$ctid" >> "$LOG_FILE"
    printf '[%s] [INFO] UPDATE COMMAND:' "$(timestamp)" >> "$LOG_FILE"
    printf ' %q' "${cmd[@]}" >> "$LOG_FILE"
    printf '\n' >> "$LOG_FILE"

    if "${cmd[@]}"; then
        rc=0
    else
        rc=$?
    fi

    append_file_to_log "INNER UPDATE LOG CT ${ctid}" "$update_log"
    printf '[%s] [INFO] END UPDATE CT %s rc=%s\n' "$(timestamp)" "$ctid" "$rc" >> "$LOG_FILE"
    return "$rc"
}

create_snapshot() {
    local ctid="$1"
    local rc=0

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Would create snapshot ${SNAPSHOT_NAME} for container $ctid"
        return 0
    fi

    log_info "Creating snapshot ${SNAPSHOT_NAME} for container $ctid"
    printf '[%s] [INFO] BEGIN SNAPSHOT CT %s name=%s\n' "$(timestamp)" "$ctid" "$SNAPSHOT_NAME" >> "$LOG_FILE"

    if pct snapshot "$ctid" "$SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1; then
        ((SNAPSHOT_CREATED_COUNT++))
        log_success "Snapshot ${SNAPSHOT_NAME} created for container $ctid"
        printf '[%s] [INFO] END SNAPSHOT CT %s rc=0\n' "$(timestamp)" "$ctid" >> "$LOG_FILE"
        return 0
    fi

    rc=$?
    log_error "Failed to create snapshot ${SNAPSHOT_NAME} for container $ctid (exit code: $rc)"
    printf '[%s] [INFO] END SNAPSHOT CT %s rc=%s\n' "$(timestamp)" "$ctid" "$rc" >> "$LOG_FILE"
    return "$rc"
}

delete_snapshot_if_requested() {
    local ctid="$1"

    if [[ "$KEEP_SNAPSHOT" -eq 1 ]]; then
        ((SNAPSHOT_KEPT_COUNT++))
        SNAPSHOT_KEPT_CONTAINERS+=("$ctid")
        log_info "Keeping snapshot ${SNAPSHOT_NAME} for container $ctid by request"
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Would delete snapshot ${SNAPSHOT_NAME} for container $ctid after a successful update"
        return 0
    fi

    log_info "Deleting snapshot ${SNAPSHOT_NAME} for container $ctid after a successful update"

    if pct delsnapshot "$ctid" "$SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1; then
        log_success "Snapshot ${SNAPSHOT_NAME} removed for container $ctid"
        return 0
    fi

    ((SNAPSHOT_KEPT_COUNT++))
    SNAPSHOT_KEPT_CONTAINERS+=("$ctid")
    log_warning "Failed to delete snapshot ${SNAPSHOT_NAME} for container $ctid; keeping it"
    return 0
}

rollback_container() {
    local ctid="$1"
    local rc=0

    if [[ "$ROLLBACK_ON_FAILURE" -eq 0 ]]; then
        log_warning "Rollback is disabled; snapshot ${SNAPSHOT_NAME} is being kept for container $ctid"
        ((SNAPSHOT_KEPT_COUNT++))
        SNAPSHOT_KEPT_CONTAINERS+=("$ctid")
        return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_warning "[DRY-RUN] Would roll back container $ctid to snapshot ${SNAPSHOT_NAME}"
        if [[ "$START_AFTER_ROLLBACK" -eq 1 ]]; then
            log_info "[DRY-RUN] Would start container $ctid after rollback if needed"
        fi
        return 0
    fi

    log_warning "Rolling back container $ctid to snapshot ${SNAPSHOT_NAME}"
    printf '[%s] [INFO] BEGIN ROLLBACK CT %s name=%s\n' "$(timestamp)" "$ctid" "$SNAPSHOT_NAME" >> "$LOG_FILE"

    if ! pct rollback "$ctid" "$SNAPSHOT_NAME" >> "$LOG_FILE" 2>&1; then
        rc=$?
        ((SNAPSHOT_KEPT_COUNT++))
        SNAPSHOT_KEPT_CONTAINERS+=("$ctid")
        log_error "Rollback failed for container $ctid (exit code: $rc)"
        printf '[%s] [INFO] END ROLLBACK CT %s rc=%s\n' "$(timestamp)" "$ctid" "$rc" >> "$LOG_FILE"
        return "$rc"
    fi

    if [[ "$START_AFTER_ROLLBACK" -eq 1 ]] && ! is_container_running "$ctid"; then
        log_info "Starting container $ctid after rollback"
        if ! pct start "$ctid" >> "$LOG_FILE" 2>&1; then
            rc=$?
            log_error "Rollback completed, but failed to start container $ctid (exit code: $rc)"
            printf '[%s] [INFO] END ROLLBACK CT %s rc=%s\n' "$(timestamp)" "$ctid" "$rc" >> "$LOG_FILE"
            return "$rc"
        fi
    fi

    ((ROLLED_BACK_COUNT++))
    ROLLED_BACK_CONTAINERS+=("$ctid")
    ((SNAPSHOT_KEPT_COUNT++))
    SNAPSHOT_KEPT_CONTAINERS+=("$ctid")
    log_success "Container $ctid rolled back to snapshot ${SNAPSHOT_NAME}"
    printf '[%s] [INFO] END ROLLBACK CT %s rc=0\n' "$(timestamp)" "$ctid" >> "$LOG_FILE"
    return 0
}

process_container() {
    local ctid="$1"
    local name
    local lock
    local update_log
    local update_rc=0
    local rc=0

    name="$(get_container_name "$ctid")"
    lock="$(get_container_lock "$ctid")"

    if [[ -n "$name" ]]; then
        log_info "Container $ctid ($name)"
    else
        log_info "Container $ctid"
    fi

    if ! is_container_running "$ctid"; then
        log_warning "Container $ctid is no longer in running state, skipping"
        ((SKIPPED_COUNT++))
        SKIPPED_CONTAINERS+=("$ctid")
        return 0
    fi

    if [[ -n "$lock" ]]; then
        log_warning "Container $ctid has lock=$lock, skipping"
        ((SKIPPED_COUNT++))
        SKIPPED_CONTAINERS+=("$ctid")
        return 0
    fi

    if ! create_snapshot "$ctid"; then
        rc=$?
        ((FAILED_COUNT++))
        FAILED_CONTAINERS+=("$ctid")
        return "$rc"
    fi

    update_log="$(mktemp "/tmp/${SCRIPT_NAME}.ct-${ctid}.XXXXXX.log")" || {
        log_error "Failed to create a temporary update log for container $ctid"
        ((SNAPSHOT_KEPT_COUNT++))
        SNAPSHOT_KEPT_CONTAINERS+=("$ctid")
        ((FAILED_COUNT++))
        FAILED_CONTAINERS+=("$ctid")
        return 1
    }

    if run_update_script "$ctid" "$update_log"; then
        update_rc=0
    else
        update_rc=$?
    fi
    rm -f "$update_log"

    if [[ "$update_rc" -eq 0 ]]; then
        ((SUCCESS_COUNT++))
        delete_snapshot_if_requested "$ctid"
        return 0
    fi

    ((FAILED_COUNT++))
    FAILED_CONTAINERS+=("$ctid")
    log_error "Update failed for container $ctid (exit code: $update_rc)"
    rollback_container "$ctid" || true
    return "$update_rc"
}

handle_termination() {
    local signal_name="$1"

    log_error "Execution interrupted by signal ${signal_name}"

    exit 130
}

print_summary() {
    local execution_time="$1"

    echo "========================================" >&2
    log_info "=== SAFE UPDATE RESULTS ==="
    log_info "Total execution time: ${execution_time} seconds"
    log_info "Total containers selected: $TOTAL_COUNT"
    log_info "Snapshot name: ${SNAPSHOT_NAME}"
    log_info "Snapshots created: $SNAPSHOT_CREATED_COUNT"
    log_success "Updated successfully: $SUCCESS_COUNT"

    if [[ "$ROLLED_BACK_COUNT" -gt 0 ]]; then
        log_warning "Rolled back: ${ROLLED_BACK_COUNT} (${ROLLED_BACK_CONTAINERS[*]})"
    else
        log_info "Rolled back: 0"
    fi

    if [[ "$SNAPSHOT_KEPT_COUNT" -gt 0 ]]; then
        log_info "Snapshots kept: ${SNAPSHOT_KEPT_COUNT} (${SNAPSHOT_KEPT_CONTAINERS[*]})"
    else
        log_info "Snapshots kept: 0"
    fi

    if [[ "$SKIPPED_COUNT" -gt 0 ]]; then
        log_warning "Skipped: ${SKIPPED_COUNT} (${SKIPPED_CONTAINERS[*]})"
    else
        log_info "Skipped: 0"
    fi

    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        log_error "Failed: ${FAILED_COUNT} (${FAILED_CONTAINERS[*]})"
    else
        log_info "Failed: 0"
    fi
}

main() {
    local start_time
    local end_time
    local execution_time
    local containers
    local container_count
    local ct

    parse_args "$@"
    resolve_snapshot_name
    check_permissions
    ensure_log_file
    check_dependencies
    warn_overlapping_filters
    warn_requested_container_states

    trap 'handle_termination INT' INT
    trap 'handle_termination TERM' TERM

    start_time="$(date +%s)"

    log_info "Starting safe LXC container update run"
    log_info "Start time: $(date)"
    log_info "Log file: $LOG_FILE"
    log_info "Dry-run mode: $DRY_RUN"
    log_info "APT mode: $APT_MODE"
    log_info "Update script: $UPDATE_SCRIPT"
    log_info "Snapshot name: $SNAPSHOT_NAME"
    log_info "Keep snapshot on success: $KEEP_SNAPSHOT"
    log_info "Rollback on failure: $ROLLBACK_ON_FAILURE"
    log_info "Start after rollback: $START_AFTER_ROLLBACK"
    if [[ -n "$INCLUDE_CTS" ]]; then
        log_info "--ct filter: $INCLUDE_CTS"
    fi
    if [[ -n "$EXCLUDE_CTS" ]]; then
        log_info "--exclude filter: $EXCLUDE_CTS"
    fi
    echo "$SEPARATOR" >&2

    if ! containers="$(get_lxc_containers)"; then
        log_warning "No eligible running LXC containers found for update"
        exit 0
    fi

    container_count="$(printf '%s\n' "$containers" | wc -l)"
    TOTAL_COUNT="$container_count"
    log_info "Containers selected for processing: $container_count"

    while IFS= read -r ct; do
        [[ -z "$ct" ]] && continue
        echo "$SEPARATOR" >&2
        process_container "$ct" || true
        sleep 1
    done <<< "$containers"

    end_time="$(date +%s)"
    execution_time=$((end_time - start_time))

    print_summary "$execution_time"
    log_info "Finish time: $(date)"

    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

main "$@"
