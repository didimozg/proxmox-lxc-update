#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================
# Proxmox LXC updater
# ============================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_LOG_FILE="/var/log/pve-lxc-update.log"
readonly DEFAULT_TIMEOUT=1800   # 30 minutes per container
readonly SEPARATOR="----------------------------------------"
readonly APT_ACQUIRE_OPTIONS="-o Acquire::ForceIPv4=true -o Acquire::Retries=3"

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
PER_CONTAINER_TIMEOUT="$DEFAULT_TIMEOUT"
APT_MODE="upgrade"   # upgrade | dist-upgrade
PARALLEL_JOBS=1
USE_COLOR=1
RUN_STATE_DIR=""
ACTIVE_PIDS=()
ACTIVE_CTS=()
ACTIVE_JOB_LOGS=()
ACTIVE_DONE_FILES=()
TOTAL_COUNT=0
SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
FAILED_CONTAINERS=()
SKIPPED_CONTAINERS=()

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

    # console
    if [[ "$USE_COLOR" -eq 1 && -t 2 ]]; then
        printf '%b[%s]%b %s\n' "$color" "$level" "$NC" "$message" >&2
    else
        printf '[%s] %s\n' "$level" "$message" >&2
    fi

    # file
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

Options:
  --dry-run                Show what would be executed without running updates
  --ct 101,102,103         Update only selected container IDs
  --exclude 104,105        Exclude selected container IDs
  --log-file PATH          Custom log file path (default: ${DEFAULT_LOG_FILE})
  --no-color               Disable colored console output
  --parallel N             Number of containers to update simultaneously
  --timeout SECONDS        Timeout per container (default: ${DEFAULT_TIMEOUT})
  --apt-mode MODE          upgrade | dist-upgrade (default: upgrade)
  -h, --help               Show this help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --ct 101,102
  $SCRIPT_NAME --exclude 103 --timeout 3600
  $SCRIPT_NAME --log-file /root/pve-lxc-update.log
  $SCRIPT_NAME --parallel 3
  $SCRIPT_NAME --apt-mode dist-upgrade
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
    local required_commands=(pct awk grep timeout)

    if [[ "$PARALLEL_JOBS" -gt 1 ]]; then
        required_commands+=(mktemp)
    fi

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        exit 1
    fi
}

parse_args() {
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
            --parallel)
                PARALLEL_JOBS="${2:-}"
                [[ ! "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]] && {
                    log_error "Invalid --parallel value: $PARALLEL_JOBS"
                    exit 1
                }
                shift 2
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

setup_parallel_runtime() {
    [[ "$PARALLEL_JOBS" -le 1 ]] && return 0

    RUN_STATE_DIR="$(mktemp -d "/tmp/${SCRIPT_NAME}.XXXXXX")" || {
        log_error "Failed to create temporary directory for parallel mode"
        exit 1
    }
}

cleanup_parallel_runtime() {
    if [[ -n "$RUN_STATE_DIR" && -d "$RUN_STATE_DIR" ]]; then
        rm -rf "$RUN_STATE_DIR"
        RUN_STATE_DIR=""
    fi
}

terminate_active_jobs() {
    local pid

    for pid in "${ACTIVE_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done

    for pid in "${ACTIVE_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

remove_active_job_at_index() {
    local index="$1"

    unset "ACTIVE_PIDS[$index]"
    unset "ACTIVE_CTS[$index]"
    unset "ACTIVE_JOB_LOGS[$index]"
    unset "ACTIVE_DONE_FILES[$index]"

    ACTIVE_PIDS=("${ACTIVE_PIDS[@]}")
    ACTIVE_CTS=("${ACTIVE_CTS[@]}")
    ACTIVE_JOB_LOGS=("${ACTIVE_JOB_LOGS[@]}")
    ACTIVE_DONE_FILES=("${ACTIVE_DONE_FILES[@]}")
}

register_container_result() {
    local ctid="$1"
    local rc="$2"

    case "$rc" in
        0)
            ((SUCCESS_COUNT++))
            ;;
        2)
            ((SKIPPED_COUNT++))
            SKIPPED_CONTAINERS+=("$ctid")
            ;;
        *)
            ((FAILED_COUNT++))
            FAILED_CONTAINERS+=("$ctid")
            ;;
    esac
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

is_container_running() {
    local ctid="$1"
    pct status "$ctid" 2>/dev/null | grep -q '^status: running$'
}

