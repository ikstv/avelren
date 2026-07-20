import { buildApp } from "./http/app.js";

const app = buildApp({ logger: true });
const port = parsePort(process.env.PORT);
const host = process.env.HOST ?? "0.0.0.0";

await app.listen({ host, port });

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    void app.close().finally(() => {
      process.exit(0);
    });
  });
}

function parsePort(value: string | undefined): number {
  if (value === undefined) {
    return 3_000;
  }

  const port = Number(value);

  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new RangeError("PORT must be an integer between 1 and 65535");
  }

  return port;
}
