import { InMemoryWorkloadProvider } from "./workload/in-memory-workload-provider.js";
import { buildApp } from "./http/app.js";
import { parseDemoMode } from "./config.js";
import { parseStorageConfig } from "./config.js";
import { Pool } from "pg";
import { runMigrations } from "./storage/migrations.js";
import { PostgresCollectorStore } from "./storage/postgres-collector-store.js";
import { SnapshotWorkloadProvider } from "./workload/snapshot-workload-provider.js";
import type { WorkloadProvider } from "./workload/workload.js";

const demoMode = parseDemoMode(process.env.AVELREN_DEMO_MODE);
const storageConfig = parseStorageConfig(process.env);
if (demoMode && storageConfig.mode === "postgres") {
  throw new Error("AVELREN_DEMO_MODE cannot be used with PostgreSQL storage");
}

let pool: Pool | undefined;
let workloadProvider: WorkloadProvider;
if (storageConfig.mode === "postgres") {
  pool = new Pool({ connectionString: storageConfig.databaseUrl });
  try {
    await runMigrations(pool);
  } catch (error) {
    await pool.end();
    throw error;
  }
  workloadProvider = new SnapshotWorkloadProvider({
    snapshotStore: new PostgresCollectorStore(pool),
  });
} else {
  workloadProvider = demoMode
    ? InMemoryWorkloadProvider.demo()
    : new InMemoryWorkloadProvider();
}

const app = buildApp({ logger: true, workloadProvider });
if (pool !== undefined) {
  const databasePool = pool;
  app.addHook("onClose", async () => {
    await databasePool.end();
  });
}
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
