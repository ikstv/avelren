# Конвеєр збору / Collection Pipeline

## Українською

Серверний конвеєр Avelren приймає вже нормалізовані спостереження з відкритого джерела. Реальний adapter відкритого джерела на цьому етапі не підключено, адреси, технічні деталі доступу і production-конфігурація не зберігаються в репозиторії.

`CollectorService.ingest` валідує `locationId`, `vehicleCount` і `observedAt`, створює детермінований `observationId` через SHA-256 і використовує перше спостереження як baseline без події. Повторні `observationId` та старіші або рівні `observedAt` не змінюють стан.

`SnapshotStore` зберігає останній стан для кожного `locationId`, підтримує монотонний `sequence` і повертає копії об'єктів. In-memory реалізації залишаються для локальних та unit-тестів. Production-режим використовує PostgreSQL для snapshots, оброблених observation IDs і `pending` outbox-подій зі стабільними `eventId`.

Порогові події створюються тільки при зростанні значення. Крок порогу дорівнює `50`; перехід `40 -> 160` створює події для `50`, `100` і `150`. Зменшення та незмінні значення подій не створюють.

`GET /v1/workload` повертає лише кешований snapshot і не запускає polling або запит до відкритого джерела. Якщо snapshot відсутній, сервер повертає структурований `503`. Demo seed дозволений лише при точному `AVELREN_DEMO_MODE=true`.

### PostgreSQL, міграції та lease

Для production потрібно явно встановити `AVELREN_STORAGE_MODE=postgres` і передати `DATABASE_URL` лише через environment. За відсутньої або неправильної конфігурації production-запуск завершується помилкою без переходу на in-memory storage. Реальні connection strings не зберігаються в репозиторії й не логуються.

Перед запуском HTTP server застосовує versioned SQL migrations із `services/api/migrations`. Migration runner використовує транзакційний PostgreSQL advisory lock, таблицю `avelren_schema_migrations` і SHA-256 checksum; повторний або конкурентний запуск безпечний, а помилка міграції зупиняє server startup.

Snapshot, observation ID і створені threshold events записуються атомарно в одній транзакції. Унікальні обмеження БД захищають observation IDs та ідентичність threshold events від повторів. Усі значення SQL параметризовані; сирий payload відкритого джерела не зберігається.

Distributed lease зберігає `ownerId` і `expiresAt` у PostgreSQL. Acquire, renew і release атомарні, рішення щодо TTL використовують `clock_timestamp()` PostgreSQL, а мережевий запит не утримує SQL-транзакцію. Replica без lease безпечно пропускає цикл. Мінімальний polling interval залишається 60 секунд.

Локальні PostgreSQL integration tests використовують `TEST_DATABASE_URL`; CI запускає ізольований service container із тестовими credentials. Приклад production-конфігурації у `.env.example` навмисно використовує домен `.invalid`.

Таблиця snapshots містить лише останній запис на `locationId`, тому старі snapshots автоматично не накопичуються. Автоматичне видалення observation IDs або pending outbox events не ввімкнено: воно може порушити дедуплікацію або доставку. Контрольована retention-процедура має бути додана разом із delivery lifecycle в окремій зміні.

## English

The Avelren server pipeline accepts already normalized observations from a publicly accessible external source. The real adapter for that source is not connected at this stage, and source addresses, technical access details, and production configuration are not stored in the repository.

`CollectorService.ingest` validates `locationId`, `vehicleCount`, and `observedAt`, derives a deterministic SHA-256 `observationId`, and treats the first observation as a baseline without an event. Repeated `observationId` values and older or equal `observedAt` values do not mutate state.

`SnapshotStore` keeps the latest state per `locationId`, maintains a monotonic `sequence`, and returns object copies. In-memory implementations remain available for local and unit tests. Production mode uses PostgreSQL for snapshots, processed observation IDs, and `pending` outbox events with stable `eventId` values.

Threshold events are created only when the value increases. The threshold step is `50`; a `40 -> 160` transition creates events for `50`, `100`, and `150`. Decreases and unchanged values do not create events.

`GET /v1/workload` returns only the cached snapshot and never triggers polling or a request to the publicly accessible external source. If no snapshot exists, the server returns a structured `503`. Demo seeding is enabled only by exact `AVELREN_DEMO_MODE=true`.

### PostgreSQL, migrations, and lease

Production must explicitly set `AVELREN_STORAGE_MODE=postgres` and provide `DATABASE_URL` only through the environment. Missing or invalid production configuration fails startup without falling back to in-memory storage. Real connection strings are neither stored in the repository nor logged.

Before the HTTP server starts, it applies versioned SQL migrations from `services/api/migrations`. The migration runner uses a transactional PostgreSQL advisory lock, the `avelren_schema_migrations` table, and SHA-256 checksums; repeated and concurrent runs are safe, while a migration failure stops server startup.

The snapshot, observation ID, and generated threshold events are written atomically in one transaction. Database unique constraints protect observation IDs and threshold-event identity from duplicates. Every SQL value is parameterized, and raw payloads from the publicly accessible external source are not stored.

The distributed lease stores `ownerId` and `expiresAt` in PostgreSQL. Acquire, renew, and release are atomic, TTL decisions use PostgreSQL `clock_timestamp()`, and the network request does not hold a SQL transaction. A replica without the lease safely skips its cycle. The minimum polling interval remains 60 seconds.

Local PostgreSQL integration tests use `TEST_DATABASE_URL`; CI starts an isolated service container with test-only credentials. The production configuration example in `.env.example` intentionally uses an `.invalid` domain.

The snapshots table keeps only the latest row per `locationId`, so old snapshots do not accumulate. Automatic deletion of observation IDs or pending outbox events is not enabled because it could break deduplication or delivery. A controlled retention procedure must be introduced with the delivery lifecycle in a separate change.
