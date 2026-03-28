#!/usr/bin/env bash

set -u
set -o pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_SCRIPT_DIR="/media/script"
readonly DEFAULT_SYSTEMD_DIR="/etc/systemd/system"
readonly DEFAULT_CONFIG_FILE="/etc/default/proxmox-backup-health-check"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

USE_COLOR=1
DRY_RUN=0
BACKUP_EXISTING=1
DEPLOY_BACKUP_HEALTH_SYSTEMD=1
OVERWRITE_CONFIG=0
ENABLE_BACKUP_HEALTH_TIMER=0
DISABLE_BACKUP_HEALTH_TIMER=0
INTERACTIVE=0
SSH_PORT=""
SSH_KEY=""
SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"
SCRIPT_DIR="$DEFAULT_SCRIPT_DIR"
SYSTEMD_DIR="$DEFAULT_SYSTEMD_DIR"
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
BACKUP_HEALTH_CHECK_ARGS="${BACKUP_HEALTH_CHECK_ARGS:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_THREAD_ID="${TELEGRAM_THREAD_ID:-}"
TELEGRAM_NOTIFY_ON_OK="${TELEGRAM_NOTIFY_ON_OK:-1}"
TMP_DIR=""
RUN_ID="$(date +%Y%m%d-%H%M%S)"
CONFIG_TEMPLATE_FILE=""

HOSTS=()
SSH_BASE=()
SCP_BASE=()
SSH_OPTIONS=()

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
}

log_info()    { log_raw "INFO"    "$BLUE"   "$1"; }
log_success() { log_raw "SUCCESS" "$GREEN"  "$1"; }
log_warning() { log_raw "WARNING" "$YELLOW" "$1"; }
log_error()   { log_raw "ERROR"   "$RED"    "$1"; }

usage() {
    cat >&2 <<EOF
Usage: $SCRIPT_NAME --host root@192.168.4.10 [options]

Deploy Proxmox maintenance scripts and optional backup-health-check systemd files
to one or more Proxmox nodes over SSH/SCP.

Options:
  --host HOST                    Add a deployment target, for example root@192.168.4.10
  --interactive                  Prompt for deployment paths and backup-health-check config values
  --script-dir PATH              Remote script directory (default: ${DEFAULT_SCRIPT_DIR})
  --systemd-dir PATH             Remote systemd unit directory (default: ${DEFAULT_SYSTEMD_DIR})
  --config-file PATH             Remote backup-health-check config file (default: ${DEFAULT_CONFIG_FILE})
  --backup-health-check-args ARG Remote BACKUP_HEALTH_CHECK_ARGS value for generated config
  --telegram-bot-token TOKEN     Remote Telegram bot token for generated config
  --telegram-chat-id ID          Remote Telegram chat ID for generated config
  --telegram-thread-id ID        Remote Telegram thread ID for generated config
  --telegram-no-ok               Set TELEGRAM_NOTIFY_ON_OK=0 in generated config
  --ssh-port PORT                SSH port for ssh/scp
  --ssh-key PATH                 SSH private key for ssh/scp
  --ssh-option OPTION            Extra ssh/scp -o option, may be used multiple times
  --ssh-bin PATH_OR_NAME         SSH client binary to use (default: ssh)
  --scp-bin PATH_OR_NAME         SCP client binary to use (default: scp)
  --skip-backup-health-systemd   Deploy scripts only, skip service/timer/config handling
  --overwrite-config             Replace the remote backup-health-check config file
  --enable-backup-health-timer   Enable and start proxmox-backup-health-check.timer after deploy
  --disable-backup-health-timer  Disable and stop proxmox-backup-health-check.timer after deploy
  --no-backup                    Do not create remote .bak.<timestamp> copies before overwriting files
  --dry-run                      Print the actions without making changes
  --no-color                     Disable colored output
  -h, --help                     Show this help

Examples:
  $SCRIPT_NAME --host root@192.168.4.10
  $SCRIPT_NAME --host root@192.168.4.10 --host root@192.168.4.12
  $SCRIPT_NAME --interactive
  $SCRIPT_NAME --host root@192.168.4.10 --dry-run
  $SCRIPT_NAME --host root@192.168.4.10 --ssh-option StrictHostKeyChecking=accept-new
  $SCRIPT_NAME --host root@192.168.4.10 --ssh-bin ssh.exe --scp-bin scp.exe
  $SCRIPT_NAME --host root@192.168.4.10 --enable-backup-health-timer
  $SCRIPT_NAME --host root@192.168.4.10 --skip-backup-health-systemd
  $SCRIPT_NAME --host root@192.168.4.10 --overwrite-config --telegram-chat-id 123456789
EOF
}

