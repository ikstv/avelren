# PostgreSQL backup / резервне копіювання PostgreSQL

## Українська

Workflow використовує окремий Google-акаунт для backup, rclone OAuth і зашифрований Restic repository `rclone:<private-remote>:Avelren Backups/restic`. Назва remote, rclone config і Restic password зберігаються лише в root-only environment/config paths. Google password, app password, OAuth token, email і credentials не додаються до Git.

Restic отримує повний repository URL з backend prefix `rclone:`, а прямі команди rclone отримують той самий remote/path без цього prefix: `<private-remote>:Avelren Backups/restic`.

Створіть окремий Google-акаунт з мінімальним доступом, налаштуйте OAuth rclone на контрольованій машині та перенесіть `rclone.conf` захищеним каналом. Не вставляйте OAuth token у чат, shell history або логи. На сервері `/etc/avelren/backup` має бути `root:root 0700`; `backup.env` і `rclone.conf` — `root:root 0600`, а Restic password — `root:root 0400`. Mode `0600` для password-файла підтримується лише для зворотної сумісності.

### Встановлення та безпечна заміна

Усі файли встановлює root. Джерела `scripts/backup/postgres-tcp-dump.sh`, `postgres-backup-control.sh`, `restic-password-file.sh` і `restic-repository.sh` мають відповідати destination-файлам з тими самими назвами в `/usr/local/libexec/`; owner/group — `root:root`, mode — `0755`. Потім `scripts/backup/postgres-backup.sh` встановлюється як `/usr/local/libexec/avelren-postgres-backup` (`root:root 0755`). Команди для init, repository check, prune і restore drill відповідно встановлюються як `/usr/local/libexec/avelren-postgres-backup-init`, `/usr/local/libexec/avelren-postgres-backup-repo-check`, `/usr/local/libexec/avelren-postgres-backup-prune` і `/usr/local/libexec/avelren-postgres-restore-drill` (`root:root 0755`).

Перед новим встановленням timer має залишатися disabled; перед upgrade його треба зупинити. Кожний script спочатку копіюється через `install -o root -g root -m 0755` у прихований temporary-файл у `/usr/local/libexec/`, а потім замінюється `mv -T` у межах тієї самої filesystem. Порядок replacement: спочатку `postgres-tcp-dump.sh`, `postgres-backup-control.sh` і два `restic-*.sh`; потім чотири допоміжні команди; основний `avelren-postgres-backup` — останнім. Це не залишає новий main script зі старим helper. Не запускайте backup між кроками.

Нижче `release_root` — абсолютний шлях до перевіреного checkout одного release. Команди виконуються послідовно з `set -eu`:

```bash
release_root=/absolute/path/to/avelren
for timer in avelren-postgres-backup.timer avelren-postgres-repo-check.timer; do
  if [ -e "/etc/systemd/system/$timer" ]; then systemctl stop "$timer"; fi
done
install -o root -g root -m 0755 "$release_root/scripts/backup/postgres-tcp-dump.sh" /usr/local/libexec/.postgres-tcp-dump.sh.new
mv -T /usr/local/libexec/.postgres-tcp-dump.sh.new /usr/local/libexec/postgres-tcp-dump.sh
install -o root -g root -m 0755 "$release_root/scripts/backup/postgres-backup-control.sh" /usr/local/libexec/.postgres-backup-control.sh.new
mv -T /usr/local/libexec/.postgres-backup-control.sh.new /usr/local/libexec/postgres-backup-control.sh
for name in restic-password-file restic-repository; do
  install -o root -g root -m 0755 "$release_root/scripts/backup/$name.sh" "/usr/local/libexec/.$name.sh.new"
  mv -T "/usr/local/libexec/.$name.sh.new" "/usr/local/libexec/$name.sh"
done
for mapping in \
  'postgres-backup-init.sh:avelren-postgres-backup-init' \
  'postgres-backup-repo-check.sh:avelren-postgres-backup-repo-check' \
  'postgres-backup-prune.sh:avelren-postgres-backup-prune' \
  'postgres-restore-drill.sh:avelren-postgres-restore-drill'; do
  source_name="${mapping%%:*}"; destination_name="${mapping#*:}"
  install -o root -g root -m 0755 "$release_root/scripts/backup/$source_name" "/usr/local/libexec/.$destination_name.new"
  mv -T "/usr/local/libexec/.$destination_name.new" "/usr/local/libexec/$destination_name"
done
install -o root -g root -m 0755 "$release_root/scripts/backup/postgres-backup.sh" /usr/local/libexec/.avelren-postgres-backup.new
mv -T /usr/local/libexec/.avelren-postgres-backup.new /usr/local/libexec/avelren-postgres-backup
```

