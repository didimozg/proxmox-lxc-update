#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================
# Proxmox backup health check
# ============================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_LOG_FILE="/var/log/pve-backup-health-check.log"
readonly DEFAULT_WARN_AGE_HOURS=192
readonly DEFAULT_CRIT_AGE_HOURS=336
readonly DEFAULT_RECENT_PROBLEM_HOURS=336
readonly DEFAULT_TASK_LIMIT=30
readonly DEFAULT_PROBLEM_LIMIT=10
readonly DEFAULT_TELEGRAM_TIMEOUT=15
readonly DEFAULT_TELEGRAM_NOTIFY_ON_OK=1
readonly DEFAULT_TELEGRAM_MESSAGE_LIMIT=3500

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Options
LOG_FILE="$DEFAULT_LOG_FILE"
LOG_READY=0
USE_COLOR=1
NODE_FILTER=""
WARN_AGE_HOURS="$DEFAULT_WARN_AGE_HOURS"
CRIT_AGE_HOURS="$DEFAULT_CRIT_AGE_HOURS"
RECENT_PROBLEM_HOURS="$DEFAULT_RECENT_PROBLEM_HOURS"
TASK_LIMIT="$DEFAULT_TASK_LIMIT"
PROBLEM_LIMIT="$DEFAULT_PROBLEM_LIMIT"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_THREAD_ID="${TELEGRAM_THREAD_ID:-}"
TELEGRAM_TIMEOUT="${TELEGRAM_TIMEOUT:-$DEFAULT_TELEGRAM_TIMEOUT}"
TELEGRAM_NOTIFY_ON_OK="${TELEGRAM_NOTIFY_ON_OK:-$DEFAULT_TELEGRAM_NOTIFY_ON_OK}"
TMP_DIR=""
REPORT_FILE=""
RUN_STARTED=0

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

usage() {
    cat >&2 <<EOF
Usage: $SCRIPT_NAME [options]

Cluster-wide health check for Proxmox vzdump backup jobs and recent backup tasks.

Options:
  --node pve-node-1,pve-node-2 Limit checks to selected cluster nodes
  --warn-age-hours HOURS       Warn when the latest successful vzdump on a node is older than this (default: ${DEFAULT_WARN_AGE_HOURS})
  --crit-age-hours HOURS       Critical when the latest successful vzdump on a node is older than this (default: ${DEFAULT_CRIT_AGE_HOURS})
  --recent-problem-hours HOURS Treat recent failed or warning tasks inside this window as active issues (default: ${DEFAULT_RECENT_PROBLEM_HOURS})
  --task-limit N               Number of recent vzdump tasks to inspect per node (default: ${DEFAULT_TASK_LIMIT})
  --problem-limit N            Number of recent problematic tasks to print (default: ${DEFAULT_PROBLEM_LIMIT})
  --log-file PATH              Custom log file path (default: ${DEFAULT_LOG_FILE})
  --telegram-bot-token TOKEN   Telegram bot token (prefer env or systemd EnvironmentFile in production)
  --telegram-chat-id ID        Telegram chat ID for notifications
  --telegram-thread-id ID      Optional Telegram topic/thread ID
  --telegram-timeout SECONDS   Telegram API timeout (default: ${DEFAULT_TELEGRAM_TIMEOUT})
  --telegram-no-ok             Skip Telegram notifications for OK results
  --no-color                   Disable colored console output
  -h, --help                   Show this help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --node pve-node-1
  $SCRIPT_NAME --warn-age-hours 48 --crit-age-hours 96
  $SCRIPT_NAME --task-limit 50 --problem-limit 15
  TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... $SCRIPT_NAME --telegram-no-ok
EOF
}

normalize_csv_names() {
    local value="${1//[[:space:]]/}"

    value="${value#,}"
    value="${value%,}"
    printf '%s' "$value"
}