validate_positive_integer() {
    local option_name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        log_error "Invalid ${option_name} value: $value"
        exit 1
    fi
}

validate_nonempty_value() {
    local option_name="$1"
    local value="$2"

    if [[ -z "$value" || "$value" == --* ]]; then
        log_error "Empty or invalid value for ${option_name}"
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

normalize_csv_hosts() {
    local value="${1//[[:space:]]/}"

    value="${value#,}"
    value="${value%,}"
    printf '%s' "$value"
}

append_hosts_from_csv() {
    local csv="$1"
    local host

    csv="$(normalize_csv_hosts "$csv")"
    [[ -z "$csv" ]] && return 0

    IFS=',' read -r -a _parsed_hosts <<< "$csv"
    for host in "${_parsed_hosts[@]}"; do
        [[ -n "$host" ]] && HOSTS+=("$host")
    done
}

prompt_value() {
    local prompt_label="$1"
    local current_value="$2"
    local var_name="$3"
    local input=""
    local rendered_default=""

    if [[ -n "$current_value" ]]; then
        rendered_default=" [$current_value]"
    fi

    read -r -p "${prompt_label}${rendered_default}: " input
    if [[ -z "$input" ]]; then
        input="$current_value"
    fi

    printf -v "$var_name" '%s' "$input"
}

prompt_secret() {
    local prompt_label="$1"
    local current_value="$2"
    local var_name="$3"
    local input=""
    local rendered_hint=""

    if [[ -n "$current_value" ]]; then
        rendered_hint=" [leave blank to keep current]"
    fi

    read -r -s -p "${prompt_label}${rendered_hint}: " input
    printf '\n' >&2

    if [[ -z "$input" ]]; then
        input="$current_value"
    fi

    printf -v "$var_name" '%s' "$input"
}

prompt_yes_no() {
    local prompt_label="$1"
    local default_value="$2"
    local var_name="$3"
    local input=""
    local prompt_suffix="[y/N]"

    if [[ "$default_value" -eq 1 ]]; then
        prompt_suffix="[Y/n]"
    fi

    read -r -p "${prompt_label} ${prompt_suffix}: " input
    input="${input,,}"

    if [[ -z "$input" ]]; then
        printf -v "$var_name" '%s' "$default_value"
        return 0
    fi

    case "$input" in
        y|yes)
            printf -v "$var_name" '1'
            ;;
        n|no)
            printf -v "$var_name" '0'
            ;;
        *)
            log_warning "Unknown response '$input', using default"
            printf -v "$var_name" '%s' "$default_value"
            ;;
    esac
}

prompt_timer_action() {
    local input=""

    read -r -p "Backup health timer action [k=keep, e=enable, d=disable] [k]: " input
    input="${input,,}"

    ENABLE_BACKUP_HEALTH_TIMER=0
    DISABLE_BACKUP_HEALTH_TIMER=0

    case "$input" in
        ""|k|keep)
            ;;
        e|enable)
            ENABLE_BACKUP_HEALTH_TIMER=1
            ;;
        d|disable)
            DISABLE_BACKUP_HEALTH_TIMER=1
            ;;
        *)
            log_warning "Unknown timer action '$input', keeping current state"
            ;;
    esac
}

