# Модель загроз Avelren / Avelren Threat Model

## Українська

### Обсяг і активи

Модель охоплює Android, публічний API, майбутній серверний адаптер, конфігурацію та CI. На першому етапі немає акаунтів, персональних даних, production deployment або FCM.

Головні активи: доступність сервера, цілісність і свіжість стану, коректність порогів, серверні секрети та стабільність відкритого джерела.

### Базові припущення

- відкрите джерело й усі вхідні дані недовірені;
- Android-пристрій і публічний API можуть отримувати довільні запити;
- користувач не керує адресою серверного джерела;
- публічний репозиторій повністю видимий атакувальнику;
- Android не містить адреси джерела або серверних credentials.

### Загрози й протидії

| Загроза | Поточна протидія | Що потрібно до production |
|---|---|---|
| Android звертається до джерела | У клієнті є лише HTTPS URL Avelren API | Автоматична перевірка мережевих destination |
| Опитування частіше 60 секунд | Жорстка валідація `>= 60_000 ms`, single-flight | Durable lease для рестартів і кількох реплік |
| SSRF | Публічний API не приймає URL; production adapter відсутній | Статична allowlist, DNS/IP перевірка, блокування приватних адрес |
| Велика або шкідлива відповідь | Реальний adapter ще не підключено | Timeout, size limit, content-type і schema validation |
| Повторні порогові події | Перший стан є базою; політика чиста й протестована | Ідемпотентний event ID та outbox |
| Витік секретів | `.env`, ключі та Firebase-файли ігноруються; у Git лише `.invalid` адреси | Secret scanning і короткоживучі credentials |
| Перехоплення трафіку Android | Cleartext вимкнено; URL збірки зобов’язаний бути HTTPS | TLS на production API, ротація сертифікатів |
| API flood | Read-only API не запускає source poll | Rate limiting, cache headers, метрики |
| Supply-chain compromise | GitHub Actions мають мінімальні permissions і pinned checkout SHA | Dependabot/dependency review та регулярні оновлення |
| Хибне враження офіційності | Власний бренд і явний неофіційний статус | Зберігати дисклеймери в застосунку та релізах |

### Правила релізу

До підключення production adapter обов’язкові allowlist, захист від SSRF, timeout, обмеження відповіді, схема, backoff і durable lease. До FCM обов’язкові захищені серверні credentials, Android runtime permission, notification channel та ідемпотентний outbox.

Модель переглядається перед додаванням нового джерела, FCM, акаунтів, історії, аналітики або персональних даних.

## English

### Scope and assets

This model covers Android, the public API, the future server adapter, configuration, and CI. The first milestone has no accounts, personal data, production deployment, or FCM.

Primary assets are server availability, state integrity and freshness, threshold correctness, server secrets, and stability of the publicly accessible external source.

### Baseline assumptions

- the publicly accessible external source and all input are untrusted;
- an Android device and the public API can receive arbitrary requests;
- users cannot control the server-side source address;
- an attacker can read the complete public repository;
- Android contains neither the source address nor server credentials.

### Threats and mitigations

| Threat | Current mitigation | Required before production |
|---|---|---|
| Android contacts the source | The client contains only the Avelren HTTPS API URL | Automated network-destination check |
| Polling faster than 60 seconds | Hard `>= 60,000 ms` validation and single-flight execution | Durable lease across restarts and replicas |
| SSRF | The public API accepts no URL; no production adapter exists | Static allowlist, DNS/IP validation, private-address blocking |
| Oversized or malicious response | No real adapter is connected | Timeout, size limit, content-type and schema validation |
| Duplicate threshold events | First state is a baseline; policy is pure and tested | Idempotent event ID and outbox |
| Secret leakage | `.env`, keys, and Firebase files are ignored; Git uses only `.invalid` addresses | Secret scanning and short-lived credentials |
| Android traffic interception | Cleartext is disabled; build-time API URL must use HTTPS | TLS on the production API and certificate rotation |
| API flooding | The read-only API never triggers a source poll | Rate limiting, cache headers, and metrics |
| Supply-chain compromise | GitHub Actions use minimal permissions and a pinned checkout SHA | Dependabot/dependency review and regular updates |
| False official impression | Independent branding and explicit unofficial status | Preserve disclaimers in the app and releases |

### Release gates

Before connecting a production adapter, require an allowlist, SSRF protection, timeout, response limits, schema validation, backoff, and a durable lease. Before FCM, require protected server credentials, Android runtime permission, a notification channel, and an idempotent outbox.

Review this model before adding another source, FCM, accounts, history, analytics, or personal data.
