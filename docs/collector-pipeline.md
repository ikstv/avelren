# Конвеєр збору / Collection Pipeline

## Українською

Серверний конвеєр Avelren приймає вже нормалізовані спостереження з відкритого джерела. Реальний adapter відкритого джерела на цьому етапі не підключено, адреси, технічні деталі доступу і production-конфігурація не зберігаються в репозиторії.

`CollectorService.ingest` валідує `locationId`, `vehicleCount` і `observedAt`, створює детермінований `observationId` через SHA-256 і використовує перше спостереження як baseline без події. Повторні `observationId` та старіші або рівні `observedAt` не змінюють стан.

`SnapshotStore` зберігає останній стан для кожного `locationId`, підтримує монотонний `sequence`, повертає копії об'єктів і серіалізує in-memory оновлення. `ThresholdEventStore` працює як in-memory outbox із `pending` подіями та стабільними `eventId`; повторне додавання однакового `eventId` не створює дубль.

Порогові події створюються тільки при зростанні значення. Крок порогу дорівнює `50`; перехід `40 -> 160` створює події для `50`, `100` і `150`. Зменшення та незмінні значення подій не створюють.

`GET /v1/workload` повертає лише кешований snapshot і не запускає polling або запит до відкритого джерела. Якщо snapshot відсутній, сервер повертає структурований `503`. Demo seed дозволений лише при точному `AVELREN_DEMO_MODE=true`.

## English

The Avelren server pipeline accepts already normalized observations from a publicly accessible external source. The real adapter for that source is not connected at this stage, and source addresses, technical access details, and production configuration are not stored in the repository.

`CollectorService.ingest` validates `locationId`, `vehicleCount`, and `observedAt`, derives a deterministic SHA-256 `observationId`, and treats the first observation as a baseline without an event. Repeated `observationId` values and older or equal `observedAt` values do not mutate state.

`SnapshotStore` keeps the latest state per `locationId`, maintains a monotonic `sequence`, returns object copies, and serializes in-memory updates. `ThresholdEventStore` acts as an in-memory outbox with `pending` events and stable `eventId` values; adding the same `eventId` again does not create a duplicate.

Threshold events are created only when the value increases. The threshold step is `50`; a `40 -> 160` transition creates events for `50`, `100`, and `150`. Decreases and unchanged values do not create events.

`GET /v1/workload` returns only the cached snapshot and never triggers polling or a request to the publicly accessible external source. If no snapshot exists, the server returns a structured `503`. Demo seeding is enabled only by exact `AVELREN_DEMO_MODE=true`.
