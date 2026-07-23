# PostgreSQL backup / резервне копіювання PostgreSQL

## Українська

Backup використовує Restic repository `rclone:<private-remote>:Avelren Backups/restic`. OAuth-конфіг rclone, Restic password і `backup.env` зберігаються лише у root-only paths. Пароль PostgreSQL читається з наявного Docker secret `/run/secrets/postgres_password`; він не передається через argv, host environment або output.

### Runtime і cancellation model

`postgres-backup.sh` запускає detached `docker exec` усередині PostgreSQL-контейнера та підключає `pg_dump` до `127.0.0.1:5432` через SCRAM. Випадковий `PGPASSFILE` (`root:root 0600`), runner і PID/start-time identities існують лише в окремому `tmpfs` `/run/avelren-backup` (`root:root 0700`). Перед стартом backup fail-closed перевіряє declared Docker tmpfs options (`rw`, `noexec`, `nosuid`, `nodev`, `mode=0700`, `uid=0`, `gid=0`) і effective kernel mount через `/proc/self/mountinfo`: точний mount point, тип `tmpfs`, effective `rw,noexec,nosuid,nodev` та directory `root:root 0700`. Restart або recreate контейнера знищує цей runtime state; PostgreSQL data volume його не містить.

Перед стартом нова операція fail-closed відмовляється працювати, якщо runtime має state іншої операції. Directory створюється атомарним `mkdir`; collision ніколи не перезаписує runner, heartbeat чи identity і повторюється не більше п’яти разів. `flock` додатково забороняє конкурентні host-side backup-и.

Host locks мають окремий runtime namespace `/run/avelren` (`root:root 0700`): `/run/avelren/postgres-backup.lock` і `/run/avelren/postgres-restore.lock` є різними logical locks та regular files `root:root 0600`. Backup unit створює лише цей namespace через `RuntimeDirectory=avelren`, зберігає його до reboot через `RuntimeDirectoryPreserve=yes` і не має write access до shared `/run/lock`; repo-check unit не має write access до lock namespace. Обидва oneshot units незалежно provision-ять persistent `/var/lib/avelren-backup` через `StateDirectory=avelren-backup` з owner `root:root` і mode `0700`, тому перший запуск не залежить від попереднього ручного створення каталогу. Прямий root-запуск створює лише відсутній exact leaf під root-controlled `/run`, а existing symlink, non-directory або directory з іншими owner/group/mode відхиляє без repair. Lock helper відхиляє symlink, FIFO, socket/device/directory, hardlink, неправильні owner/group/mode та path/FD identity mismatch; absent file створює з observed `O_CREAT|O_EXCL`, existing valid file відкриває без truncation і повторно звіряє device/inode після `flock`. Bash не надає `O_NOFOLLOW`: локальний invariant спирається на root-controlled parent, exact `0700` namespace, atomic creation і post-open identity checks; root-equivalent attacker поза цією threat model.

`AVELREN_BACKUP_LOCK_FILE` лишається сумісним override повного absolute canonical file path. Його `dirname` є dedicated leaf namespace: parent уже має існувати, бути root-owned і не бути untrusted writable; script створює лише exact missing leaf, ніколи не `chmod`/`chown` existing directory і fail-closed відхиляє unsafe path components або object. Для systemd non-default path додатково має бути явно writable для unit, не перебувати у private `/tmp`/`/var/tmp` namespace і однаково задаватися для всіх відповідних manual/timer запусків; documented default є підтримуваним спільним domain для цих запусків. Старі direct files `/run/lock/avelren-postgres-backup.lock` та `/run/lock/avelren-postgres-restore.lock` новий release не відкриває і не видаляє; вони зникають природно після reboot. Release навмисно не перевіряє й не ремонтує metadata shared `/run/lock`: якщо старий script уже пошкодив її, потрібні reboot або окреме OS-specific відновлення адміністратором. Mixed old/new releases не мають спільного lock domain, а shared deployment/operation gate лишається окремим невирішеним етапом.

