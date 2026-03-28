# Proxmox LXC Update

[![Release](https://img.shields.io/github/v/release/didimozg/proxmox-lxc-update?display_name=tag)](https://github.com/didimozg/proxmox-lxc-update/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/didimozg/proxmox-lxc-update/ci.yml?branch=main&label=CI)](https://github.com/didimozg/proxmox-lxc-update/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/didimozg/proxmox-lxc-update)](./LICENSE)

This repository currently includes two host-side Bash scripts for Proxmox LXC maintenance:

- `update-lxc.sh`: update running containers directly from the Proxmox host
- `update-lxc-safe.sh`: create a pre-update snapshot, run `update-lxc.sh`, and optionally roll back on failure

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

## Installation

Clone the repository or copy the scripts to the Proxmox host:

```bash
chmod +x update-lxc.sh
chmod +x update-lxc-safe.sh
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
