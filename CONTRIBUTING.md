# Внески до Avelren / Contributing to Avelren

## Українська

Дякуємо за інтерес до Avelren. Проєкт розвивається малими перевірюваними змінами з безпекою за замовчуванням.

### Перед початком

1. Створіть окрему гілку від актуальної основної гілки.
2. Не додавайте секрети, production-адреси, дампи даних або персональні дані.
3. У публічній документації називайте постачальника даних лише «відкрите джерело».
4. Не змінюйте API-контракт без синхронного оновлення прикладів і споживачів.
5. Не зменшуйте мінімальний інтервал опитування нижче 60 секунд.

### Заголовок коміту та pull request

Обов’язковий формат:

```text
type(scope): Українська назва / English title
```

Дозволені типи:

- `feat` — нова можливість;
- `fix` — виправлення дефекту;
- `docs` — документація;
- `test` — тести;
- `refactor` — зміна структури без зміни поведінки;
- `perf` — продуктивність;
- `build` — система збирання;
- `ci` — автоматизація репозиторію;
- `chore` — технічне обслуговування;
- `style` — форматування без зміни поведінки;
- `revert` — скасування попередньої зміни.

`scope` пишеться латинкою в нижньому регістрі, наприклад `android`, `server`, `api`, `docs` або `repo`.

Приклад:

```text
feat(api): Додати поточний знімок / Add current snapshot
```

### Тіло коміту та pull request

Український блок завжди йде першим, англійський — другим:

```text
UA:
Додано контракт поточного знімка та перевірку кроку порога.

EN:
Added the current snapshot contract and threshold-step validation.
```

Обидва блоки мають описувати причину, поведінку і спосіб перевірки зміни. Для несумісної зміни окремо вкажіть план міграції.

### Якість зміни

Перед відкриттям pull request:

- запустіть тести зміненого компонента;
- перевірте `git diff --check`;
- перевірте JSON-приклади й OpenAPI;
- переконайтеся, що Android не звертається до відкритого джерела;
- переконайтеся, що конфігурація не може встановити опитування частіше ніж раз на 60 секунд;
- додайте або оновіть тести для порогів `50`, `100`, `150` та стрибка через кілька порогів;
- перевірте, що журнали не містять секретів або повних production-адрес.

### Рев’ю

Pull request має бути малим і сфокусованим. Рев’юер перевіряє коректність, безпеку, тестованість, сумісність контракту та двомовність опису.

Ліцензійну модель ще не визначено. Надсилання внеску не створює окремої ліцензійної угоди; рішення щодо прийняття внесків залишається за супроводжувачами до затвердження політики.

---

## English

Thank you for your interest in Avelren. The project evolves through small, verifiable changes with secure defaults.

### Before you start

1. Create a dedicated branch from the current default branch.
2. Do not add secrets, production addresses, data dumps, or personal data.
3. In public documentation, refer to the data provider only as a “publicly accessible external source”.
4. Do not change the API contract without updating its examples and consumers in the same change.
5. Never reduce the minimum polling interval below 60 seconds.

### Commit and pull request title

The required format is:

```text
type(scope): Українська назва / English title
```

Allowed types:

- `feat` — new capability;
- `fix` — defect correction;
- `docs` — documentation;
- `test` — tests;
- `refactor` — structural change without behavioral change;
- `perf` — performance;
- `build` — build system;
- `ci` — repository automation;
- `chore` — maintenance;
- `style` — formatting without behavioral change;
- `revert` — reversal of an earlier change.

Write `scope` in lowercase Latin characters, for example `android`, `server`, `api`, `docs`, or `repo`.

Example:

```text
feat(api): Додати поточний знімок / Add current snapshot
```

### Commit and pull request body

The Ukrainian block always comes first and the English block second:

```text
UA:
Додано контракт поточного знімка та перевірку кроку порога.

EN:
Added the current snapshot contract and threshold-step validation.
```

Both blocks must describe the reason, behavior, and verification method. For a breaking change, include a migration plan.

### Change quality

Before opening a pull request:

- run tests for the changed component;
- run `git diff --check`;
- validate JSON examples and OpenAPI;
- verify that Android does not contact the publicly accessible external source;
- verify that configuration cannot poll more frequently than once every 60 seconds;
- add or update tests for thresholds `50`, `100`, `150`, and a jump across multiple thresholds;
- verify that logs contain no secrets or complete production addresses.

### Review

Keep each pull request small and focused. Reviewers check correctness, security, testability, contract compatibility, and bilingual descriptions.

The licensing model has not been selected yet. Submitting a contribution does not create a separate license agreement; maintainers retain discretion over accepting contributions until a policy is approved.