При SIGINT/SIGTERM controller надсилає TERM лише supervisor перевіреної операції. Під час setup окремий 128-bit token передає host-у cleanup ownership до blocking `docker exec`; exact directory видаляється лише після повторної перевірки цього root-only marker, а collision або missing/mismatched marker зберігається fail-closed. Supervisor робить для `pg_dump`: TERM → bounded wait → KILL → `wait`, потім так само завершує і reap-ить watchdog та виходить останнім. Host escalation перевіряє operation ID, PID, `/proc` start time і operation token повторно безпосередньо перед кожним scoped signal. Це defense against PID reuse/stale identifiers, а не абсолютна атомарна гарантія kernel-level identity-and-signal. SIGINT повертає 130, SIGTERM — 143.

Якщо Docker daemon недоступний, controller не вгадує PID і не видаляє неперевірений state. Після відновлення daemon живий watchdog завершує операцію; restart/recreate контейнера гарантовано очищає tmpfs. Paused/frozen контейнер не може виконувати traps або watchdog: credential залишається root-only у RAM tmpfs до unpause з cleanup або restart/recreate. Timer не слід перезапускати, доки попередній state не зник і контейнер не healthy.

Custom dump створюється з `--no-owner --no-acl`, копіюється на host лише після status `0`, перевіряється `pg_restore --list`, шифрується Restic і після цього видаляється з root-only temporary directory. Host dump створюється атомарно як root-owned regular file з exact mode `0600` незалежно від umask викликача; наявний symlink, FIFO, directory або regular file відхиляється. Backup не виконує SQL mutation. Prune є окремою командою: 7 daily, 4 weekly, 3 monthly; warning — 12 GiB, hard stop нових backup-ів — 14 GiB.

`AVELREN_BACKUP_TRANSFER_TIMEOUT` окремо обмежує host-side streaming dump: default `900` секунд, допустимий діапазон `30..7200`. `AVELREN_BACKUP_DOCKER_TIMEOUT` лишається лише для коротких Docker/control commands.

Restore drill вибирає `latest` лише серед snapshot-ів із тим самим PostgreSQL tag, приймає рівно один regular dump із production naming/ownership contract і відкриває його один раз через перевірений FD. `createdb`, streaming `pg_restore`, validation і `dropdb` виконуються в одному immutable PostgreSQL container через explicit TCP `127.0.0.1:5432` та root-only `PGPASSFILE` у перевіреному tmpfs; host libpq environment і host `pg_restore` не використовуються. Temporary database має випадкову identity, відмінну від `avelren`; interruption cleanup спочатку зупиняє token-scoped PostgreSQL backend створення, а потім звіряє operation token, cluster identity та database OID. Restore payload видаляється лише після повторної перевірки token та device/inode; mismatch або cleanup failure зберігає state з redacted diagnostic. Root-equivalent host/container attacker або PostgreSQL superuser поза локальною threat model цього drill.

### Точна процедура install/upgrade

Команди нижче виконує root. `release_root` — абсолютний шлях до перевіреного checkout; `deploy_root` — `/opt/avelren`. Не продовжуйте після будь-якої помилки.