run_interactive_setup() {
    local host_input=""
    local configure_telegram=0

    log_info "Interactive mode enabled"

    if [[ "${#HOSTS[@]}" -eq 0 ]]; then
        read -r -p "Deployment hosts (comma-separated, for example root@192.168.4.10,root@192.168.4.12): " host_input
        append_hosts_from_csv "$host_input"
    fi

    prompt_value "Remote script directory" "$SCRIPT_DIR" SCRIPT_DIR
    prompt_value "SSH port (leave blank for default)" "$SSH_PORT" SSH_PORT
    prompt_value "SSH key path (leave blank for default)" "$SSH_KEY" SSH_KEY
    prompt_yes_no "Create remote backup copies before overwriting files?" "$BACKUP_EXISTING" BACKUP_EXISTING
    prompt_yes_no "Deploy backup-health-check systemd files?" "$DEPLOY_BACKUP_HEALTH_SYSTEMD" DEPLOY_BACKUP_HEALTH_SYSTEMD

    if [[ "$DEPLOY_BACKUP_HEALTH_SYSTEMD" -eq 1 ]]; then
        prompt_value "Remote systemd directory" "$SYSTEMD_DIR" SYSTEMD_DIR
        prompt_value "Remote backup-health-check config file" "$CONFIG_FILE" CONFIG_FILE
        prompt_yes_no "Overwrite existing backup-health-check config if present?" "$OVERWRITE_CONFIG" OVERWRITE_CONFIG
        prompt_value "Generated BACKUP_HEALTH_CHECK_ARGS value" "$BACKUP_HEALTH_CHECK_ARGS" BACKUP_HEALTH_CHECK_ARGS
        prompt_yes_no "Populate Telegram values in generated config?" 0 configure_telegram

        if [[ "$configure_telegram" -eq 1 ]]; then
            prompt_secret "Telegram bot token" "$TELEGRAM_BOT_TOKEN" TELEGRAM_BOT_TOKEN
            prompt_value "Telegram chat ID" "$TELEGRAM_CHAT_ID" TELEGRAM_CHAT_ID
            prompt_value "Telegram thread ID (optional)" "$TELEGRAM_THREAD_ID" TELEGRAM_THREAD_ID
            prompt_yes_no "Notify on OK results?" "$TELEGRAM_NOTIFY_ON_OK" TELEGRAM_NOTIFY_ON_OK
        fi

        prompt_timer_action
    fi
}

