# Основа push-сповіщень / Push notification foundation

## UA

Порогова подія та записи `notification_outbox` для всіх активних на той момент
Android-інсталяцій створюються однією PostgreSQL-транзакцією. Нові інсталяції не
отримують старі події. Worker короткою транзакцією захоплює bounded batch через
`FOR UPDATE SKIP LOCKED`, звільняє транзакцію до мережевого виклику, а завершити
або перенести запис може лише owner активного claim. TTL визначається часом
PostgreSQL.

FCM-токени шифруються AES-256-GCM. HMAC-SHA-256 fingerprint використовує окремий
ключ; keyring зберігає active key id та попередні ключі для ротації. Installation
credential генерується випадково, повертається лише під час першої успішної
реєстрації та зберігається сервером як salted `scrypt` verifier. Android зберігає
credential у ciphertext, захищеному Android Keystore, і не зберігає FCM-токен.

`PUSH_ENABLED=false` є безпечним локальним режимом. При `PUSH_ENABLED=true`
сервер вимагає PostgreSQL, `FCM_PROJECT_ID`, keyring, fingerprint key та Application
Default Credentials/workload identity. Неповна конфігурація зупиняє startup;
mock-provider або in-memory fallback не вмикаються. Імена параметрів наведено у
`.env.example`, значення credentials до репозиторію не додаються.

Реєстраційний endpoint має strict runtime validation, малий body limit,
rate limiting і нормалізовані помилки. Це базовий abuse-захист, але не доказ
автентичності застосунку. Play Integrity або App Check свідомо відкладені до
окремого security milestone. PostgreSQL storage та worker потребують операційного
моніторингу, retention policy і резервного копіювання перед production.

Android приймає лише schema version `1` з точним набором мінімальних полів,
ігнорує невідомі схеми та не виконує довільні URL. Реальний adapter відкритого
джерела не входить до цієї реалізації.

Необов'язкові Android build properties `AVELREN_FCM_APPLICATION_ID`,
`AVELREN_FCM_PROJECT_ID`, `AVELREN_FCM_API_KEY` і `AVELREN_FCM_SENDER_ID`
передаються лише через локальну/CI build-конфігурацію. Без них local build і тести
працюють, але Firebase не ініціалізується. Реальні значення не відстежуються Git.

## EN

A threshold event and `notification_outbox` rows for installations enabled at
that moment are created in one PostgreSQL transaction. Newly registered devices
do not receive historical events. The worker claims a bounded batch in a short
`FOR UPDATE SKIP LOCKED` transaction, releases it before network I/O, and permits
only the owner of a live claim to complete or reschedule it. TTL uses PostgreSQL
time.

FCM tokens use AES-256-GCM encryption. An independent HMAC-SHA-256 key produces
fingerprints, while a keyring retains the active and old encryption keys for
rotation. A random installation credential is returned only by the first
successful registration and stored server-side as a salted `scrypt` verifier.
Android keeps only Keystore-protected credential ciphertext and does not persist
the FCM token.

`PUSH_ENABLED=false` is the safe local mode. Enabling push requires PostgreSQL,
`FCM_PROJECT_ID`, the keyring, fingerprint key, and Application Default
Credentials/workload identity. Incomplete configuration stops startup; there is
no mock provider or in-memory fallback. Configuration names are documented in
`.env.example`, without credential values.

Strict runtime validation, a small body limit, rate limiting, and normalized
errors provide baseline abuse resistance, not app authenticity. Play Integrity
or App Check is deliberately deferred to a separate security milestone.
PostgreSQL storage and the worker still require production monitoring, retention,
and backups.

Android accepts only schema version `1` with the exact minimal field set, ignores
unknown schemas, and never follows arbitrary URLs. A real publicly accessible
external source adapter remains outside this implementation.

Optional Android build properties `AVELREN_FCM_APPLICATION_ID`,
`AVELREN_FCM_PROJECT_ID`, `AVELREN_FCM_API_KEY`, and `AVELREN_FCM_SENDER_ID` are
provided only by local/CI build configuration. Local builds and tests work without
them, while Firebase remains uninitialized. Real values are not tracked by Git.