```bash
set -eu
release_root="$(git rev-parse --show-toplevel)"
deploy_root=/opt/avelren
compose=(docker compose --env-file /opt/avelren/.env.production --file /opt/avelren/docker-compose.yml)
rollback_root="/var/backups/avelren-backup-release/$(date -u +%Y%m%dT%H%M%SZ)"

for timer in avelren-postgres-backup.timer avelren-postgres-repo-check.timer; do
  systemctl cat "$timer" >/dev/null 2>&1 || continue
  systemctl disable --now "$timer"
done
for unit in avelren-postgres-backup.service avelren-postgres-repo-check.service; do
  systemctl cat "$unit" >/dev/null 2>&1 && systemctl stop "$unit"
  if systemctl is-active --quiet "$unit"; then echo "ABORT: $unit is still active" >&2; exit 1; fi
done

# Старий і новий runtime paths мають не містити активної операції.
"${compose[@]}" exec -T -u 0 postgres sh -eu -c '
  for item in /tmp/avelren-pg-backup.* /run/avelren-backup/operation.*; do
    [ ! -e "$item" ] || { echo active-backup-operation >&2; exit 1; }
  done
'

install -d -o root -g root -m 0700 "$rollback_root/libexec" "$rollback_root/systemd"
for file in /usr/local/libexec/postgres-tcp-dump.sh /usr/local/libexec/postgres-tcp-restore.sh /usr/local/libexec/postgres-backup-control.sh \
  /usr/local/libexec/restic-password-file.sh /usr/local/libexec/restic-repository.sh /usr/local/libexec/secure-lock-file.sh \
  /usr/local/libexec/avelren-postgres-backup /usr/local/libexec/avelren-postgres-backup-init \
  /usr/local/libexec/avelren-postgres-backup-repo-check /usr/local/libexec/avelren-postgres-backup-prune \
  /usr/local/libexec/avelren-postgres-restore-drill; do
  [ ! -e "$file" ] || cp -a -- "$file" "$rollback_root/libexec/"
done
for unit in avelren-postgres-backup.service avelren-postgres-backup.timer \
  avelren-postgres-repo-check.service avelren-postgres-repo-check.timer; do
  [ ! -e "/etc/systemd/system/$unit" ] || cp -a -- "/etc/systemd/system/$unit" "$rollback_root/systemd/"
done
cp -a -- "$deploy_root/docker-compose.yml" "$rollback_root/docker-compose.yml"

# Compose додає ephemeral runtime; validate перед replacement і recreate.
docker compose --env-file "$deploy_root/.env.production" --file "$release_root/docker-compose.yml" config --quiet
install -o root -g root -m 0644 "$release_root/docker-compose.yml" "$deploy_root/.docker-compose.yml.new"
mv -T "$deploy_root/.docker-compose.yml.new" "$deploy_root/docker-compose.yml"
"${compose[@]}" up -d --no-deps --force-recreate postgres
"${compose[@]}" up -d --wait --wait-timeout 120 postgres
container="$("${compose[@]}" ps -q postgres)"
test -n "$(docker inspect -f '{{with index .HostConfig.Tmpfs "/run/avelren-backup"}}{{.}}{{end}}' "$container")"
test "$(docker exec -u 0 "$container" stat -c '%u:%g:%a' /run/avelren-backup)" = 0:0:700

# Helper/control/support first; main second.
for name in postgres-tcp-dump postgres-tcp-restore postgres-backup-control restic-password-file restic-repository secure-lock-file; do
  install -o root -g root -m 0755 "$release_root/scripts/backup/$name.sh" "/usr/local/libexec/.$name.sh.new"
  mv -T "/usr/local/libexec/.$name.sh.new" "/usr/local/libexec/$name.sh"
done
for mapping in \
  postgres-backup-init.sh:avelren-postgres-backup-init \
  postgres-backup-repo-check.sh:avelren-postgres-backup-repo-check \
  postgres-backup-prune.sh:avelren-postgres-backup-prune \
  postgres-restore-drill.sh:avelren-postgres-restore-drill; do
  source_name="${mapping%%:*}"; destination_name="${mapping#*:}"
  install -o root -g root -m 0755 "$release_root/scripts/backup/$source_name" "/usr/local/libexec/.$destination_name.new"
  mv -T "/usr/local/libexec/.$destination_name.new" "/usr/local/libexec/$destination_name"
done
install -o root -g root -m 0755 "$release_root/scripts/backup/postgres-backup.sh" /usr/local/libexec/.avelren-postgres-backup.new
mv -T /usr/local/libexec/.avelren-postgres-backup.new /usr/local/libexec/avelren-postgres-backup

# Units only after scripts.
for unit in avelren-postgres-backup.service avelren-postgres-backup.timer \
  avelren-postgres-repo-check.service avelren-postgres-repo-check.timer; do
  install -o root -g root -m 0644 "$release_root/deploy/systemd/$unit" "/etc/systemd/system/.$unit.new"
  mv -T "/etc/systemd/system/.$unit.new" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
```

Validation не має placeholders і не запускає backup/restore/prune/init:

```bash
set -eu
release_root="$(git rev-parse --show-toplevel)"
cmp -s "$release_root/docker-compose.yml" /opt/avelren/docker-compose.yml
for name in postgres-tcp-dump postgres-tcp-restore postgres-backup-control restic-password-file restic-repository secure-lock-file; do
  cmp -s "$release_root/scripts/backup/$name.sh" "/usr/local/libexec/$name.sh"
done
for mapping in postgres-backup.sh:avelren-postgres-backup postgres-backup-init.sh:avelren-postgres-backup-init \
  postgres-backup-repo-check.sh:avelren-postgres-backup-repo-check postgres-backup-prune.sh:avelren-postgres-backup-prune \
  postgres-restore-drill.sh:avelren-postgres-restore-drill; do
  cmp -s "$release_root/scripts/backup/${mapping%%:*}" "/usr/local/libexec/${mapping#*:}"
done
for file in /usr/local/libexec/{postgres-tcp-dump.sh,postgres-tcp-restore.sh,postgres-backup-control.sh,restic-password-file.sh,restic-repository.sh,secure-lock-file.sh,avelren-postgres-backup,avelren-postgres-backup-init,avelren-postgres-backup-repo-check,avelren-postgres-backup-prune,avelren-postgres-restore-drill}; do
  test "$(stat -c '%U:%G:%a' "$file")" = root:root:755
done
for file in /etc/systemd/system/avelren-postgres-{backup,repo-check}.{service,timer}; do
  test "$(stat -c '%U:%G:%a' "$file")" = root:root:644
done
bash -n /usr/local/libexec/{postgres-tcp-dump.sh,postgres-tcp-restore.sh,postgres-backup-control.sh,restic-password-file.sh,restic-repository.sh,secure-lock-file.sh,avelren-postgres-backup,avelren-postgres-backup-init,avelren-postgres-backup-repo-check,avelren-postgres-backup-prune,avelren-postgres-restore-drill}
systemd-analyze verify /etc/systemd/system/avelren-postgres-{backup,repo-check}.{service,timer}
test "$(systemctl show avelren-postgres-backup.service -p RuntimeDirectory --value)" = avelren
test "$(systemctl show avelren-postgres-backup.service -p RuntimeDirectoryMode --value)" = 0700
test "$(systemctl show avelren-postgres-backup.service -p RuntimeDirectoryPreserve --value)" = yes
for unit in avelren-postgres-backup.service avelren-postgres-repo-check.service; do
  test "$(systemctl show "$unit" -p StateDirectory --value)" = avelren-backup
  test "$(systemctl show "$unit" -p StateDirectoryMode --value)" = 0700
done
docker compose --env-file /opt/avelren/.env.production --file /opt/avelren/docker-compose.yml config --quiet
test "$(docker exec -u 0 "$(docker compose --env-file /opt/avelren/.env.production --file /opt/avelren/docker-compose.yml ps -q postgres)" stat -c '%u:%g:%a' /run/avelren-backup)" = 0:0:700
```

Лише після PASS усіх команд дозволено `systemctl enable --now avelren-postgres-backup.timer avelren-postgres-repo-check.timer`. Якщо helper відсутній, не executable, не збігається з тим самим release або runtime не tmpfs `0700`, timer запускати заборонено.

### Rollback

```bash
set -eu
rollback_root=/var/backups/avelren-backup-release/YYYYmmddTHHMMSSZ
for timer in avelren-postgres-backup.timer avelren-postgres-repo-check.timer; do
  systemctl cat "$timer" >/dev/null 2>&1 || continue
  systemctl disable --now "$timer"
done
for unit in avelren-postgres-backup.service avelren-postgres-repo-check.service; do
  systemctl cat "$unit" >/dev/null 2>&1 && systemctl stop "$unit"
  systemctl is-active --quiet "$unit" && { echo "ABORT: $unit is still active" >&2; exit 1; } || true
done
install -o root -g root -m 0755 "$rollback_root/libexec/avelren-postgres-backup" /usr/local/libexec/.avelren-postgres-backup.rollback
mv -T /usr/local/libexec/.avelren-postgres-backup.rollback /usr/local/libexec/avelren-postgres-backup
for file in "$rollback_root"/libexec/*; do
  [ "${file##*/}" = avelren-postgres-backup ] && continue
  install -o root -g root -m 0755 "$file" "/usr/local/libexec/.${file##*/}.rollback"
  mv -T "/usr/local/libexec/.${file##*/}.rollback" "/usr/local/libexec/${file##*/}"
done
for file in "$rollback_root"/systemd/*; do install -o root -g root -m 0644 "$file" "/etc/systemd/system/${file##*/}"; done
install -o root -g root -m 0644 "$rollback_root/docker-compose.yml" /opt/avelren/.docker-compose.yml.rollback
mv -T /opt/avelren/.docker-compose.yml.rollback /opt/avelren/docker-compose.yml
systemctl daemon-reload
docker compose --env-file /opt/avelren/.env.production --file /opt/avelren/docker-compose.yml config --quiet
docker compose --env-file /opt/avelren/.env.production --file /opt/avelren/docker-compose.yml up -d --no-deps --force-recreate postgres
docker compose --env-file /opt/avelren/.env.production --file /opt/avelren/docker-compose.yml up -d --wait --wait-timeout 120 postgres
```