validate_final_config() {
    if [[ "${#HOSTS[@]}" -eq 0 ]]; then
        log_error "At least one --host value is required"
        exit 1
    fi

    if [[ "$ENABLE_BACKUP_HEALTH_TIMER" -eq 1 && "$DISABLE_BACKUP_HEALTH_TIMER" -eq 1 ]]; then
        log_error "--enable-backup-health-timer and --disable-backup-health-timer cannot be used together"
        exit 1
    fi

    if [[ -n "$SSH_PORT" ]]; then
        validate_positive_integer "--ssh-port" "$SSH_PORT"
    fi

    validate_zero_or_one "TELEGRAM_NOTIFY_ON_OK" "$TELEGRAM_NOTIFY_ON_OK"

    if [[ -n "$TELEGRAM_CHAT_ID" ]]; then
        validate_signed_integer "--telegram-chat-id" "$TELEGRAM_CHAT_ID"
    fi

    if [[ -n "$TELEGRAM_THREAD_ID" ]]; then
        validate_positive_integer "--telegram-thread-id" "$TELEGRAM_THREAD_ID"
    fi

    if [[ -n "$TELEGRAM_BOT_TOKEN" || -n "$TELEGRAM_CHAT_ID" || -n "$TELEGRAM_THREAD_ID" ]]; then
        if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
            log_error "Telegram config requires both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
            exit 1
        fi
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                validate_nonempty_value "--host" "${2:-}"
                HOSTS+=("${2}")
                shift 2
                ;;
            --interactive)
                INTERACTIVE=1
                shift
                ;;
            --script-dir)
                SCRIPT_DIR="${2:-}"
                validate_nonempty_value "--script-dir" "$SCRIPT_DIR"
                shift 2
                ;;
            --systemd-dir)
                SYSTEMD_DIR="${2:-}"
                validate_nonempty_value "--systemd-dir" "$SYSTEMD_DIR"
                shift 2
                ;;
            --config-file)
                CONFIG_FILE="${2:-}"
                validate_nonempty_value "--config-file" "$CONFIG_FILE"
                shift 2
                ;;
            --backup-health-check-args)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing value for --backup-health-check-args"
                    exit 1
                fi
                BACKUP_HEALTH_CHECK_ARGS="${2}"
                if [[ -z "$BACKUP_HEALTH_CHECK_ARGS" ]]; then
                    log_error "Empty value for --backup-health-check-args"
                    exit 1
                fi
                shift 2
                ;;
            --telegram-bot-token)
                TELEGRAM_BOT_TOKEN="${2:-}"
                validate_nonempty_value "--telegram-bot-token" "$TELEGRAM_BOT_TOKEN"
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
            --telegram-no-ok)
                TELEGRAM_NOTIFY_ON_OK=0
                shift
                ;;
            --ssh-port)
                SSH_PORT="${2:-}"
                validate_positive_integer "--ssh-port" "$SSH_PORT"
                shift 2
                ;;
            --ssh-key)
                SSH_KEY="${2:-}"
                validate_nonempty_value "--ssh-key" "$SSH_KEY"
                shift 2
                ;;
            --ssh-bin)
                SSH_BIN="${2:-}"
                validate_nonempty_value "--ssh-bin" "$SSH_BIN"
                shift 2
                ;;
            --scp-bin)
                SCP_BIN="${2:-}"
                validate_nonempty_value "--scp-bin" "$SCP_BIN"
                shift 2
                ;;
            --ssh-option)
                validate_nonempty_value "--ssh-option" "${2:-}"
                SSH_OPTIONS+=("${2}")
                shift 2
                ;;
            --skip-backup-health-systemd)
                DEPLOY_BACKUP_HEALTH_SYSTEMD=0
                shift
                ;;
            --overwrite-config)
                OVERWRITE_CONFIG=1
                shift
                ;;
            --enable-backup-health-timer)
                ENABLE_BACKUP_HEALTH_TIMER=1
                shift
                ;;
            --disable-backup-health-timer)
                DISABLE_BACKUP_HEALTH_TIMER=1
                shift
                ;;
            --no-backup)
                BACKUP_EXISTING=0
                shift
                ;;
            --dry-run)
                DRY_RUN=1
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
}

check_local_dependencies() {
    local missing=0
    local required_commands=("$SSH_BIN" "$SCP_BIN" mktemp)
    local cmd

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

check_local_files() {
    local file
    local required_files=(
        "$REPO_DIR/update-lxc.sh"
        "$REPO_DIR/update-lxc-safe.sh"
        "$REPO_DIR/backup-health-check.sh"
        "$REPO_DIR/systemd/proxmox-backup-health-check.service"
        "$REPO_DIR/systemd/proxmox-backup-health-check.timer"
    )

    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Required repository file not found: $file"
            exit 1
        fi
    done
}

setup_runtime() {
    TMP_DIR="$(mktemp -d "/tmp/${SCRIPT_NAME}.XXXXXX")" || {
        log_error "Failed to create temporary directory"
        exit 1
    }
    CONFIG_TEMPLATE_FILE="$TMP_DIR/proxmox-backup-health-check.env"
}

cleanup_runtime() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
        TMP_DIR=""
    fi
}