get_container_status() {
    local ctid="$1"

    pct status "$ctid" 2>/dev/null | awk -F': ' '$1=="status" {print $2; exit}'
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

detect_os_type() {
    local ctid="$1"
    local ostype

    ostype="$(get_config_value "$ctid" "ostype")"

    if [[ -n "$ostype" ]]; then
        echo "$ostype"
        return 0
    fi

    if pct exec "$ctid" -- test -f /etc/debian_version >/dev/null 2>&1; then
        echo "debian"
    elif pct exec "$ctid" -- test -f /etc/redhat-release >/dev/null 2>&1; then
        echo "centos"
    elif pct exec "$ctid" -- test -f /etc/alpine-release >/dev/null 2>&1; then
        echo "alpine"
    elif pct exec "$ctid" -- test -f /etc/arch-release >/dev/null 2>&1; then
        echo "archlinux"
    else
        echo "unknown"
    fi
}

build_apt_command() {
    local mode="$1"
    local action="upgrade"

    if [[ "$mode" == "dist-upgrade" ]]; then
        action="dist-upgrade"
    fi

    cat <<EOF
export DEBIAN_FRONTEND=noninteractive
apt-get ${APT_ACQUIRE_OPTIONS} update &&
apt-get ${APT_ACQUIRE_OPTIONS} -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold ${action} &&
apt-get autoremove -y &&
apt-get autoclean -y
EOF
}

build_fallback_command() {
    local apt_cmd

    apt_cmd="$(build_apt_command "$APT_MODE")"

    cat <<EOF
if command -v apt-get >/dev/null 2>&1; then
$apt_cmd
elif command -v dnf >/dev/null 2>&1; then
    dnf update -y &&
    dnf clean all
elif command -v yum >/dev/null 2>&1; then
    yum update -y &&
    yum clean all
elif command -v apk >/dev/null 2>&1; then
    apk update &&
    apk upgrade &&
    apk cache clean
elif command -v pacman >/dev/null 2>&1; then
    pacman -Syu --noconfirm &&
    pacman -Sc --noconfirm
else
    echo "Could not determine package manager"
    exit 1
fi
EOF
}

build_update_command() {
    local ostype="$1"

    case "$ostype" in
        ubuntu|debian)
            build_apt_command "$APT_MODE"
            ;;
        alpine)
            cat <<'EOF'
apk update &&
apk upgrade &&
apk cache clean
EOF
            ;;
        archlinux)
            cat <<'EOF'
pacman -Syu --noconfirm &&
pacman -Sc --noconfirm
EOF
            ;;
        centos|fedora|rocky|almalinux)
            cat <<'EOF'
if command -v dnf >/dev/null 2>&1; then
    dnf update -y &&
    dnf clean all
elif command -v yum >/dev/null 2>&1; then
    yum update -y &&
    yum clean all
else
    echo "dnf/yum not found"
    exit 1
fi
EOF
            ;;
        *)
            build_fallback_command
            ;;
    esac
}

handle_termination() {
    local signal_name="$1"

    log_error "Execution interrupted by signal ${signal_name}"
    terminate_active_jobs
    cleanup_parallel_runtime
    exit 130
}

start_parallel_job() {
    local ctid="$1"
    local job_log="${RUN_STATE_DIR}/ct-${ctid}.log"
    local done_file="${RUN_STATE_DIR}/ct-${ctid}.done"
    local pid

    rm -f "$job_log" "$done_file"

    (
        local rc

        LOG_FILE="$job_log"
        LOG_READY=1

        if update_container "$ctid"; then
            rc=0
        else
            rc=$?
        fi

        : > "$done_file"
        exit "$rc"
    ) &
    pid=$!

    ACTIVE_PIDS+=("$pid")
    ACTIVE_CTS+=("$ctid")
    ACTIVE_JOB_LOGS+=("$job_log")
    ACTIVE_DONE_FILES+=("$done_file")
}

collect_parallel_job() {
    local index="$1"
    local pid="${ACTIVE_PIDS[$index]}"
    local ctid="${ACTIVE_CTS[$index]}"
    local job_log="${ACTIVE_JOB_LOGS[$index]}"
    local done_file="${ACTIVE_DONE_FILES[$index]}"
    local rc

    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi

    if [[ -f "$job_log" ]]; then
        cat "$job_log" >> "$LOG_FILE"
        rm -f "$job_log"
    fi

    rm -f "$done_file"
    register_container_result "$ctid" "$rc"
    remove_active_job_at_index "$index"
}

wait_for_any_parallel_job() {
    local index

    [[ "${#ACTIVE_PIDS[@]}" -eq 0 ]] && return 0

    while true; do
        for index in "${!ACTIVE_PIDS[@]}"; do
            if [[ -f "${ACTIVE_DONE_FILES[$index]}" ]]; then
                collect_parallel_job "$index"
                return 0
            fi
        done

        sleep 1
    done
}

wait_for_all_parallel_jobs() {
    while [[ "${#ACTIVE_PIDS[@]}" -gt 0 ]]; do
        wait_for_any_parallel_job
    done
}

