# Avelren Codex instructions

- Build this project from scratch; do not copy code or architecture from paused projects.
- Keep the product name `Avelren`, repository slug `avelren`, and Android package `ua.ikstv.avelren`.
- Do not start Figma or visual-design work until the owner explicitly asks.
- Keep updates short and action-oriented. For each proposed Codex task, recommend an available model by name plus exactly one level: `низький`, `середній`, or `високий`.

## Architecture and safety

- Preserve the boundary: publicly accessible external source → Avelren server → Android.
- Android must never contact, identify, or contain configuration for the publicly accessible external source.
- Server polling must never be configured below 60 seconds. Production collection additionally requires a durable lease across restarts and replicas.
- The server owns threshold calculation. The initial step is 50; the first value is a baseline, and an increase emits every crossed multiple of 50.
- Never commit real source addresses, selectors, credentials, production endpoints, Firebase files, captured responses, or personal data. Use `.invalid` placeholders.
- Public documentation must identify the provider only as `відкрите джерело` in Ukrainian and `publicly accessible external source` in English.

## Changes and verification

- Keep API implementation, OpenAPI, examples, and Android wire models synchronized.
- For server changes, run `npm run typecheck`, `npm test`, `npm run build`, and `npm audit --omit=dev` in `services/api`.
- For Android changes, run `./gradlew test` in `apps/android` when the Android SDK and dependency network are available.
- Every commit and pull request title must be `type(scope): Українська назва / English title`.
- Every commit and pull request body must contain a substantive `UA:` block first and `EN:` block second.
