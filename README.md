# Proxmox LXC Update

[![Release](https://img.shields.io/github/v/release/didimozg/proxmox-lxc-update?display_name=tag)](https://github.com/didimozg/proxmox-lxc-update/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/didimozg/proxmox-lxc-update/ci.yml?branch=main&label=CI)](https://github.com/didimozg/proxmox-lxc-update/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/didimozg/proxmox-lxc-update)](./LICENSE)

Russian documentation: [README_RU.md](./README_RU.md).

This repository currently includes three host-side maintenance scripts for Proxmox:

- `update-lxc.sh`: update running containers directly from the Proxmox host
- `update-lxc-safe.sh`: create a pre-update snapshot, run `update-lxc.sh`, and optionally roll back on failure
- `backup-health-check.sh`: audit vzdump backup jobs, recent backup task health, backup coverage across the cluster, and optional Telegram notifications

`update-lxc.sh` is the main updater for running Proxmox LXC containers executed directly from the Proxmox host with `pct exec`.

It is designed for practical day-to-day administration:

- update all running containers or only a selected subset
- exclude specific container IDs
- preview actions with `--dry-run`
- run serially or in parallel
- enforce a per-container timeout
- detect the guest package manager automatically
- keep a readable host-side log and final summary
- make Debian/Ubuntu updates more resilient with `ForceIPv4` and retries

## Supported Guest Package Managers

- `apt-get` for Debian and Ubuntu
- `dnf` / `yum` for Fedora, CentOS, Rocky Linux, and AlmaLinux
- `apk` for Alpine
- `pacman` for Arch Linux

If `ostype` is missing or not useful, the script falls back to package manager detection inside the container.

## Requirements

- Proxmox VE host
- `root` privileges
- `bash`
- `pct`
- `timeout`
- `awk`
- `grep`
- `mktemp` when `--parallel` is greater than `1`
- `curl` when Telegram notifications are enabled for `backup-health-check.sh`

## Installation

Clone the repository or copy the scripts to the Proxmox host:

```bash
chmod +x backup-health-check.sh
chmod +x update-lxc.sh
chmod +x update-lxc-safe.sh
sudo ./backup-health-check.sh --help
sudo ./update-lxc.sh --help
sudo ./update-lxc-safe.sh --help
```

## Quick Start

Update all running containers:

```bash
./update-lxc.sh
```

Preview what would run without making changes:

```bash
./update-lxc.sh --dry-run
```

Update only selected containers:

```bash
./update-lxc.sh --ct 101,102,103
```

Exclude specific containers:

```bash
./update-lxc.sh --exclude 104,105
```

Run multiple updates at once:

```bash
./update-lxc.sh --parallel 3
```

Use `dist-upgrade` for Debian/Ubuntu guests:

```bash
./update-lxc.sh --apt-mode dist-upgrade
```

Write logs to a custom location:

```bash
./update-lxc.sh --log-file /root/pve-lxc-update.log
```

## Safe Update Script

`update-lxc-safe.sh` is a serial safety wrapper around `update-lxc.sh`.

For each selected running container it:

1. creates a Proxmox snapshot
2. runs `update-lxc.sh` only for that container
3. optionally rolls the container back when the update fails
4. optionally starts the container again after rollback
5. removes the snapshot after a successful update unless told to keep it

### Quick Start

Run a safe update for all running containers:

```bash
./update-lxc-safe.sh
```

Preview snapshots, update commands, and rollback actions:

```bash
./update-lxc-safe.sh --dry-run
```

Update only selected containers and keep successful snapshots:

```bash
./update-lxc-safe.sh --ct 101,102 --keep-snapshot
```

Use a custom snapshot name:

```bash
./update-lxc-safe.sh --snapshot-name before-maintenance
```

Disable automatic rollback:

```bash
./update-lxc-safe.sh --no-rollback
```

### Safe Script Options

```text
--dry-run
--ct 101,102,103
--exclude 104,105
--log-file PATH
--no-color
--timeout SECONDS
--apt-mode upgrade|dist-upgrade
--update-script PATH
--snapshot-prefix PREFIX
--snapshot-name NAME
--keep-snapshot
--no-rollback
--no-start-after-rollback
-h, --help
```

### Safe Script Notes

- `update-lxc-safe.sh` intentionally runs containers one by one.
- The same snapshot name is used for all selected containers in a single run; snapshots remain per-container on the Proxmox side.
- By default, snapshots are deleted after a successful update and kept after a failed update.
- By default, the script attempts rollback on update failure.
- After rollback, the script starts the container again unless `--no-start-after-rollback` is used.
- Manual interruption does not trigger an automatic rollback workflow; handle interrupted containers deliberately.
- Snapshot creation still depends on the underlying Proxmox storage supporting container snapshots.

## Backup Health Check Script

`backup-health-check.sh` is a read-only cluster health report for Proxmox backup jobs and recent `vzdump` task history.

It is designed to answer a few practical questions quickly:

- are there any enabled backup jobs at all
- when did each node last complete a successful `vzdump`
- are there recent warning or failed backup tasks
- are there guests not covered by current backup jobs
- are any nodes overdue based on configurable freshness thresholds

### Quick Start

Run a cluster-wide health check:

```bash
./backup-health-check.sh
```

Check only one node:

```bash
./backup-health-check.sh --node minipveone
```

Use stricter thresholds:

```bash
./backup-health-check.sh --warn-age-hours 48 --crit-age-hours 96
```

Write the report to a custom log file:

```bash
./backup-health-check.sh --log-file /root/pve-backup-health-check.log
```

Run the health check and notify Telegram:

```bash
TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... ./backup-health-check.sh --telegram-no-ok
```

### Backup Health Check Options

```text
--node pve,minipveone
--warn-age-hours HOURS
--crit-age-hours HOURS
--recent-problem-hours HOURS
--task-limit N
--problem-limit N
--log-file PATH
--telegram-bot-token TOKEN
--telegram-chat-id ID
--telegram-thread-id ID
--telegram-timeout SECONDS
--telegram-no-ok
--no-color
-h, --help
```

### Backup Health Check Notes

- The script is read-only and does not start, stop, or modify guests.
- It uses cluster API data from `pvesh`, so it should be run as `root` on a Proxmox node.
- Default thresholds are intentionally weekly-friendly:
  `warn=192h`, `crit=336h`, `recent-problem-window=336h`.
- A node can still be reported as healthy even if older historical backup failures exist, as long as they are outside the recent problem window.
- Guests returned by `/cluster/backup-info/not-backed-up` are reported separately so you can catch coverage gaps.
- The script currently focuses on `vzdump` job health and coverage, not on detailed PBS datastore verification.
- Telegram delivery is optional and is activated when both `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are provided.
- In production, prefer an external environment file over passing the Telegram token on the command line.
- If Telegram is enabled and the report is too long, the message is truncated while the full report remains in the log file.
- The Telegram sender automatically retries over IPv4 when the default network path fails, which helps on hosts with broken IPv6 egress.

### Scheduled Execution With systemd

The repository includes ready-to-use files in [systemd](./systemd):

- `proxmox-backup-health-check.service`
- `proxmox-backup-health-check.timer`
- `proxmox-backup-health-check.env.example`

Suggested deployment flow on a Proxmox node:

```bash
install -m 0755 backup-health-check.sh /usr/local/sbin/backup-health-check.sh
install -m 0644 systemd/proxmox-backup-health-check.service /etc/systemd/system/proxmox-backup-health-check.service
install -m 0644 systemd/proxmox-backup-health-check.timer /etc/systemd/system/proxmox-backup-health-check.timer
install -m 0644 systemd/proxmox-backup-health-check.env.example /etc/default/proxmox-backup-health-check
systemctl daemon-reload
systemctl enable --now proxmox-backup-health-check.timer
```

Example `/etc/default/proxmox-backup-health-check`:

```bash
SCRIPT_PATH=/media/script/backup_health_check.sh
LOG_FILE=/var/log/pve-backup-health-check.log
BACKUP_HEALTH_CHECK_ARGS=
TELEGRAM_BOT_TOKEN=123456:replace-me
TELEGRAM_CHAT_ID=123456789
TELEGRAM_THREAD_ID=
TELEGRAM_NOTIFY_ON_OK=1
TELEGRAM_TIMEOUT=15
```

Notes:

- `BACKUP_HEALTH_CHECK_ARGS` is split on spaces, so keep it simple.
- The service adds `--no-color` automatically for clean logs and Telegram messages.
- The target Telegram user must start the bot first, otherwise Telegram will reject the message.

## Options

```text
--dry-run
--ct 101,102,103
--exclude 104,105
--log-file PATH
--no-color
--parallel N
--timeout SECONDS
--apt-mode upgrade|dist-upgrade
-h, --help
```

## How It Works

1. Reads the list of running LXC containers from `pct list`.
2. Applies `--ct` and `--exclude` filters.
3. Re-checks the container state before running updates.
4. Skips containers with an active Proxmox `lock`.
5. Builds the correct package manager command for the guest OS.
6. Runs updates inside the container with `pct exec`.
7. Collects success, skip, timeout, and failure results.
8. Prints a final summary and writes a persistent log.

## Logging

By default, the log is written to:

```text
/var/log/pve-lxc-update.log
```

The safe wrapper uses its own log by default:

```text
/var/log/pve-lxc-safe-update.log
```

The backup health check uses:

```text
/var/log/pve-backup-health-check.log
```

The log includes:

- run start and finish
- selected containers
- per-container execution blocks
- `dry-run` command output
- failures and timeouts

When `--parallel` is used, each worker writes to a temporary per-container log first, and the script merges those logs into the main file when jobs finish. That means log blocks may be ordered by completion time instead of launch order.

## Debian And Ubuntu Behavior

For `apt-get`, the script uses:

- `DEBIAN_FRONTEND=noninteractive`
- `Dpkg::Options::=--force-confdef`
- `Dpkg::Options::=--force-confold`
- `Acquire::ForceIPv4=true`
- `Acquire::Retries=3`

This helps reduce interactive prompts and transient repository failures on hosts or containers without working IPv6 connectivity.

## Exit Behavior

- exits with `0` when all processed containers complete successfully
- exits with `1` when at least one container fails
- exits with `130` when interrupted by `INT` or `TERM`

## Notes And Limitations

- The script updates only containers in the `running` state.
- Containers with an active `lock` are skipped.
- `--parallel` must be at least `1`.
- Starting with `--parallel 2` or `--parallel 3` is usually safer than going wide immediately.
- If the same ID is present in both `--ct` and `--exclude`, `--exclude` takes precedence.
- This script intentionally does not start stopped containers.
- Some packages may still be kept back by `apt-get upgrade`; use `--apt-mode dist-upgrade` if that matches your maintenance policy.

## License

MIT. See [LICENSE](LICENSE).