validate_csv_names() {
    local option_name="$1"
    local value="$2"

    if [[ -z "$value" || ! "$value" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
        log_error "Invalid ${option_name} value: expected a comma-separated list of node names"
        exit 1
    fi
}

validate_positive_integer() {
    local option_name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        log_error "Invalid ${option_name} value: $value"
        exit 1
    fi
}

validate_signed_integer() {
    local option_name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
        log_error "Invalid ${option_name} value: $value"
        exit 1
    fi
}

validate_zero_or_one() {
    local option_name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[01]$ ]]; then
        log_error "Invalid ${option_name} value: $value"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node)
                NODE_FILTER="$(normalize_csv_names "${2:-}")"
                validate_csv_names "--node" "$NODE_FILTER"
                shift 2
                ;;
            --warn-age-hours)
                WARN_AGE_HOURS="${2:-}"
                validate_positive_integer "--warn-age-hours" "$WARN_AGE_HOURS"
                shift 2
                ;;
            --crit-age-hours)
                CRIT_AGE_HOURS="${2:-}"
                validate_positive_integer "--crit-age-hours" "$CRIT_AGE_HOURS"
                shift 2
                ;;
            --recent-problem-hours)
                RECENT_PROBLEM_HOURS="${2:-}"
                validate_positive_integer "--recent-problem-hours" "$RECENT_PROBLEM_HOURS"
                shift 2
                ;;
            --task-limit)
                TASK_LIMIT="${2:-}"
                validate_positive_integer "--task-limit" "$TASK_LIMIT"
                shift 2
                ;;
            --problem-limit)
                PROBLEM_LIMIT="${2:-}"
                validate_positive_integer "--problem-limit" "$PROBLEM_LIMIT"
                shift 2
                ;;
            --log-file)
                LOG_FILE="${2:-}"
                [[ -z "$LOG_FILE" || "$LOG_FILE" == --* ]] && { log_error "Empty or invalid value for --log-file"; exit 1; }
                shift 2
                ;;
            --telegram-bot-token)
                TELEGRAM_BOT_TOKEN="${2:-}"
                [[ -z "$TELEGRAM_BOT_TOKEN" || "$TELEGRAM_BOT_TOKEN" == --* ]] && { log_error "Empty or invalid value for --telegram-bot-token"; exit 1; }
                shift 2
                ;;
            --telegram-chat-id)
                TELEGRAM_CHAT_ID="${2:-}"
                validate_signed_integer "--telegram-chat-id" "$TELEGRAM_CHAT_ID"
                shift 2
                ;;
            --telegram-thread-id)
                TELEGRAM_THREAD_ID="${2:-}"
                validate_positive_integer "--telegram-thread-id" "$TELEGRAM_THREAD_ID"
                shift 2
                ;;
            --telegram-timeout)
                TELEGRAM_TIMEOUT="${2:-}"
                validate_positive_integer "--telegram-timeout" "$TELEGRAM_TIMEOUT"
                shift 2
                ;;
            --telegram-no-ok)
                TELEGRAM_NOTIFY_ON_OK=0
                shift
                ;;
            --no-color)
                USE_COLOR=0
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

    if (( WARN_AGE_HOURS >= CRIT_AGE_HOURS )); then
        log_error "--warn-age-hours must be lower than --crit-age-hours"
        exit 1
    fi

    validate_zero_or_one "TELEGRAM_NOTIFY_ON_OK" "$TELEGRAM_NOTIFY_ON_OK"
    validate_positive_integer "TELEGRAM_TIMEOUT" "$TELEGRAM_TIMEOUT"

    if [[ -n "$TELEGRAM_CHAT_ID" ]]; then
        validate_signed_integer "--telegram-chat-id" "$TELEGRAM_CHAT_ID"
    fi

    if [[ -n "$TELEGRAM_THREAD_ID" ]]; then
        validate_positive_integer "--telegram-thread-id" "$TELEGRAM_THREAD_ID"
    fi

    if [[ -n "$TELEGRAM_BOT_TOKEN" || -n "$TELEGRAM_CHAT_ID" || -n "$TELEGRAM_THREAD_ID" ]]; then
        if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
            log_error "Telegram notifications require both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
            exit 1
        fi
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
    local required_commands=(pvesh python3 mktemp)
    local cmd

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            missing=1
        fi
    done

    if telegram_enabled; then
        if ! command -v curl >/dev/null 2>&1; then
            log_error "Required command not found for Telegram notifications: curl"
            missing=1
        fi
    fi

    if [[ "$missing" -ne 0 ]]; then
        exit 1
    fi
}