build_ssh_tools() {
    SSH_BASE=("$SSH_BIN")
    SCP_BASE=("$SCP_BIN")

    if [[ -n "$SSH_PORT" ]]; then
        SSH_BASE+=(-p "$SSH_PORT")
        SCP_BASE+=(-P "$SSH_PORT")
    fi

    if [[ -n "$SSH_KEY" ]]; then
        SSH_BASE+=(-i "$SSH_KEY")
        SCP_BASE+=(-i "$SSH_KEY")
    fi

    if [[ "${#SSH_OPTIONS[@]}" -gt 0 ]]; then
        local option
        for option in "${SSH_OPTIONS[@]}"; do
            SSH_BASE+=(-o "$option")
            SCP_BASE+=(-o "$option")
        done
    fi
}

print_command() {
    printf '%q ' "$@"
    printf '\n'
}

run_remote() {
    local host="$1"
    local command="$2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[DRY-RUN] ' >&2
        print_command "${SSH_BASE[@]}" "$host" "$command" >&2
        return 0
    fi

    "${SSH_BASE[@]}" "$host" "$command"
}

copy_to_remote() {
    local local_path="$1"
    local host="$2"
    local remote_path="$3"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[DRY-RUN] ' >&2
        print_command "${SCP_BASE[@]}" "$local_path" "${host}:${remote_path}" >&2
        return 0
    fi

    "${SCP_BASE[@]}" "$local_path" "${host}:${remote_path}"
}

remote_file_exists() {
    local host="$1"
    local remote_path="$2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 1
    fi

    "${SSH_BASE[@]}" "$host" "test -f \"$remote_path\""
}

backup_remote_file() {
    local host="$1"
    local remote_path="$2"

    if [[ "$BACKUP_EXISTING" -eq 0 ]]; then
        return 0
    fi

    run_remote "$host" "if [ -f \"$remote_path\" ]; then cp \"$remote_path\" \"$remote_path.bak.$RUN_ID\"; fi"
}

write_config_template() {
    cat > "$CONFIG_TEMPLATE_FILE" <<EOF
SCRIPT_PATH="${SCRIPT_DIR}/backup_health_check.sh"
LOG_FILE="/var/log/pve-backup-health-check.log"
BACKUP_HEALTH_CHECK_ARGS="${BACKUP_HEALTH_CHECK_ARGS}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
TELEGRAM_THREAD_ID="${TELEGRAM_THREAD_ID}"
TELEGRAM_NOTIFY_ON_OK=${TELEGRAM_NOTIFY_ON_OK}
TELEGRAM_TIMEOUT=15
EOF
}

validate_remote_scripts() {
    local host="$1"
    local remote_update_lxc="$SCRIPT_DIR/update_lxc.sh"
    local remote_update_lxc_safe="$SCRIPT_DIR/update_lxc_safe.sh"
    local remote_backup_health="$SCRIPT_DIR/backup_health_check.sh"

    run_remote "$host" "chmod +x \"$remote_update_lxc\" \"$remote_update_lxc_safe\" \"$remote_backup_health\""
    run_remote "$host" "bash -n \"$remote_update_lxc\" && bash -n \"$remote_update_lxc_safe\" && bash -n \"$remote_backup_health\""
}