Лише після scripts так само безпечно встановіть `deploy/systemd/avelren-postgres-backup.service`, `avelren-postgres-backup.timer`, `avelren-postgres-repo-check.service` і `avelren-postgres-repo-check.timer` як однойменні `/etc/systemd/system/*` (`root:root 0644`), потім виконайте `systemctl daemon-reload`. `backup.env` створюється з приватного `deploy/systemd/avelren-backup.env.example` як `/etc/avelren/backup/backup.env` (`root:root 0600`); він не замінюється з Git поверх реальних credentials.

```bash
for unit in avelren-postgres-backup.service avelren-postgres-backup.timer avelren-postgres-repo-check.service avelren-postgres-repo-check.timer; do
  install -o root -g root -m 0644 "$release_root/deploy/systemd/$unit" "/etc/systemd/system/.$unit.new"
  mv -T "/etc/systemd/system/.$unit.new" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
```

До enable/start timer виконайте `bash -n /usr/local/libexec/{postgres-tcp-dump.sh,postgres-backup-control.sh,restic-password-file.sh,restic-repository.sh,avelren-postgres-backup,avelren-postgres-backup-init,avelren-postgres-backup-repo-check,avelren-postgres-backup-prune,avelren-postgres-restore-drill}`, перевірте owner/mode через `stat -c '%U:%G %a %n'`, перевірте кожний deployed script через `cmp -s <release-source> <destination>`, а units — через `systemd-analyze verify`. Також виконайте `docker compose --env-file /opt/avelren/.env.production --file /opt/avelren/docker-compose.yml config --quiet` і явний `avelren-postgres-backup-repo-check`. Timer заборонено enable/start, якщо helper відсутній, не executable, не збігається з source того самого release або будь-яка перевірка не пройшла. Repository не ініціалізується автоматично: `avelren-postgres-backup-init` виконується окремо лише для нового repository.

Після успішних перевірок timer можна ввімкнути через `systemctl enable --now avelren-postgres-backup.timer avelren-postgres-repo-check.timer` і перевірити через `systemctl status` та `systemctl list-timers`. Rollback починається зі stop/disable обох timer-ів. Атомарно поверніть попередній `avelren-postgres-backup` першим, потім сумісні з ним helper/support scripts, після цього попередні units; виконайте `daemon-reload` і повторіть усі validation-команди. Timer не вмикається, доки повний попередній комплект не відновлено й не перевірено.

Щоденний backup перевіряє healthy PostgreSQL і підключається до `127.0.0.1:5432` усередині PostgreSQL-контейнера через SCRAM. Пароль читається лише з mounted `postgres_password` secret у випадковий temporary `PGPASSFILE` з mode `0600`; він не передається через arguments або environment. Порожній secret або secret із newline відхиляється. Main script запускає helper через detached `docker exec`, відстежує лише його operation ID, PID і process start time та при SIGINT/SIGTERM виконує scoped TERM→KILL із reap children. Heartbeat watchdog видаляє credential і незавершений dump, якщо host controller зникає. SIGINT повертає `130`, SIGTERM — `143`; для oneshot systemd це коректний cancelled/failed result, а не успішний backup. Backup бере custom-format `pg_dump` з `--no-owner --no-acl`, перевіряє `pg_restore --list`, шифрує dump Restic через rclone і видаляє лише власний root-only temporary directory. `flock` забороняє паралельні запуски. Prune не запускається під час backup: окрема ручна команда зберігає 7 daily, 4 weekly і 3 monthly. При 12 GiB є warning, при 14 GiB нові backup зупиняються без видалення snapshot.

Restore drill створює випадкову БД з префіксом `avelren_restore_`, ніколи не використовує production database `avelren`, відновлює останній snapshot, перевіряє migrations `001–003` і основні таблиці. При невизначеній помилці тимчасова БД і файли зберігаються; видаляються лише після повністю успішної перевірки.

