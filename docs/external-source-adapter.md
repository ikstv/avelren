# Безпечний адаптер відкритого джерела / Secure external source adapter

## Українська

Адаптер працює лише на сервері, вимкнений за замовчуванням і вимагає PostgreSQL. У Git немає production-адрес, реальних селекторів, відповідей або облікових даних. Увімкнений adapter завершує запуск із помилкою, якщо приватна конфігурація неповна чи небезпечна.

Перед кожним HTTP-запитом сервер атомарно резервує наступний дозволений час у PostgreSQL. Інтервал не може бути меншим за 60 секунд; lease і poll-state не допускають паралельних запитів кількох реплік та відновлюються після TTL. Мережева операція не виконується всередині SQL-транзакції.

HTTP-клієнт дозволяє лише HTTPS, точний allowlisted host і порт 443. DNS перевіряється до з'єднання, приватні та спеціальні IP-діапазони відхиляються, а перевірена адреса закріплюється для TLS-з'єднання зі збереженням імені хоста. Redirect, proxy, cookies, auth, стиснені відповіді й довільні headers не підтримуються. Timeout, розмір headers і декодованого body обмежені.

HTML вважається недовіреним. Parser не запускає JavaScript і не завантажує ресурси, вимагає рівно один збіг кожного приватно налаштованого selector та приймає лише суворе невід'ємне ціле і canonical UTC timestamp. До collector pipeline надходить тільки валідований `SourceObservation`; сирий body не зберігається, не логується й не повертається API.

`ETag` і `Last-Modified` зберігаються в обмеженому вигляді. `304` не змінює snapshot або outbox. Помилки, `403`, `429`, `Retry-After` і повторні `5xx` спричиняють PostgreSQL-керований backoff/circuit breaker, який ніколи не зменшує мінімальний інтервал.

## English

The adapter runs only on the server, is disabled by default, and requires PostgreSQL. Git contains no production address, real selector, captured response, or credential. An enabled adapter fails startup when its private configuration is incomplete or unsafe.

Before every HTTP request, the server atomically reserves the next allowed time in PostgreSQL. The interval cannot be shorter than 60 seconds; the lease and poll state prevent concurrent requests across replicas and recover after their TTL. The network operation never runs inside a SQL transaction.

The HTTP client permits only HTTPS, the exact allowlisted host, and port 443. DNS is checked before connection, private and special IP ranges are rejected, and the validated address is pinned for the TLS connection while preserving the hostname. Redirects, proxies, cookies, authentication, compressed responses, and arbitrary headers are unsupported. Timeout, header size, and decoded body size are bounded.

HTML is untrusted. The parser executes no JavaScript and loads no resources, requires exactly one match for each privately configured selector, and accepts only a strict non-negative integer and canonical UTC timestamp. Only a validated `SourceObservation` reaches the collector pipeline; raw bodies are not stored, logged, or returned by the API.

Bounded `ETag` and `Last-Modified` values support conditional requests. A `304` changes neither snapshots nor the outbox. Errors, `403`, `429`, `Retry-After`, and repeated `5xx` apply PostgreSQL-managed backoff and circuit breaking that never reduces the minimum interval.