setup_runtime() {
    TMP_DIR="$(mktemp -d "/tmp/${SCRIPT_NAME}.XXXXXX")" || {
        log_error "Failed to create a temporary runtime directory"
        exit 1
    }
}

cleanup_runtime() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
        TMP_DIR=""
    fi
}

telegram_enabled() {
    [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]
}

build_telegram_message() {
    local rc="$1"
    local host_name

    if ! host_name="$(hostname -s 2>/dev/null)"; then
        host_name="$(hostname 2>/dev/null || printf 'unknown-host')"
    fi

    if [[ -z "$REPORT_FILE" || ! -f "$REPORT_FILE" ]]; then
        REPORT_FILE="$TMP_DIR/telegram-fallback-report.txt"
        cat > "$REPORT_FILE" <<EOF
=== PROXMOX BACKUP HEALTH CHECK ===
Generated at: $(date)

No report content is available because the script exited before the report was generated.
Check the log file for details: $LOG_FILE
EOF
    fi

    python3 - "$rc" "$host_name" "$LOG_FILE" "$DEFAULT_TELEGRAM_MESSAGE_LIMIT" < "$REPORT_FILE" <<'PY'
import sys

rc = int(sys.argv[1])
host_name = sys.argv[2]
log_file = sys.argv[3]
limit = int(sys.argv[4])
report = sys.stdin.read().strip()

status = {
    0: "OK",
    1: "WARN",
    2: "CRIT",
}.get(rc, "ERROR")

prefix = (
    f"Proxmox backup health check on {host_name}\n"
    f"Status: {status}\n"
    f"Log: {log_file}\n\n"
)
message = prefix + (report or "No report content available.")

if len(message) > limit:
    suffix = "\n\n[truncated in Telegram; see the log file for the full report]"
    message = message[: limit - len(suffix)] + suffix

print(message)
PY
}

send_telegram_notification() {
    local rc="$1"
    local message_file="$TMP_DIR/telegram-message.txt"
    local curl_stderr_file="$TMP_DIR/telegram-curl.stderr"
    local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    local -a curl_args

    if ! telegram_enabled; then
        return 0
    fi

    if [[ "$TELEGRAM_NOTIFY_ON_OK" -eq 0 && "$rc" -eq 0 ]]; then
        log_info "Skipping Telegram notification for OK result"
        return 0
    fi

    if ! build_telegram_message "$rc" > "$message_file"; then
        log_warning "Failed to build Telegram notification payload"
        return 0
    fi

    curl_args=(
        --silent
        --show-error
        --fail
        --connect-timeout "$TELEGRAM_TIMEOUT"
        --max-time "$(( TELEGRAM_TIMEOUT * 2 ))"
        --retry 2
        --retry-delay 2
        -X POST "$api_url"
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"
        --data-urlencode "text@${message_file}"
        --data-urlencode "disable_web_page_preview=true"
    )

    if [[ -n "$TELEGRAM_THREAD_ID" ]]; then
        curl_args+=(--data-urlencode "message_thread_id=${TELEGRAM_THREAD_ID}")
    fi

    if curl "${curl_args[@]}" > /dev/null 2> "$curl_stderr_file"; then
        log_success "Telegram notification sent"
        return 0
    fi

    log_info "Retrying Telegram notification over IPv4"

    if curl -4 "${curl_args[@]}" > /dev/null 2> "$curl_stderr_file"; then
        log_warning "Telegram notification required IPv4 fallback"
        log_success "Telegram notification sent"
        return 0
    fi

    if [[ -s "$curl_stderr_file" ]]; then
        log_warning "Telegram API error: $(tr '\n' ' ' < "$curl_stderr_file")"
    fi

    log_warning "Failed to send Telegram notification"
}

handle_exit() {
    local rc="$1"

    if [[ "$RUN_STARTED" -eq 1 ]]; then
        send_telegram_notification "$rc"
        cleanup_runtime
    fi
}

fetch_json() {
    local api_path="$1"
    local output_file="$2"
    local allow_failure="${3:-0}"

    if pvesh get "$api_path" --output-format json > "$output_file" 2> "${output_file}.err"; then
        rm -f "${output_file}.err"
        return 0
    fi

    if [[ "$allow_failure" -eq 1 ]]; then
        printf '[]\n' > "$output_file"
        return 0
    fi

    log_error "Failed to query ${api_path}"
    if [[ -s "${output_file}.err" ]]; then
        while IFS= read -r line; do
            log_error "$line"
        done < "${output_file}.err"
    fi
    exit 1
}

