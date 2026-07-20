# PostgreSQL backup / резервне копіювання PostgreSQL

## Українська

Workflow використовує окремий Google-акаунт для backup, rclone OAuth і зашифрований Restic repository `rclone:<private-remote>:Avelren Backups/restic`. Назва remote, rclone config і Restic password зберігаються лише в root-only environment/config paths. Google password, app password, OAuth token, email і credentials не додаються до Git.

Restic отримує повний repository URL з backend prefix `rclone:`, а прямі команди rclone отримують той самий remote/path без цього prefix: `<private-remote>:Avelren Backups/restic`.

Створіть окремий Google-акаунт з мінімальним доступом, налаштуйте OAuth rclone на контрольованій машині та перенесіть `rclone.conf` захищеним каналом. Не вставляйте OAuth token у чат, shell history або логи. На сервері `/etc/avelren/backup` має бути `root:root 0700`; `backup.env` і `rclone.conf` — `root:root 0600`, а Restic password — `root:root 0400`. Mode `0600` для password-файла підтримується лише для зворотної сумісності.

Встановіть scripts як root у `/usr/local/libexec/`, units з `deploy/systemd/` у `/etc/systemd/system/`, а `backup.env` — з приватного шаблону `deploy/systemd/avelren-backup.env.example`. Перевірте доступність remote через `rclone lsd` та папки `Avelren Backups` через `rclone lsf`. Repository не ініціалізується автоматично: один раз виконайте явний `avelren-postgres-backup-init`, потім `avelren-postgres-backup-repo-check`.

Щоденний backup перевіряє healthy PostgreSQL, бере custom-format `pg_dump` з `--no-owner --no-acl`, перевіряє `pg_restore --list`, шифрує dump Restic через rclone і видаляє лише власний root-only temporary directory. `flock` забороняє паралельні запуски. Prune не запускається під час backup: окрема ручна команда зберігає 7 daily, 4 weekly і 3 monthly. При 12 GiB є warning, при 14 GiB нові backup зупиняються без видалення snapshot.

Restore drill створює випадкову БД з префіксом `avelren_restore_`, ніколи не використовує production database `avelren`, відновлює останній snapshot, перевіряє migrations `001–003` і основні таблиці. При невизначеній помилці тимчасова БД і файли зберігаються; видаляються лише після повністю успішної перевірки.

Перевіряйте timer-и через `systemctl list-timers`, `systemctl status avelren-postgres-backup.timer` і weekly repository check. Для credential rotation зупиніть timer, замініть OAuth config/password root-only способом, виконайте repository check і ручний backup, потім увімкніть timer. Після втрати сервера відновіть packages, rclone OAuth config і Restic password з secure escrow, виконайте `restic check`, restore drill і лише потім recovery production.

## English

The workflow uses a dedicated Google backup account, rclone OAuth, and an encrypted Restic repository at `rclone:<private-remote>:Avelren Backups/restic`. The remote name, rclone config, and Restic password remain in root-only private environment/config paths. Google passwords, app passwords, OAuth tokens, email addresses, and credentials are never committed.

Restic receives the full repository URL with the `rclone:` backend prefix, while direct rclone commands receive the same remote/path without that prefix: `<private-remote>:Avelren Backups/restic`.

Create the dedicated account with least privilege, complete rclone OAuth on a controlled machine, and transfer `rclone.conf` through a protected channel. Never paste an OAuth token into chat, shell history, or logs. On the server, `/etc/avelren/backup` is `root:root 0700`; `backup.env` and `rclone.conf` are `root:root 0600`, while the Restic password is `root:root 0400`. Password-file mode `0600` remains accepted only for backward compatibility.

Install the scripts as root under `/usr/local/libexec/` and the units from `deploy/systemd/` under `/etc/systemd/system/`. Verify the rclone remote and the `Avelren Backups` folder before explicit repository initialization. Initialization is never automatic. Run the init command once, then run the repository check.

The daily job checks PostgreSQL health, creates a custom-format dump with `--no-owner --no-acl`, validates it with `pg_restore --list`, encrypts it through Restic and rclone, and removes only its root-only temporary directory. `flock` prevents overlapping runs. Prune is a separate controlled operation with 7 daily, 4 weekly, and 3 monthly snapshots. A 12 GiB warning is emitted; new backups stop at 14 GiB without deleting existing snapshots.

The restore drill uses a random `avelren_restore_` database, never production database `avelren`, restores the latest snapshot, and verifies migrations `001–003` plus the main tables. An uncertain failure preserves the temporary database and files; cleanup occurs only after every verification succeeds.

Verify timers with `systemctl list-timers`, the daily backup timer, and the weekly repository check. For credential rotation, stop the timer, replace OAuth config/password through a root-only procedure, run repository check and a manual backup, then re-enable the timer. After server loss, recover packages, rclone OAuth config, and the Restic password from secure escrow, run `restic check`, perform a restore drill, and only then plan production recovery.
