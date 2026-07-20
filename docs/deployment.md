# Production deployment Avelren / Avelren production deployment

## Українська

### Межі першого deployment

Ця конфігурація готує один Ubuntu 24.04 сервер для запуску API Avelren, PostgreSQL і Caddy через Docker Compose. API доступний лише Caddy через внутрішню Docker-мережу. PostgreSQL не має host port. Перший запуск навмисно вимикає push, application attestation і adapter відкритого джерела.

Файли в Git не містять production-домену або секретів. Перед deployment оператор має визначити домен, email для ACME, унікальний instance ID, політику backup і два локальні secret-файли.

### Локальна перевірка

```bash
cd services/api
npm ci
npm run typecheck
npm test
npm run build
npm audit --omit=dev
cd ../..
docker compose --env-file .env.production.example config --quiet
```

### Підготовка приватної конфігурації на сервері

Виконуйте ці команди лише у приватній директорії deployment. Значення `.invalid` у прикладі не придатні для TLS.

```bash
cp .env.production.example .env.production
chmod 600 .env.production
install -d -m 700 secrets

DB_PASSWORD="$(openssl rand -hex 32)"
printf '%s' "$DB_PASSWORD" > secrets/postgres_password
printf 'postgresql://avelren:%s@postgres:5432/avelren' "$DB_PASSWORD" > secrets/database_url
unset DB_PASSWORD
chmod 600 secrets/postgres_password secrets/database_url
```

Відредагуйте `.env.production`: встановіть справжні `AVELREN_DOMAIN`, `ACME_EMAIL` та унікальний `AVELREN_INSTANCE_ID`. Пароль PostgreSQL у двох secret-файлах має залишатися однаковим. Не додавайте ці файли до Git.

### Майбутній deployment

DNS A/AAAA має вказувати на сервер, а host ports 80 і 443 мають бути доступні до запуску Caddy.

```bash
docker compose --env-file .env.production config --quiet
docker compose --env-file .env.production build --pull
docker compose --env-file .env.production up -d
docker compose --env-file .env.production ps
docker compose --env-file .env.production logs --tail=100 api postgres caddy
curl --fail --silent --show-error "https://${AVELREN_DOMAIN}/v1/health"
```

Для зупинки без видалення даних:

```bash
docker compose --env-file .env.production down
```

Не використовуйте `down -v`: named volumes містять PostgreSQL і TLS-стан Caddy. До публічного запуску налаштуйте перевірений off-host backup PostgreSQL і процедуру відновлення.

### Security-властивості й обмеження

- Лише Caddy публікує host ports. API та PostgreSQL не публікуються напряму.
- API і Caddy працюють non-root, із read-only root filesystem, dropped capabilities і `no-new-privileges`.
- PostgreSQL використовує upstream entrypoint, який готує volume і переходить до користувача `postgres`.
- Docker logs обмежені ротацією; кожен сервіс має healthcheck, restart policy і resource limits.
- Docker-published ports можуть обходити частину правил UFW. Compose навмисно публікує лише Caddy 80/443; не додавайте `ports` до API або PostgreSQL.
- Це single-server deployment без high availability. Падіння host або пошкодження локального volume зупиняє сервіс.
- Стандартний Caddy image не додає application rate limiting. До широкого публічного запуску потрібне окреме рішення rate limiting або upstream edge protection.
- Image tags слід зафіксувати digest-значеннями під час контрольованого release після перевірки оновлень.

## English

### First-deployment boundary

This configuration prepares one Ubuntu 24.04 server to run the Avelren API, PostgreSQL, and Caddy through Docker Compose. Only Caddy can reach the host network. The API is reachable through an internal Docker network, and PostgreSQL has no host port. Push, application attestation, and the publicly accessible external source adapter are intentionally disabled for the first start.

No production domain or secret is stored in Git. Before deployment, the operator must choose the domain, ACME email, unique instance ID, backup policy, and two local secret files.

### Local verification

```bash
cd services/api
npm ci
npm run typecheck
npm test
npm run build
npm audit --omit=dev
cd ../..
docker compose --env-file .env.production.example config --quiet
```

### Prepare private configuration on the server

Run these commands only inside the private deployment directory. The `.invalid` example values cannot obtain TLS certificates.

```bash
cp .env.production.example .env.production
chmod 600 .env.production
install -d -m 700 secrets

DB_PASSWORD="$(openssl rand -hex 32)"
printf '%s' "$DB_PASSWORD" > secrets/postgres_password
printf 'postgresql://avelren:%s@postgres:5432/avelren' "$DB_PASSWORD" > secrets/database_url
unset DB_PASSWORD
chmod 600 secrets/postgres_password secrets/database_url
```

Edit `.env.production` and set the real `AVELREN_DOMAIN`, `ACME_EMAIL`, and a unique `AVELREN_INSTANCE_ID`. The PostgreSQL password must remain identical in both secret files. Never add these files to Git.

### Future deployment

DNS A/AAAA must point to the server, and host ports 80 and 443 must be reachable before Caddy starts.

```bash
docker compose --env-file .env.production config --quiet
docker compose --env-file .env.production build --pull
docker compose --env-file .env.production up -d
docker compose --env-file .env.production ps
docker compose --env-file .env.production logs --tail=100 api postgres caddy
curl --fail --silent --show-error "https://${AVELREN_DOMAIN}/v1/health"
```

Stop the stack without deleting data:

```bash
docker compose --env-file .env.production down
```

Do not use `down -v`: named volumes contain PostgreSQL data and Caddy TLS state. Configure and test an off-host PostgreSQL backup and restore procedure before public deployment.

### Security properties and limitations

- Only Caddy publishes host ports. Neither the API nor PostgreSQL is directly published.
- The API and Caddy run as non-root with read-only root filesystems, dropped capabilities, and `no-new-privileges`.
- PostgreSQL uses the upstream entrypoint, which prepares the volume and switches to the `postgres` user.
- Docker logs are bounded by rotation; every service has a healthcheck, restart policy, and resource limits.
- Docker-published ports can bypass parts of UFW. This Compose file intentionally publishes only Caddy on 80/443; never add `ports` to the API or PostgreSQL.
- This is a single-server deployment without high availability. Host or local-volume failure stops the service.
- The standard Caddy image does not add application rate limiting. Add a separate rate-limiting layer or upstream edge protection before broad public exposure.
- Pin image tags to reviewed digests during a controlled release after update verification.