handle_backup_health_systemd() {
    local host="$1"
    local remote_service="$SYSTEMD_DIR/proxmox-backup-health-check.service"
    local remote_timer="$SYSTEMD_DIR/proxmox-backup-health-check.timer"
    local config_dir

    config_dir="$(dirname "$CONFIG_FILE")"

    run_remote "$host" "mkdir -p \"$SYSTEMD_DIR\" \"$config_dir\""

    backup_remote_file "$host" "$remote_service"
    backup_remote_file "$host" "$remote_timer"

    copy_to_remote "$REPO_DIR/systemd/proxmox-backup-health-check.service" "$host" "$remote_service"
    copy_to_remote "$REPO_DIR/systemd/proxmox-backup-health-check.timer" "$host" "$remote_timer"

    if [[ "$OVERWRITE_CONFIG" -eq 1 ]]; then
        backup_remote_file "$host" "$CONFIG_FILE"
        copy_to_remote "$CONFIG_TEMPLATE_FILE" "$host" "$CONFIG_FILE"
        log_info "Replaced backup-health-check config on $host: $CONFIG_FILE"
    elif remote_file_exists "$host" "$CONFIG_FILE"; then
        log_info "Preserving existing backup-health-check config on $host: $CONFIG_FILE"
    else
        copy_to_remote "$CONFIG_TEMPLATE_FILE" "$host" "$CONFIG_FILE"
        log_info "Installed backup-health-check config on $host: $CONFIG_FILE"
    fi

    run_remote "$host" "systemd-analyze verify \"$remote_service\" \"$remote_timer\""
    run_remote "$host" "systemctl daemon-reload"

    if [[ "$ENABLE_BACKUP_HEALTH_TIMER" -eq 1 ]]; then
        run_remote "$host" "systemctl enable --now proxmox-backup-health-check.timer"
    elif [[ "$DISABLE_BACKUP_HEALTH_TIMER" -eq 1 ]]; then
        run_remote "$host" "systemctl disable --now proxmox-backup-health-check.timer"
    fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        local timer_enabled
        local timer_active

        timer_enabled="$("${SSH_BASE[@]}" "$host" "systemctl is-enabled proxmox-backup-health-check.timer 2>&1 || true")"
        timer_active="$("${SSH_BASE[@]}" "$host" "systemctl is-active proxmox-backup-health-check.timer 2>&1 || true")"
        log_info "Timer state on $host: enabled=${timer_enabled}, active=${timer_active}"
    fi
}

deploy_host() {
    local host="$1"
    local remote_update_lxc="$SCRIPT_DIR/update_lxc.sh"
    local remote_update_lxc_safe="$SCRIPT_DIR/update_lxc_safe.sh"
    local remote_backup_health="$SCRIPT_DIR/backup_health_check.sh"

    log_info "----------------------------------------"
    log_info "Deploying to $host"

    run_remote "$host" "mkdir -p \"$SCRIPT_DIR\""

    backup_remote_file "$host" "$remote_update_lxc"
    backup_remote_file "$host" "$remote_update_lxc_safe"
    backup_remote_file "$host" "$remote_backup_health"

    copy_to_remote "$REPO_DIR/update-lxc.sh" "$host" "$remote_update_lxc"
    copy_to_remote "$REPO_DIR/update-lxc-safe.sh" "$host" "$remote_update_lxc_safe"
    copy_to_remote "$REPO_DIR/backup-health-check.sh" "$host" "$remote_backup_health"

    validate_remote_scripts "$host"

    if [[ "$DEPLOY_BACKUP_HEALTH_SYSTEMD" -eq 1 ]]; then
        handle_backup_health_systemd "$host"
    else
        log_info "Skipping backup-health-check systemd deployment for $host"
    fi

    log_success "Deployment completed for $host"
}

main() {
    local host

    parse_args "$@"
    if [[ "$INTERACTIVE" -eq 1 ]]; then
        run_interactive_setup
    fi
    validate_final_config
    check_local_dependencies
    check_local_files
    setup_runtime
    trap 'cleanup_runtime' EXIT
    build_ssh_tools
    write_config_template

    log_info "Starting Proxmox maintenance deployment"
    log_info "Hosts: ${HOSTS[*]}"
    log_info "Remote script directory: $SCRIPT_DIR"
    log_info "Remote systemd directory: $SYSTEMD_DIR"
    log_info "Remote config file: $CONFIG_FILE"
    log_info "Generated BACKUP_HEALTH_CHECK_ARGS: ${BACKUP_HEALTH_CHECK_ARGS:-<empty>}"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        log_info "Generated Telegram config: enabled"
    else
        log_info "Generated Telegram config: disabled"
    fi
    log_info "Backup existing files: $BACKUP_EXISTING"
    log_info "Deploy backup-health-check systemd: $DEPLOY_BACKUP_HEALTH_SYSTEMD"
    log_info "Dry-run mode: $DRY_RUN"

    for host in "${HOSTS[@]}"; do
        deploy_host "$host"
    done

    log_info "Deployment run completed"
}

main "$@"
