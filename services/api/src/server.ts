import { InMemoryWorkloadProvider } from "./workload/in-memory-workload-provider.js";
import { buildApp } from "./http/app.js";
import { parseDemoMode } from "./config.js";
import { parseStorageConfig } from "./config.js";
import { Pool } from "pg";
import { runMigrations } from "./storage/migrations.js";
import { PostgresCollectorStore } from "./storage/postgres-collector-store.js";
import { SnapshotWorkloadProvider } from "./workload/snapshot-workload-provider.js";
import type { WorkloadProvider } from "./workload/workload.js";
import { randomUUID } from "node:crypto";
import { parsePushConfig } from "./push/config.js";
import { PostgresDeviceRegistrationService } from "./push/device-registration.js";
import { PostgresNotificationOutboxStore } from "./push/outbox-store.js";
import { FcmHttpV1Provider, GoogleAdcAccessTokenProvider } from "./push/provider.js";
import { TokenCrypto } from "./push/token-crypto.js";
import { NotificationWorker } from "./push/worker.js";
import { createAppAttestationVerifier, parseAppAttestationConfig,
  type AppAttestationVerifier } from "./security/app-attestation.js";
import { CollectorService } from "./collector/collector-service.js";
import { CoordinatedExternalSourceClient } from "./external-source/coordinated-source-client.js";
import { parseExternalSourceConfig } from "./external-source/config.js";
import { ExternalSourceAdapter } from "./external-source/external-source-adapter.js";
import { HtmlObservationParser } from "./external-source/html-observation-parser.js";
import { PostgresExternalSourcePollStateStore } from "./external-source/postgres-poll-state-store.js";
import { SecureExternalSourceClient } from "./external-source/secure-http-client.js";
import { PostgresCycleLease, PostgresLeaseStore } from "./lease/postgres-lease-store.js";
import { PollingCoordinator } from "./polling/polling-coordinator.js";

const demoMode = parseDemoMode(process.env.AVELREN_DEMO_MODE);
const storageConfig = parseStorageConfig(process.env);
const pushConfig = parsePushConfig(process.env);
const appAttestationConfig = parseAppAttestationConfig(process.env, pushConfig.enabled);
const externalSourceConfig = parseExternalSourceConfig(process.env);
if (demoMode && storageConfig.mode === "postgres") {
  throw new Error("AVELREN_DEMO_MODE cannot be used with PostgreSQL storage");
}
if (pushConfig.enabled && storageConfig.mode !== "postgres") {
  throw new Error("Push requires PostgreSQL storage");
}
if (externalSourceConfig.enabled && storageConfig.mode !== "postgres") {
  throw new Error("External source collection requires PostgreSQL storage");
}