get_cluster_nodes() {
    python3 - "$TMP_DIR/nodes.json" "$NODE_FILTER" <<'PY'
import json
import sys

nodes_path = sys.argv[1]
node_filter = sys.argv[2]

with open(nodes_path, "r", encoding="utf-8") as fh:
    nodes = json.load(fh)

available = [entry["node"] for entry in nodes if entry.get("node")]

if node_filter:
    requested = [item for item in node_filter.split(",") if item]
    missing = [item for item in requested if item not in available]
    if missing:
        print("ERROR: unknown node(s): " + ", ".join(missing))
        sys.exit(2)
    selected = requested
else:
    selected = available

for node in selected:
    print(node)
PY
}

collect_cluster_data() {
    local node
    local task_file
    local node_output

    fetch_json "/cluster/backup" "$TMP_DIR/jobs.json"
    fetch_json "/nodes" "$TMP_DIR/nodes.json"
    fetch_json "/cluster/resources" "$TMP_DIR/resources.json"
    fetch_json "/cluster/backup-info/not-backed-up" "$TMP_DIR/not-backed-up.json" 1

    if ! node_output="$(get_cluster_nodes 2>&1)"; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && log_error "$line"
        done <<< "$node_output"
        exit 1
    fi

    mapfile -t CLUSTER_NODES <<< "$node_output"
    if [[ "${#CLUSTER_NODES[@]}" -eq 0 ]]; then
        log_error "No cluster nodes were selected"
        exit 1
    fi

    for node in "${CLUSTER_NODES[@]}"; do
        task_file="$TMP_DIR/tasks-${node}.json"
        if ! pvesh get "/nodes/${node}/tasks" --typefilter vzdump --limit "$TASK_LIMIT" --output-format json > "$task_file" 2> "${task_file}.err"; then
            printf '[]\n' > "$task_file"
        fi
    done
}

print_report() {
    local report_file="$TMP_DIR/report.txt"
    local rc

    REPORT_FILE="$report_file"

    if python3 - "$TMP_DIR" "$WARN_AGE_HOURS" "$CRIT_AGE_HOURS" "$RECENT_PROBLEM_HOURS" "$PROBLEM_LIMIT" > "$report_file" <<'PY'
import json
import os
import sys
from datetime import datetime

tmp_dir = sys.argv[1]
warn_age_hours = int(sys.argv[2])
crit_age_hours = int(sys.argv[3])
recent_problem_hours = int(sys.argv[4])
problem_limit = int(sys.argv[5])

SEVERITY_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2}

def load_json(name, default):
    path = os.path.join(tmp_dir, name)
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

def read_error(name):
    path = os.path.join(tmp_dir, name)
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().strip()

def format_ts(ts):
    if not ts:
        return "n/a"
    return datetime.fromtimestamp(ts).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")

def age_hours(ts, now_ts):
    if not ts:
        return None
    return max(0.0, (now_ts - ts) / 3600.0)

def format_age(hours):
    if hours is None:
        return "n/a"
    total = int(round(hours))
    days, rem = divmod(total, 24)
    parts = []
    if days:
        parts.append(f"{days}d")
    parts.append(f"{rem}h")
    return " ".join(parts)

def combine(current, new):
    return new if SEVERITY_ORDER[new] > SEVERITY_ORDER[current] else current

jobs = load_json("jobs.json", [])
nodes = load_json("nodes.json", [])
resources = load_json("resources.json", [])
not_backed_up = load_json("not-backed-up.json", [])
task_files = sorted(name for name in os.listdir(tmp_dir) if name.startswith("tasks-") and name.endswith(".json"))
now_ts = datetime.now().astimezone().timestamp()

enabled_jobs = [job for job in jobs if job.get("type") == "vzdump" and int(job.get("enabled", 1)) == 1]
disabled_jobs = [job for job in jobs if job.get("type") == "vzdump" and int(job.get("enabled", 1)) == 0]

node_info = {}
for node in nodes:
    if node.get("node"):
        node_info[node["node"]] = node

