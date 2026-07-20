# Безпека Avelren / Avelren Security

## Українська

### Статус підтримки

Avelren перебуває на ранньому етапі й ще не має production-релізу. Виправлення безпеки застосовуються лише до актуальної основної гілки.

### Як повідомити про вразливість

Не створюйте публічний issue з описом вразливості, секретами або способом експлуатації. Скористайтеся приватним повідомленням про вразливість у розділі **Security** репозиторію GitHub.

У повідомленні вкажіть:

- уражений компонент і версію або commit;
- умови відтворення;
- можливий вплив;
- мінімальний доказ концепції без реальних секретів і персональних даних;
- запропоноване виправлення, якщо воно відоме.

Супроводжувачі підтвердять отримання, оцінять ризик і узгодять подальшу комунікацію. Не публікуйте деталі до завершення виправлення або явного погодження.

### У межах політики

- Android-клієнт і його мережеві налаштування;
- серверний API та колектор;
- перевірка й нормалізація вхідних даних;
- порогові події та захист від повторів;
- CI, залежності й конфігурація репозиторію;
- витік секретів або production-конфігурації.

Недоступність або помилки відкритого джерела не є вразливістю Avelren, якщо вони не призводять до окремого порушення конфіденційності, цілісності чи доступності нашого продукту.

### Базові правила

- Android звертається лише до API Avelren.
- Мінімальний інтервал опитування — 60 секунд.
- Реальні адреси, ключі, токени та файли облікових даних не зберігаються в Git.
- API не повинен приймати довільну адресу відкритого джерела від користувача.
- Дані перевіряються за схемою, обмежуються за розміром і мають часові мітки.
- Застарілі дані позначаються явно й не породжують нових порогових подій.
- Production API має використовувати TLS, обмеження частоти та безпечні заголовки.

Детальніше: [модель загроз](docs/threat-model.md).

---

## English

### Support status

Avelren is at an early stage and has no production release yet. Security fixes apply only to the current default branch.

### Reporting a vulnerability

Do not open a public issue containing a vulnerability, secrets, or exploitation details. Use GitHub’s private vulnerability reporting feature in the repository’s **Security** section.

Include:

- the affected component and version or commit;
- reproduction conditions;
- potential impact;
- a minimal proof of concept without real secrets or personal data;
- a proposed fix, if known.

Maintainers will acknowledge the report, assess its risk, and coordinate further communication. Do not disclose details before remediation is complete or explicit approval is given.

### In scope

- the Android client and its network configuration;
- the server API and collector;
- input validation and normalization;
- threshold events and duplicate protection;
- CI, dependencies, and repository configuration;
- leakage of secrets or production configuration.

Unavailability or errors in a publicly accessible external source are not an Avelren vulnerability unless they cause a separate confidentiality, integrity, or availability issue in our product.

### Baseline rules

- Android contacts only the Avelren API.
- The minimum polling interval is 60 seconds.
- Real addresses, keys, tokens, and credential files are never stored in Git.
- The API must not accept an arbitrary publicly accessible external source address from a user.
- Data is schema-validated, size-limited, and timestamped.
- Stale data is explicitly marked and does not create new threshold events.
- A production API must use TLS, rate limiting, and secure headers.

See the [threat model](docs/threat-model.md) for details.