let pool: Pool | undefined;
let workloadProvider: WorkloadProvider;
let pushRegistrationService: PostgresDeviceRegistrationService | undefined;
let notificationWorker: NotificationWorker | undefined;
let appAttestationVerifier: AppAttestationVerifier | undefined;
let collectorCoordinator: PollingCoordinator<void> | undefined;
if (pushConfig.enabled) {
  appAttestationVerifier = createAppAttestationVerifier(appAttestationConfig);
}
if (storageConfig.mode === "postgres") {
  pool = new Pool({ connectionString: storageConfig.databaseUrl });
  try {
    await runMigrations(pool);
  } catch (error) {
    await pool.end();
    throw error;
  }
  const collectorStore = new PostgresCollectorStore(pool);
  workloadProvider = new SnapshotWorkloadProvider({ snapshotStore: collectorStore });
  if (externalSourceConfig.enabled) {
    const sourceOwner = process.env.AVELREN_INSTANCE_ID ?? randomUUID();
    const sourceClient = new SecureExternalSourceClient({
      url: requiredExternal(externalSourceConfig.url),
      allowedHost: requiredExternal(externalSourceConfig.allowedHost),
      timeoutMs: externalSourceConfig.timeoutMs,
      maxResponseBytes: externalSourceConfig.maxResponseBytes,
      maxHeaderBytes: externalSourceConfig.maxHeaderBytes,
      maxRetryAfterMs: externalSourceConfig.maxRetryAfterMs,
    });
    const parser = new HtmlObservationParser({
      locationId: requiredExternal(externalSourceConfig.locationId),
      countSelector: requiredExternal(externalSourceConfig.countSelector),
      ...(externalSourceConfig.observedAtSelector === undefined ? {} : {
        observedAtSelector: externalSourceConfig.observedAtSelector,
      }),
    });
    const pollingClient = new CoordinatedExternalSourceClient(
      new ExternalSourceAdapter(sourceClient, parser),
      new CollectorService({ snapshotStore: collectorStore, thresholdEventStore: collectorStore, transactionStore: collectorStore }),
      new PostgresExternalSourcePollStateStore(pool),
      {
        reservation: {
          sourceKey: "primary", ownerId: sourceOwner,
          minimumIntervalMs: externalSourceConfig.pollIntervalMs,
          claimTtlMs: externalSourceConfig.claimTtlMs,
        },
        failurePolicy: {
          minimumIntervalMs: externalSourceConfig.pollIntervalMs,
          backoffBaseMs: externalSourceConfig.backoffBaseMs,
          backoffMaxMs: externalSourceConfig.backoffMaxMs,
          circuitFailures: externalSourceConfig.circuitFailures,
          circuitOpenMs: externalSourceConfig.circuitOpenMs,
        },
      },
    );
    collectorCoordinator = new PollingCoordinator({
      sourceClient: pollingClient,
      intervalMs: externalSourceConfig.pollIntervalMs,
      onValue: () => undefined,
      onError: () => undefined,
      cycleLease: new PostgresCycleLease({
        store: new PostgresLeaseStore(pool),
        leaseKey: "collector:external-source", ownerId: sourceOwner,
        ttlMs: parseLeaseTtlMs(process.env.COLLECTOR_LEASE_TTL_SECONDS),
      }),
    });
  }
  if (pushConfig.enabled) {
    if (!pushConfig.keyring || !pushConfig.projectId) {
      throw new Error("Push configuration is incomplete");
    }
    const tokenCrypto = new TokenCrypto(pushConfig.keyring);
    pushRegistrationService = new PostgresDeviceRegistrationService(pool, tokenCrypto);
    notificationWorker = new NotificationWorker(
      new PostgresNotificationOutboxStore(pool),
      new FcmHttpV1Provider(
        pushConfig.projectId,
        new GoogleAdcAccessTokenProvider(),
        pushConfig.providerTimeoutMs,
      ),
      tokenCrypto,
      {
        owner: process.env.AVELREN_INSTANCE_ID ?? randomUUID(),
        batchSize: pushConfig.batchSize,
        concurrency: pushConfig.concurrency,
        claimTtlMs: pushConfig.claimTtlMs,
        maxAttempts: pushConfig.maxAttempts,
        retryBaseMs: pushConfig.retryBaseMs,
        retryMaxMs: pushConfig.retryMaxMs,
      },
    );
  }
} else {
  workloadProvider = demoMode
    ? InMemoryWorkloadProvider.demo()
    : new InMemoryWorkloadProvider();
}

const app = buildApp({
  logger: true,
  workloadProvider,
  ...(pushRegistrationService ? { pushRegistrationService } : {}),
  ...(appAttestationVerifier ? { appAttestationVerifier } : {}),
});
let workerTimer: NodeJS.Timeout | undefined;
if (notificationWorker) {
  const worker = notificationWorker;
  workerTimer = setInterval(() => {
    void worker.runOnce().catch(() => {
      app.log.error({ code: "push_worker_failed" }, "Push worker cycle failed");
    });
  }, pushConfig.workerIntervalMs);
  workerTimer.unref();
  void worker.runOnce().catch(() => {
    app.log.error({ code: "push_worker_failed" }, "Push worker cycle failed");
  });
}
if (pool !== undefined) {
  const databasePool = pool;
  app.addHook("onClose", async () => {
    if (workerTimer) clearInterval(workerTimer);
    await collectorCoordinator?.stop();
    await notificationWorker?.stop();
    await databasePool.end();
  });
}
const port = parsePort(process.env.PORT);
const host = process.env.HOST ?? "0.0.0.0";

await app.listen({ host, port });
collectorCoordinator?.start();

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

function parseLeaseTtlMs(value: string | undefined): number {
  const seconds = value === undefined ? 120 : Number(value);
  if (!Number.isSafeInteger(seconds) || seconds < 60 || seconds > 86_400) {
    throw new Error("Collector lease configuration is invalid");
  }
  return seconds * 1_000;
}

function requiredExternal<T>(value: T | undefined): T {
  if (value === undefined) throw new Error("External source configuration is invalid");
  return value;
}