vm_container_counts = {}
for resource in resources:
    if resource.get("type") not in {"lxc", "qemu"}:
        continue
    if int(resource.get("template", 0)) == 1:
        continue
    node = resource.get("node")
    if not node:
        continue
    vm_container_counts[node] = vm_container_counts.get(node, 0) + 1

overall = "OK"
lines = []
problem_tasks = []

lines.append("=== PROXMOX BACKUP HEALTH CHECK ===")
lines.append(f"Generated at: {format_ts(now_ts)}")
lines.append(f"Thresholds: warn>{warn_age_hours}h crit>{crit_age_hours}h recent-problems<={recent_problem_hours}h")
lines.append("")

if not enabled_jobs:
    overall = "CRIT"
    lines.append("Enabled backup jobs: 0")
else:
    lines.append(f"Enabled backup jobs: {len(enabled_jobs)}")
lines.append(f"Disabled backup jobs: {len(disabled_jobs)}")
lines.append("")

lines.append("Configured backup jobs:")
if jobs:
    for job in enabled_jobs + disabled_jobs:
        enabled_text = "enabled" if int(job.get("enabled", 1)) == 1 else "disabled"
        schedule = job.get("schedule", "n/a")
        mode = job.get("mode", "n/a")
        storage = job.get("storage", "n/a")
        next_run = format_ts(job.get("next-run"))
        scope = "all" if int(job.get("all", 0)) == 1 else job.get("vmid", job.get("node", "custom"))
        lines.append(f"- {job.get('id', 'unknown')}: {enabled_text}, schedule={schedule}, mode={mode}, storage={storage}, scope={scope}, next-run={next_run}")
else:
    lines.append("- no vzdump jobs found")
lines.append("")

lines.append("Node health:")
for task_file in task_files:
    node = task_file[len("tasks-"):-len(".json")]
    tasks = load_json(task_file, [])
    task_error = read_error(task_file + ".err")
    info = node_info.get(node, {})
    node_status = info.get("status", "unknown")
    vm_container_count = vm_container_counts.get(node, 0)

    latest = tasks[0] if tasks else None
    latest_success = next((task for task in tasks if task.get("status") == "OK"), None)
    latest_warning = next((task for task in tasks if str(task.get("status", "")).startswith("WARNINGS")), None)
    latest_failure = next((task for task in tasks if task.get("status") not in (None, "", "OK") and not str(task.get("status", "")).startswith("WARNINGS")), None)

    success_ts = (latest_success or {}).get("endtime") or (latest_success or {}).get("starttime")
    success_age = age_hours(success_ts, now_ts)
    warning_ts = (latest_warning or {}).get("endtime") or (latest_warning or {}).get("starttime")
    warning_age = age_hours(warning_ts, now_ts)
    failure_ts = (latest_failure or {}).get("endtime") or (latest_failure or {}).get("starttime")
    failure_age = age_hours(failure_ts, now_ts)

    node_severity = "OK"
    reasons = []

    if task_error:
        node_severity = "CRIT"
        reasons.append("failed to query recent vzdump tasks")
    elif node_status != "online":
        node_severity = "CRIT" if vm_container_count > 0 else "WARN"
        reasons.append(f"node status={node_status}")
    elif vm_container_count == 0 and not tasks:
        reasons.append("no VMs or containers on node")
    elif latest_success is None:
        node_severity = "CRIT"
        reasons.append("no successful vzdump task found")
    else:
        if success_age is not None and success_age > crit_age_hours:
            node_severity = "CRIT"
            reasons.append(f"latest success is older than {crit_age_hours}h")
        elif success_age is not None and success_age > warn_age_hours:
            node_severity = combine(node_severity, "WARN")
            reasons.append(f"latest success is older than {warn_age_hours}h")

        if latest_failure is not None and failure_age is not None and failure_age <= recent_problem_hours:
            node_severity = "CRIT"
            reasons.append(f"recent failed task: {latest_failure.get('status')}")
            problem_tasks.append((failure_ts or 0, node, latest_failure.get("status", "ERROR"), latest_failure.get("upid", "")))

        if latest_warning is not None and warning_age is not None and warning_age <= recent_problem_hours:
            node_severity = combine(node_severity, "WARN")
            reasons.append(f"recent warning task: {latest_warning.get('status')}")
            problem_tasks.append((warning_ts or 0, node, latest_warning.get("status", "WARNINGS"), latest_warning.get("upid", "")))

    overall = combine(overall, node_severity)

    latest_status = latest.get("status", "n/a") if latest else "n/a"
    latest_finished = format_ts((latest or {}).get("endtime") or (latest or {}).get("starttime"))
    latest_success_finished = format_ts(success_ts)
    latest_success_age = format_age(success_age)
    reason_text = "; ".join(reasons) if reasons else "healthy"
    lines.append(
        f"- {node}: {node_severity} | vm-and-container-count={vm_container_count} | node-status={node_status} | "
        f"latest-task={latest_status} at {latest_finished} | latest-success={latest_success_finished} ({latest_success_age}) | {reason_text}"
    )