Перевіряйте timer-и через `systemctl list-timers`, `systemctl status avelren-postgres-backup.timer` і weekly repository check. Для credential rotation зупиніть timer, замініть OAuth config/password root-only способом, виконайте repository check і ручний backup, потім увімкніть timer. Після втрати сервера відновіть packages, rclone OAuth config і Restic password з secure escrow, виконайте `restic check`, restore drill і лише потім recovery production.

## English

The workflow uses a dedicated Google backup account, rclone OAuth, and an encrypted Restic repository at `rclone:<private-remote>:Avelren Backups/restic`. The remote name, rclone config, and Restic password remain in root-only private environment/config paths. Google passwords, app passwords, OAuth tokens, email addresses, and credentials are never committed.

Restic receives the full repository URL with the `rclone:` backend prefix, while direct rclone commands receive the same remote/path without that prefix: `<private-remote>:Avelren Backups/restic`.

Create the dedicated account with least privilege, complete rclone OAuth on a controlled machine, and transfer `rclone.conf` through a protected channel. Never paste an OAuth token into chat, shell history, or logs. On the server, `/etc/avelren/backup` is `root:root 0700`; `backup.env` and `rclone.conf` are `root:root 0600`, while the Restic password is `root:root 0400`. Password-file mode `0600` remains accepted only for backward compatibility.

### Installation and safe replacement

Root installs every file. Sources `scripts/backup/postgres-tcp-dump.sh`, `postgres-backup-control.sh`, `restic-password-file.sh`, and `restic-repository.sh` map to same-named destinations in `/usr/local/libexec/`, owned by `root:root` with mode `0755`. Then install `scripts/backup/postgres-backup.sh` as `/usr/local/libexec/avelren-postgres-backup` (`root:root 0755`). Install init, repository check, prune, and restore drill as `/usr/local/libexec/avelren-postgres-backup-init`, `/usr/local/libexec/avelren-postgres-backup-repo-check`, `/usr/local/libexec/avelren-postgres-backup-prune`, and `/usr/local/libexec/avelren-postgres-restore-drill` (`root:root 0755`).

Keep the timer disabled for a new installation; stop it before an upgrade. Copy each script with `install -o root -g root -m 0755` to a hidden temporary file in `/usr/local/libexec/`, then replace it using `mv -T` on that same filesystem. Replace `postgres-tcp-dump.sh`, `postgres-backup-control.sh`, and both `restic-*.sh` first; replace the four auxiliary commands next; replace the main `avelren-postgres-backup` last. This prevents a new main script from running with an old helper. Do not run a backup between these steps.

In the following commands, `release_root` is the absolute path to one verified release checkout. Run the commands sequentially under `set -eu`:

```bash
release_root=/absolute/path/to/avelren
for timer in avelren-postgres-backup.timer avelren-postgres-repo-check.timer; do
  if [ -e "/etc/systemd/system/$timer" ]; then systemctl stop "$timer"; fi
done
install -o root -g root -m 0755 "$release_root/scripts/backup/postgres-tcp-dump.sh" /usr/local/libexec/.postgres-tcp-dump.sh.new
mv -T /usr/local/libexec/.postgres-tcp-dump.sh.new /usr/local/libexec/postgres-tcp-dump.sh
install -o root -g root -m 0755 "$release_root/scripts/backup/postgres-backup-control.sh" /usr/local/libexec/.postgres-backup-control.sh.new
mv -T /usr/local/libexec/.postgres-backup-control.sh.new /usr/local/libexec/postgres-backup-control.sh
for name in restic-password-file restic-repository; do
  install -o root -g root -m 0755 "$release_root/scripts/backup/$name.sh" "/usr/local/libexec/.$name.sh.new"
  mv -T "/usr/local/libexec/.$name.sh.new" "/usr/local/libexec/$name.sh"
done
for mapping in \
  'postgres-backup-init.sh:avelren-postgres-backup-init' \
  'postgres-backup-repo-check.sh:avelren-postgres-backup-repo-check' \
  'postgres-backup-prune.sh:avelren-postgres-backup-prune' \
  'postgres-restore-drill.sh:avelren-postgres-restore-drill'; do
  source_name="${mapping%%:*}"; destination_name="${mapping#*:}"
  install -o root -g root -m 0755 "$release_root/scripts/backup/$source_name" "/usr/local/libexec/.$destination_name.new"
  mv -T "/usr/local/libexec/.$destination_name.new" "/usr/local/libexec/$destination_name"
done
install -o root -g root -m 0755 "$release_root/scripts/backup/postgres-backup.sh" /usr/local/libexec/.avelren-postgres-backup.new
mv -T /usr/local/libexec/.avelren-postgres-backup.new /usr/local/libexec/avelren-postgres-backup
```