update_container() {
    local ctid="$1"
    local name
    local ostype
    local lock
    local cmd
    local rc=0

    name="$(get_container_name "$ctid")"
    ostype="$(detect_os_type "$ctid")"
    lock="$(get_container_lock "$ctid")"

    if [[ -n "$name" ]]; then
        log_info "Container $ctid ($name), ostype=$ostype"
    else
        log_info "Container $ctid, ostype=$ostype"
    fi

    if ! is_container_running "$ctid"; then
        log_warning "Container $ctid is no longer in running state, skipping"
        return 2
    fi

    if [[ -n "$lock" ]]; then
        log_warning "Container $ctid has lock=$lock, skipping"
        return 2
    fi

    cmd="$(build_update_command "$ostype")"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Container $ctid would be updated"
        printf '[%s] [INFO] %s\n' "$(timestamp)" "$SEPARATOR" >> "$LOG_FILE"
        printf '[%s] [INFO] DRY-RUN CT %s ostype=%s\n' "$(timestamp)" "$ctid" "$ostype" >> "$LOG_FILE"
        printf '%s\n' "$cmd" >> "$LOG_FILE"
        return 0
    fi

    log_info "Starting update for container $ctid (timeout=${PER_CONTAINER_TIMEOUT}s)"
    printf '[%s] [INFO] %s\n' "$(timestamp)" "$SEPARATOR" >> "$LOG_FILE"
    printf '[%s] [INFO] BEGIN CT %s\n' "$(timestamp)" "$ctid" >> "$LOG_FILE"

    timeout "$PER_CONTAINER_TIMEOUT" pct exec "$ctid" -- sh -c "$cmd" >> "$LOG_FILE" 2>&1
    rc=$?

    case "$rc" in
        0)
            log_success "Container $ctid updated successfully"
            ;;
        124)
            log_error "Container $ctid: timeout exceeded (${PER_CONTAINER_TIMEOUT}s)"
            ;;
        *)
            log_error "Failed to update container $ctid (exit code: $rc)"
            ;;
    esac

    printf '[%s] [INFO] END CT %s rc=%s\n' "$(timestamp)" "$ctid" "$rc" >> "$LOG_FILE"
    return "$rc"
}

run_containers_sequential() {
    local containers="$1"
    local ct
    local rc

    while IFS= read -r ct; do
        [[ -z "$ct" ]] && continue

        ((TOTAL_COUNT++))
        echo "$SEPARATOR" >&2

        if update_container "$ct"; then
            rc=0
        else
            rc=$?
        fi

        register_container_result "$ct" "$rc"
        sleep 1
    done <<< "$containers"
}

run_containers_parallel() {
    local containers="$1"
    local ct

    setup_parallel_runtime

    while IFS= read -r ct; do
        [[ -z "$ct" ]] && continue

        ((TOTAL_COUNT++))
        start_parallel_job "$ct"

        if [[ "${#ACTIVE_PIDS[@]}" -ge "$PARALLEL_JOBS" ]]; then
            wait_for_any_parallel_job
        fi
    done <<< "$containers"

    wait_for_all_parallel_jobs
    cleanup_parallel_runtime
}

main() {
    local start_time
    local end_time
    local execution_time

    parse_args "$@"
    check_permissions
    ensure_log_file
    check_dependencies
    warn_overlapping_filters
    warn_requested_container_states

    trap 'handle_termination INT' INT
    trap 'handle_termination TERM' TERM

    start_time="$(date +%s)"

    log_info "Starting automatic LXC container updates"
    log_info "Start time: $(date)"
    log_info "Log file: $LOG_FILE"
    log_info "Dry-run mode: $DRY_RUN"
    log_info "APT mode: $APT_MODE"
    log_info "Parallel jobs: $PARALLEL_JOBS"
    if [[ -n "$INCLUDE_CTS" ]]; then
        log_info "--ct filter: $INCLUDE_CTS"
    fi
    if [[ -n "$EXCLUDE_CTS" ]]; then
        log_info "--exclude filter: $EXCLUDE_CTS"
    fi
    echo "$SEPARATOR" >&2

    local containers
    if ! containers="$(get_lxc_containers)"; then
        log_warning "No eligible running LXC containers found for update"
        exit 0
    fi

    local container_count
    container_count="$(printf '%s\n' "$containers" | wc -l)"
    log_info "Containers selected for processing: $container_count"

    if [[ "$PARALLEL_JOBS" -gt 1 ]]; then
        run_containers_parallel "$containers"
    else
        run_containers_sequential "$containers"
    fi

    end_time="$(date +%s)"
    execution_time=$((end_time - start_time))

    echo "========================================" >&2
    log_info "=== UPDATE RESULTS ==="
    log_info "Total execution time: ${execution_time} seconds"
    log_info "Total containers processed: $TOTAL_COUNT"
    log_success "Successfully updated: $SUCCESS_COUNT"

    if [[ "$SKIPPED_COUNT" -gt 0 ]]; then
        log_warning "Skipped: $SKIPPED_COUNT (${SKIPPED_CONTAINERS[*]})"
    fi

    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        log_error "Failed: $FAILED_COUNT (${FAILED_CONTAINERS[*]})"
    fi

    log_info "Finish time: $(date)"
    cleanup_parallel_runtime

    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

main "$@"
