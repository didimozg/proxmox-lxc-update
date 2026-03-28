# Proxmox LXC Update

[![Release](https://img.shields.io/github/v/release/didimozg/proxmox-lxc-update?display_name=tag)](https://github.com/didimozg/proxmox-lxc-update/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/didimozg/proxmox-lxc-update/ci.yml?branch=main&label=CI)](https://github.com/didimozg/proxmox-lxc-update/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/didimozg/proxmox-lxc-update)](./LICENSE)

English documentation: [README.md](./README.md).

Репозиторий содержит три host-side скрипта для повседневого обслуживания Proxmox:

- `update-lxc.sh` — обновление запущенных LXC-контейнеров с хоста Proxmox
- `update-lxc-safe.sh` — безопасное обновление через snapshot и автоматический rollback при ошибке
- `backup-health-check.sh` — проверка состояния `vzdump` backup job, свежести backup по нодам, покрытия гостей backup-задачами и опциональные Telegram-уведомления

## Поддерживаемые пакетные менеджеры в гостях

Для `update-lxc.sh` и `update-lxc-safe.sh` поддерживаются:

- `apt-get` для Debian и Ubuntu
- `dnf` / `yum` для Fedora, CentOS, Rocky Linux и AlmaLinux
- `apk` для Alpine
- `pacman` для Arch Linux

Если `ostype` у контейнера не задан или неинформативен, используется fallback-определение пакетного менеджера внутри контейнера.

## Требования

- Proxmox VE host
- запуск от `root`
- `bash`
- `pct`
- `pvesh` для `backup-health-check.sh`
- `python3` для `backup-health-check.sh`
- `timeout`, `awk`, `grep`
- `mktemp` для `update-lxc-safe.sh`, `backup-health-check.sh` и `update-lxc.sh` в parallel-режиме
- `curl` для `backup-health-check.sh`, если включены Telegram-уведомления

## Установка

Склонируйте репозиторий или скопируйте скрипты на Proxmox-ноду:

```bash
chmod +x backup-health-check.sh
chmod +x update-lxc.sh
chmod +x update-lxc-safe.sh

sudo ./backup-health-check.sh --help
sudo ./update-lxc.sh --help
sudo ./update-lxc-safe.sh --help
```

## Скрипт `update-lxc.sh`

Основной updater для LXC-контейнеров. Запускается на Proxmox host и выполняет обновление внутри гостя через `pct exec`.

### Что умеет

- обновлять все запущенные контейнеры или только выбранные
- исключать контейнеры по ID
- работать в `--dry-run`
- выполнять обновления последовательно или параллельно
- ограничивать время обновления для каждого контейнера
- вести читаемый лог и итоговую сводку
- делать `apt` более устойчивым на хостах/гостях без рабочего IPv6

### Быстрый старт

Обновить все запущенные контейнеры:

```bash
./update-lxc.sh
```

Показать, что будет выполнено, без реальных изменений:

```bash
./update-lxc.sh --dry-run
```

Обновить только выбранные контейнеры:

```bash
./update-lxc.sh --ct 101,102,103
```

Исключить контейнеры:

```bash
./update-lxc.sh --exclude 104,105
```

Запустить несколько обновлений параллельно:

```bash
./update-lxc.sh --parallel 3
```

Использовать `dist-upgrade` для Debian/Ubuntu:

```bash
./update-lxc.sh --apt-mode dist-upgrade
```

### Опции `update-lxc.sh`

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

## Скрипт `update-lxc-safe.sh`

Безопасная обёртка над `update-lxc.sh`.

Для каждого выбранного контейнера скрипт:

1. создаёт snapshot на стороне Proxmox
2. запускает `update-lxc.sh` только для этого контейнера
3. при ошибке пытается выполнить rollback
4. при необходимости снова запускает контейнер после rollback
5. удаляет snapshot после успешного обновления, если не задано иное

### Быстрый старт

Безопасно обновить все запущенные контейнеры:

```bash
./update-lxc-safe.sh
```

Проверить логику snapshot/update/rollback без изменений:

```bash
./update-lxc-safe.sh --dry-run
```

Обновить только выбранные контейнеры и сохранить успешные snapshot:

```bash
./update-lxc-safe.sh --ct 101,102 --keep-snapshot
```

Использовать свой snapshot name:

```bash
./update-lxc-safe.sh --snapshot-name before-maintenance
```

Отключить автоматический rollback:

```bash
./update-lxc-safe.sh --no-rollback
```

### Опции `update-lxc-safe.sh`

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

### Особенности `update-lxc-safe.sh`

- Скрипт намеренно работает последовательно, по одному контейнеру.
- Один запуск использует одно и то же имя snapshot для всех выбранных контейнеров, но snapshot создаются отдельно на стороне Proxmox для каждого `CT`.
- По умолчанию после успешного обновления snapshot удаляется.
- По умолчанию после неуспешного обновления snapshot сохраняется.
- По умолчанию при ошибке update выполняется rollback.
- После rollback контейнер запускается снова, если не задан `--no-start-after-rollback`.
- Прерывание скрипта вручную не запускает автоматическую процедуру rollback.
- Возможность snapshot зависит от используемого storage и поддержки snapshot для контейнеров.

## Скрипт `backup-health-check.sh`

Read-only health check для состояния backup в Proxmox-кластере.

Скрипт отвечает на практические вопросы:

- есть ли вообще активные `vzdump` backup job
- когда на каждой ноде в последний раз успешно завершался backup
- есть ли свежие backup-задачи со статусом `WARNINGS` или ошибками
- есть ли гости, не покрытые текущими backup-задачами
- не отстают ли backup по свежести относительно заданных порогов

### Быстрый старт

Проверить весь кластер:

```bash
./backup-health-check.sh
```

Проверить только одну ноду:

```bash
./backup-health-check.sh --node minipveone
```

Использовать более строгие пороги:

```bash
./backup-health-check.sh --warn-age-hours 48 --crit-age-hours 96
```

Писать отчёт в отдельный лог:

```bash
./backup-health-check.sh --log-file /root/pve-backup-health-check.log
```

Запускать проверку с отправкой результата в Telegram:

```bash
TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... ./backup-health-check.sh --telegram-no-ok
```

### Опции `backup-health-check.sh`

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

### Особенности `backup-health-check.sh`

- Скрипт только читает cluster API и ничего не меняет в Proxmox.
- Для работы использует `pvesh`, поэтому запускать его лучше от `root` на Proxmox-ноде.
- Пороговые значения по умолчанию подобраны под weekly-friendly сценарий:
  `warn=192h`, `crit=336h`, `recent-problem-window=336h`.
- Старые исторические ошибки не считаются активной проблемой, если они уже вышли за пределы окна `--recent-problem-hours`.
- Гости из `/cluster/backup-info/not-backed-up` выводятся отдельно, чтобы было видно дыры в покрытии backup.
- Скрипт ориентирован на состояние `vzdump` job и задач backup, а не на глубокую проверку целостности PBS datastore.
- Telegram-уведомления включаются, когда заданы и `TELEGRAM_BOT_TOKEN`, и `TELEGRAM_CHAT_ID`.
- Для production лучше задавать токен через внешний `env`-файл, а не через аргументы командной строки.
- Если отчёт слишком длинный для Telegram, сообщение будет сокращено, а полный текст останется в лог-файле.
- Отправка в Telegram автоматически повторяется через IPv4, если обычный сетевой путь не сработал, что полезно на хостах с проблемным IPv6.

### Плановый запуск через `systemd`

В репозитории уже лежат готовые файлы в каталоге [systemd](./systemd):

- `proxmox-backup-health-check.service`
- `proxmox-backup-health-check.timer`
- `proxmox-backup-health-check.env.example`

Пример развёртывания на Proxmox-ноде:

```bash
install -m 0755 backup-health-check.sh /usr/local/sbin/backup-health-check.sh
install -m 0644 systemd/proxmox-backup-health-check.service /etc/systemd/system/proxmox-backup-health-check.service
install -m 0644 systemd/proxmox-backup-health-check.timer /etc/systemd/system/proxmox-backup-health-check.timer
install -m 0644 systemd/proxmox-backup-health-check.env.example /etc/default/proxmox-backup-health-check
systemctl daemon-reload
systemctl enable --now proxmox-backup-health-check.timer
```

Пример `/etc/default/proxmox-backup-health-check`:

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

Замечания:

- `BACKUP_HEALTH_CHECK_ARGS` разбивается по пробелам, так что лучше оставлять его простым.
- Сервис сам добавляет `--no-color`, чтобы лог и Telegram-сообщения были чистыми.
- Перед первой отправкой пользователь должен написать боту, иначе Telegram отклонит сообщение.

## Как это работает

### `update-lxc.sh`

1. Читает список запущенных LXC через `pct list`
2. Применяет фильтры `--ct` и `--exclude`
3. Повторно проверяет состояние контейнера перед запуском update
4. Пропускает контейнеры с активным `lock`
5. Строит правильную команду обновления под ОС гостя
6. Выполняет update внутри контейнера через `pct exec`
7. Собирает результаты: success, skipped, timeout, failed
8. Пишет итоговую сводку и лог

### `update-lxc-safe.sh`

1. Берёт список целевых контейнеров
2. Создаёт snapshot
3. Запускает `update-lxc.sh` только для текущего контейнера
4. При ошибке выполняет rollback, если он не отключён
5. При успехе удаляет snapshot, если не задан `--keep-snapshot`

### `backup-health-check.sh`

1. Читает cluster backup job через `pvesh`
2. Получает список нод и cluster resources
3. Смотрит последние `vzdump` task по каждой ноде
4. Определяет свежесть последнего успешного backup
5. Отдельно выводит свежие warning/error backup task
6. Проверяет список гостей без backup coverage
7. Возвращает итоговый статус `OK`, `WARN` или `CRIT`

## Логирование

По умолчанию `update-lxc.sh` пишет лог сюда:

```text
/var/log/pve-lxc-update.log
```

`update-lxc-safe.sh` по умолчанию пишет сюда:

```text
/var/log/pve-lxc-safe-update.log
```

`backup-health-check.sh` по умолчанию пишет сюда:

```text
/var/log/pve-backup-health-check.log
```

Логи включают:

- время запуска и завершения
- выбранные контейнеры или ноды
- вывод по каждому контейнеру или backup-проверке
- dry-run детали
- ошибки, warning и итоговую сводку

## Поведение для Debian и Ubuntu

Для `apt-get` используется:

- `DEBIAN_FRONTEND=noninteractive`
- `Dpkg::Options::=--force-confdef`
- `Dpkg::Options::=--force-confold`
- `Acquire::ForceIPv4=true`
- `Acquire::Retries=3`

Это уменьшает вероятность зависаний на interactive prompt и помогает на узлах или контейнерах с нерабочим IPv6.

## Коды завершения

### `update-lxc.sh`

- `0` — все обработанные контейнеры обновлены успешно
- `1` — хотя бы один контейнер завершился с ошибкой
- `130` — выполнение прервано сигналом `INT` или `TERM`

### `update-lxc-safe.sh`

- `0` — все контейнеры отработали успешно
- `1` — хотя бы для одного контейнера update завершился с ошибкой
- `130` — выполнение прервано сигналом `INT` или `TERM`

### `backup-health-check.sh`

- `0` — всё хорошо
- `1` — есть warning
- `2` — есть critical findings

## Ограничения и замечания

- `update-lxc.sh` работает только с контейнерами в состоянии `running`.
- Контейнеры с активным `lock` пропускаются.
- `--parallel` должен быть не меньше `1`.
- Начинать с `--parallel 2` или `--parallel 3` обычно безопаснее, чем сразу запускать много параллельных update.
- Если один и тот же ID указан и в `--ct`, и в `--exclude`, приоритет у `--exclude`.
- Скрипты намеренно не запускают остановленные контейнеры ради обычного update.
- Для `apt-get upgrade` часть пакетов может оставаться `kept back`; если политика обслуживания это допускает, используй `--apt-mode dist-upgrade`.
- `backup-health-check.sh` не заменяет проверку самих backup-архивов на PBS и не выполняет verify datastore.

## Лицензия

MIT. См. [LICENSE](LICENSE).