Повторіть validation для попереднього checkout і лише після PASS знову enable/start timers. Repository init, backup, restore і prune не є частиною install або rollback.

## English

Backups use the Restic repository `rclone:<private-remote>:Avelren Backups/restic`. The rclone OAuth config, Restic password, and `backup.env` remain in root-only paths. The PostgreSQL password is read from the existing Docker secret `/run/secrets/postgres_password`; it is never passed through argv, the host environment, or output.

### Runtime and cancellation model

`postgres-backup.sh` starts a detached `docker exec` inside the PostgreSQL container and connects `pg_dump` to `127.0.0.1:5432` with SCRAM. The random `PGPASSFILE` (`root:root 0600`), runner, and PID/start-time identities exist only in dedicated tmpfs `/run/avelren-backup` (`root:root 0700`). Before starting, backup fails closed unless both the declared Docker tmpfs options (`rw`, `noexec`, `nosuid`, `nodev`, `mode=0700`, `uid=0`, `gid=0`) and the effective kernel mount from `/proc/self/mountinfo` agree: exact mount point, `tmpfs` filesystem, effective `rw,noexec,nosuid,nodev`, and a `root:root 0700` directory. Container restart or recreation destroys this runtime state; it never enters the PostgreSQL data volume.

A new operation fails closed when runtime state from another operation exists. Atomic `mkdir` creation never overwrites another runner, heartbeat, or identity, and collision retry is bounded to five attempts. `flock` also prevents concurrent host-side backups.

Host locks use the dedicated runtime namespace `/run/avelren` (`root:root 0700`): `/run/avelren/postgres-backup.lock` and `/run/avelren/postgres-restore.lock` are separate logical locks and `root:root 0600` regular files. The backup unit creates only this namespace with `RuntimeDirectory=avelren`, preserves it until reboot with `RuntimeDirectoryPreserve=yes`, and has no write access to shared `/run/lock`; the repo-check unit has no write access to the lock namespace. Both oneshot units independently provision persistent `/var/lib/avelren-backup` with `StateDirectory=avelren-backup`, owner `root:root`, and mode `0700`, so the first start does not depend on prior manual directory creation. A direct root invocation creates only the absent exact leaf below root-controlled `/run`, while an existing symlink, non-directory, or directory with wrong owner/group/mode is rejected without repair. The lock helper rejects symlinks, FIFOs, sockets/devices/directories, hardlinks, wrong owner/group/mode, and path/FD identity mismatches; it creates an absent file with observed `O_CREAT|O_EXCL`, opens an existing valid file without truncation, and revalidates device/inode after `flock`. Bash does not provide `O_NOFOLLOW`: the local invariant rests on the root-controlled parent, exact `0700` namespace, atomic creation, and post-open identity checks; a root-equivalent attacker is outside this threat model.

`AVELREN_BACKUP_LOCK_FILE` remains a compatible override for a full absolute canonical file path. Its `dirname` is a dedicated leaf namespace: the parent must already exist, be root-owned, and not be untrusted-writable; the script creates only the exact missing leaf, never `chmod`s/`chown`s an existing directory, and rejects unsafe path components or objects fail-closed. For systemd, a non-default path must additionally be made explicitly writable to the unit, stay outside the private `/tmp`/`/var/tmp` namespace, and be configured consistently for all applicable manual/timer invocations; the documented default is the supported common domain for those invocations. The new release neither opens nor removes the legacy direct files `/run/lock/avelren-postgres-backup.lock` and `/run/lock/avelren-postgres-restore.lock`; they disappear naturally after reboot. The release intentionally neither validates nor repairs shared `/run/lock` metadata: if an old script already damaged it, reboot or separate OS-specific administrator recovery is required. Mixed old/new releases do not share a lock domain, and a shared deployment/operation gate remains a separate unresolved cycle.

