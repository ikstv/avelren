# Перевірка автентичності застосунку / Application attestation

## UA

Push-операції Avelren вимагають стандартний header `X-Firebase-AppCheck`. Сервер
перевіряє токен офіційним Firebase Admin SDK, фіксованим project ID та allowlist
Android application ID. Для доступу до Firebase використовуються лише Application
Default Credentials або workload identity; файли credentials до репозиторію не додаються.

Attestation є додатковою перевіркою. Зміна токена, heartbeat і деактивація також
вимагають installation credential. Rate limit виконується до перевірки App Check,
а невдала перевірка не запускає операцію зі сховищем. Production із увімкненими
push-операціями запускається лише в режимі `APP_ATTESTATION_MODE=firebase` з повною
конфігурацією. Немає fallback до fake або disabled.

Для локальних тестів дозволено `APP_ATTESTATION_MODE=fake`. Він приймає лише токен,
SHA-256 digest якого задано локально, не виконує мережевих запитів і заборонений у
production. Значення токена не слід зберігати в Git. Android debug build використовує
Debug App Check provider, а release build компілює лише Play Integrity provider.

App Check зменшує автоматизоване зловживання, але не є абсолютним доказом довіри та
без окремого одноразового механізму не гарантує захист від replay. Серверний bounded
cache зберігає лише SHA-256 digest уже перевіреного токена та ніколи не логує токен,
claims, payload, адресу API або credentials.

## EN

Avelren push operations require the standard `X-Firebase-AppCheck` header. The server
verifies the token with the official Firebase Admin SDK, a fixed project ID, and an
allowlist of Android application IDs. Firebase access uses only Application Default
Credentials or workload identity; credential files are not committed.

Attestation is additive. Token rotation, heartbeat, and deactivation also require the
installation credential. Rate limiting runs before App Check verification, and failed
verification never reaches storage. Production with push operations enabled starts only
with `APP_ATTESTATION_MODE=firebase` and complete configuration. There is no fallback to
fake or disabled modes.

`APP_ATTESTATION_MODE=fake` is available for local tests only. It accepts only a token
whose SHA-256 digest is configured locally, performs no network calls, and is forbidden
in production. The token value must not be committed. Android debug builds use the Debug
App Check provider, while release builds compile only the Play Integrity provider.

App Check reduces automated abuse, but it is not absolute proof of trust and does not
guarantee replay prevention without a separate one-time mechanism. The bounded server
cache stores only the SHA-256 digest of a verified token and never logs the token, claims,
payload, API address, or credentials.