Only after the scripts, safely install `deploy/systemd/avelren-postgres-backup.service`, `avelren-postgres-backup.timer`, `avelren-postgres-repo-check.service`, and `avelren-postgres-repo-check.timer` under the same names in `/etc/systemd/system/` (`root:root 0644`), then run `systemctl daemon-reload`. Create `/etc/avelren/backup/backup.env` from the private `deploy/systemd/avelren-backup.env.example` template as `root:root 0600`; never overwrite live credentials from Git.

```bash
for unit in avelren-postgres-backup.service avelren-postgres-backup.timer avelren-postgres-repo-check.service avelren-postgres-repo-check.timer; do
  install -o root -g root -m 0644 "$release_root/deploy/systemd/$unit" "/etc/systemd/system/.$unit.new"
  mv -T "/etc/systemd/system/.$unit.new" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
```

Before enabling or starting timers, run `bash -n /usr/local/libexec/{postgres-tcp-dump.sh,postgres-backup-control.sh,restic-password-file.sh,restic-repository.sh,avelren-postgres-backup,avelren-postgres-backup-init,avelren-postgres-backup-repo-check,avelren-postgres-backup-prune,avelren-postgres-restore-drill}`, inspect ownership/modes with `stat -c '%U:%G %a %n'`, compare every deployed script to the same release source with `cmp -s <release-source> <destination>`, and validate units with `systemd-analyze verify`. Also run `docker compose --env-file /opt/avelren/.env.production --file /opt/avelren/docker-compose.yml config --quiet` and the explicit `avelren-postgres-backup-repo-check`. Do not enable/start a timer when a helper is missing, non-executable, differs from the same release source, or any validation fails. Repository initialization is never automatic; run `avelren-postgres-backup-init` separately only for a new repository.

After successful validation, enable timers with `systemctl enable --now avelren-postgres-backup.timer avelren-postgres-repo-check.timer`, then inspect `systemctl status` and `systemctl list-timers`. For rollback, stop/disable both timers first. Atomically restore the previous `avelren-postgres-backup` first, then its matching helper/support scripts, and finally the previous units; run `daemon-reload` and repeat every validation command. Do not re-enable timers until the complete previous set is restored and verified.

The daily job checks PostgreSQL health and connects to `127.0.0.1:5432` inside the PostgreSQL container using SCRAM. The password is read only from the mounted `postgres_password` secret into a random temporary `PGPASSFILE` with mode `0600`; it is never passed through arguments or the environment. An empty secret or one containing a newline is rejected. The main script starts the helper with detached `docker exec`, tracks only its operation ID, PID, and process start time, and performs scoped TERM→KILL plus child reaping after SIGINT/SIGTERM. A heartbeat watchdog removes the credential and incomplete dump if the host controller disappears. SIGINT returns `130` and SIGTERM returns `143`; for the oneshot systemd unit this is a correct cancelled/failed result, never a successful backup. The job creates a custom-format dump with `--no-owner --no-acl`, validates it with `pg_restore --list`, encrypts it through Restic and rclone, and removes only its root-only temporary directory. `flock` prevents overlapping runs. Prune is a separate controlled operation with 7 daily, 4 weekly, and 3 monthly snapshots. A 12 GiB warning is emitted; new backups stop at 14 GiB without deleting existing snapshots.

The restore drill uses a random `avelren_restore_` database, never production database `avelren`, restores the latest snapshot, and verifies migrations `001–003` plus the main tables. An uncertain failure preserves the temporary database and files; cleanup occurs only after every verification succeeds.

Verify timers with `systemctl list-timers`, the daily backup timer, and the weekly repository check. For credential rotation, stop the timer, replace OAuth config/password through a root-only procedure, run repository check and a manual backup, then re-enable the timer. After server loss, recover packages, rclone OAuth config, and the Restic password from secure escrow, run `restic check`, perform a restore drill, and only then plan production recovery.