On SIGINT/SIGTERM, the controller sends TERM only to the validated operation supervisor. During setup, an independent 128-bit token hands cleanup ownership to the host before the blocking `docker exec`; the exact directory is removed only after that root-only marker is revalidated, while a collision or missing/mismatched marker is preserved fail-closed. The supervisor performs TERM → bounded wait → KILL → `wait` for `pg_dump`, then stops and reaps the watchdog, and exits last. Host escalation revalidates the operation ID, PID, `/proc` start time, and operation token immediately before every scoped signal. This is defense against PID reuse/stale identifiers, not an absolute atomic kernel identity-and-signal guarantee. SIGINT returns 130 and SIGTERM returns 143.

When the Docker daemon is unavailable, the controller neither guesses a PID nor removes unverified state. A live watchdog completes cancellation after daemon recovery; container restart/recreation guarantees tmpfs cleanup. A paused/frozen container cannot run traps or the watchdog: the credential remains root-only in RAM-backed tmpfs until unpause and cleanup or restart/recreation. Do not restart the timer until the prior state is gone and PostgreSQL is healthy.

The custom dump uses `--no-owner --no-acl`, is copied to the host only after status `0`, is checked with `pg_restore --list`, encrypted with Restic, and removed from its root-only temporary directory. The host dump is atomically created as a root-owned regular file with exact mode `0600`, independent of caller umask; an existing symlink, FIFO, directory, or regular file is rejected. Backup executes no mutating SQL. Prune is separate: 7 daily, 4 weekly, and 3 monthly snapshots; warning at 12 GiB and hard stop for new backups at 14 GiB.

`AVELREN_BACKUP_TRANSFER_TIMEOUT` separately bounds host-side dump streaming: default `900` seconds, accepted range `30..7200`. `AVELREN_BACKUP_DOCKER_TIMEOUT` remains limited to short Docker/control commands.

### Exact install/upgrade procedure

Use the complete command blocks in the Ukrainian section above; commands and paths are language-independent. They stop and disable both timers, stop active oneshot services, abort if either service remains active, verify that no old or new runtime operation exists, save an executable rollback set, install and recreate the Compose tmpfs, install the secure-lock and other helper/control/support scripts first and the main script second, install systemd units last, and run `daemon-reload`.

The validation block contains no source/destination placeholders: `release_root` is resolved from the verified checkout with `git rev-parse`. It compares every exact source/destination pair, verifies ownership/modes and shell syntax, validates systemd units and Compose, and confirms runtime mode `0700`. It does not run backup, restore, prune, or repository initialization. Enable/start timers only after every command passes. A missing, non-executable, mismatched helper or non-tmpfs runtime is an unconditional abort.

### Rollback

Use the rollback block above with the exact timestamped `rollback_root`. It stops/disables timers, stops both oneshot services and aborts if they remain active, restores the previous main script before its matching helpers, restores units and Compose, runs `daemon-reload`, recreates PostgreSQL under the previous Compose definition, and requires validation against the previous checkout before timers may be enabled again. Repository initialization, backup, restore, and prune are never part of install or rollback.

The restore drill selects `latest` only within the producer's PostgreSQL tag, accepts exactly one regular dump matching the production naming/ownership contract, and opens it once through a verified FD. `createdb`, streaming `pg_restore`, validation, and `dropdb` use one immutable PostgreSQL container over explicit TCP `127.0.0.1:5432` with a root-only tmpfs `PGPASSFILE`; host libpq settings and host `pg_restore` are not used. The random temporary database differs from `avelren`; interruption cleanup first stops the token-scoped PostgreSQL creation backend, then checks the operation token, cluster identity, and recorded database OID. Restore payload removal revalidates the token and device/inode, while a mismatch or cleanup failure preserves state with a redacted diagnostic. A root-equivalent host/container attacker or PostgreSQL superuser is outside this drill's local threat model.