lines.append("")

cluster_problem_tasks = []
for task_file in task_files:
    node = task_file[len("tasks-"):-len(".json")]
    tasks = load_json(task_file, [])
    for task in tasks:
        status = str(task.get("status", ""))
        if status == "OK":
            continue
        task_ts = task.get("endtime") or task.get("starttime") or 0
        task_age = age_hours(task_ts, now_ts)
        if task_age is None or task_age > recent_problem_hours:
            continue
        cluster_problem_tasks.append((
            task_ts,
            node,
            status or "UNKNOWN",
            task.get("upid", ""),
        ))

cluster_problem_tasks.sort(reverse=True)
lines.append("Recent problematic tasks:")
if cluster_problem_tasks:
    for ts, node, status, upid in cluster_problem_tasks[:problem_limit]:
        lines.append(f"- {node}: {status} at {format_ts(ts)} | {upid}")
else:
    lines.append("- none")
lines.append("")

lines.append("VMs and containers not covered by backup jobs:")
if not_backed_up:
    overall = combine(overall, "WARN")
    for workload in not_backed_up:
        workload_id = workload.get("vmid", workload.get("id", "unknown"))
        workload_node = workload.get("node", "unknown")
        workload_type = workload.get("type", "unknown")
        workload_name = workload.get("name", "unknown")
        lines.append(f"- {workload_type}/{workload_id} on {workload_node}: {workload_name}")
else:
    lines.append("- none")
lines.append("")

lines.append(f"Overall status: {overall}")

print("\n".join(lines))
sys.exit(0 if overall == "OK" else 1 if overall == "WARN" else 2)
PY
    then
        rc=0
    else
        rc=$?
    fi

    cat "$report_file" >&2
    cat "$report_file" >> "$LOG_FILE"
    return "$rc"
}

main() {
    local start_time
    local rc

    parse_args "$@"
    check_permissions
    ensure_log_file
    check_dependencies
    setup_runtime
    RUN_STARTED=1
    trap 'handle_exit $?' EXIT

    start_time="$(date +%s)"

    log_info "Starting Proxmox backup health check"
    log_info "Start time: $(date)"
    log_info "Log file: $LOG_FILE"
    log_info "Task limit per node: $TASK_LIMIT"
    log_info "Warn age threshold: ${WARN_AGE_HOURS}h"
    log_info "Critical age threshold: ${CRIT_AGE_HOURS}h"
    log_info "Recent problem window: ${RECENT_PROBLEM_HOURS}h"
    if telegram_enabled; then
        log_info "Telegram notifications: enabled"
        log_info "Telegram notify on OK: $TELEGRAM_NOTIFY_ON_OK"
    else
        log_info "Telegram notifications: disabled"
    fi
    if [[ -n "$NODE_FILTER" ]]; then
        log_info "Node filter: $NODE_FILTER"
    fi

    collect_cluster_data

    if print_report; then
        rc=0
        log_success "Backup health check completed without warnings"
    else
        rc=$?
        case "$rc" in
            1)
                log_warning "Backup health check completed with warnings"
                ;;
            2)
                log_error "Backup health check completed with critical findings"
                ;;
            *)
                log_error "Backup health check failed unexpectedly (exit code: $rc)"
                ;;
        esac
    fi

    log_info "Total execution time: $(( $(date +%s) - start_time )) seconds"
    log_info "Finish time: $(date)"
    exit "$rc"
}

main "$@"
