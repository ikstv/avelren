import { Pool } from "pg";
import { afterAll, describe, expect, it } from "vitest";

import { CollectorService } from "../../src/collector/collector-service.js";
import { PostgresLeaseStore } from "../../src/lease/postgres-lease-store.js";
import { runMigrations } from "../../src/storage/migrations.js";
import { PostgresCollectorStore } from "../../src/storage/postgres-collector-store.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const testDatabaseUrl =
  databaseUrl ?? "postgresql://unused:unused@postgres.invalid/unused";
const describePostgres =
  databaseUrl === undefined ? describe.skip : describe.sequential;

describePostgres("PostgreSQL durable collector storage", () => {
  const pool = new Pool({ connectionString: testDatabaseUrl });

  afterAll(async () => {
    await pool.end();
  });

  it("applies migrations once across concurrent replicas and is repeatable", async () => {
    await resetTestDatabase(pool);
    const secondPool = new Pool({ connectionString: testDatabaseUrl });
    try {
      await Promise.all([runMigrations(pool), runMigrations(secondPool)]);
      await runMigrations(pool);
      const result = await pool.query(
        "SELECT version FROM avelren_schema_migrations ORDER BY version",
      );
      expect(result.rows).toEqual([{ version: "001" }, { version: "002" }]);
    } finally {
      await secondPool.end();
    }
  });

  it("persists atomic snapshots and events across store instances", async () => {
    await truncateCollectorData(pool);
    const firstStore = new PostgresCollectorStore(pool);
    const collector = new CollectorService({
      snapshotStore: firstStore,
      thresholdEventStore: firstStore,
      transactionStore: firstStore,
      clock: () => new Date("2026-07-20T08:00:05.000Z"),
    });

    await collector.ingest({
      locationId: "durable-location",
      vehicleCount: 40,
      observedAt: "2026-07-20T08:00:00.000Z",
    });
    await collector.ingest({
      locationId: "durable-location",
      vehicleCount: 160,
      observedAt: "2026-07-20T08:01:00.000Z",
    });

    const restartedPool = new Pool({ connectionString: testDatabaseUrl });
    const restartedStore = new PostgresCollectorStore(restartedPool);
    try {
      const state = await restartedStore.get("durable-location");
      expect(state?.snapshot).toMatchObject({ vehicleCount: 160, sequence: 1 });
      expect(
        (await restartedStore.getAllPending()).map((event) => event.threshold),
      ).toEqual([50, 100, 150]);
    } finally {
      await restartedPool.end();
    }
  });

  it("deduplicates observations and threshold events in PostgreSQL", async () => {
    await truncateCollectorData(pool);
    const store = new PostgresCollectorStore(pool);
    const collector = new CollectorService({
      snapshotStore: store,
      thresholdEventStore: store,
      transactionStore: store,
    });
    const baseline = {
      locationId: "dedupe-location",
      vehicleCount: 49,
      observedAt: "2026-07-20T08:00:00.000Z",
    };
    const crossing = {
      ...baseline,
      vehicleCount: 50,
      observedAt: "2026-07-20T08:01:00.000Z",
    };

    await collector.ingest(baseline);
    await collector.ingest(crossing);
    await collector.ingest(crossing);
    const [event] = await store.getAllPending();
    expect(event).toBeDefined();
    if (event !== undefined) {
      await store.addPending([event]);
    }

    expect(await store.getAllPending()).toHaveLength(1);
    const observations = await pool.query(
      "SELECT observation_id FROM collector_observations",
    );
    expect(observations.rowCount).toBe(2);
  });

  it("rolls back all writes and normalizes an event database error", async () => {
    await truncateCollectorData(pool);
    const store = new PostgresCollectorStore(pool);
    const collector = new CollectorService({
      snapshotStore: store,
      thresholdEventStore: store,
      transactionStore: store,
    });
    await collector.ingest({
      locationId: "rollback-location",
      vehicleCount: 40,
      observedAt: "2026-07-20T08:00:00.000Z",
    });
    await pool.query(`CREATE OR REPLACE FUNCTION reject_test_event()
      RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'internal-test-value'; END $$
      LANGUAGE plpgsql`);
    await pool.query(`CREATE TRIGGER reject_test_event_trigger
      BEFORE INSERT ON threshold_events
      FOR EACH ROW EXECUTE FUNCTION reject_test_event()`);

    try {
      let message = "";
      try {
        await collector.ingest({
          locationId: "rollback-location",
          vehicleCount: 160,
          observedAt: "2026-07-20T08:01:00.000Z",
        });
      } catch (error) {
        message = error instanceof Error ? error.message : String(error);
      }
      expect(message).toBe("PostgreSQL storage operation failed");
      expect(message).not.toContain("rollback-location");
      expect(message).not.toContain("internal-test-value");
      const state = await store.get("rollback-location");
      expect(state?.snapshot).toMatchObject({ vehicleCount: 40, sequence: 0 });
      expect(await store.getAllPending()).toEqual([]);
      const observations = await pool.query(
        "SELECT observation_id FROM collector_observations",
      );
      expect(observations.rowCount).toBe(1);
    } finally {
      await pool.query(
        "DROP TRIGGER reject_test_event_trigger ON threshold_events",
      );
      await pool.query("DROP FUNCTION reject_test_event()");
    }
  });

  it("allows one lease owner and rejects foreign renew or release", async () => {
    await truncateCollectorData(pool);
    const leases = new PostgresLeaseStore(pool);
    const [first, second] = await Promise.all([
      leases.tryAcquire({
        leaseKey: "collector:lease-location",
        ownerId: "owner-a",
        ttlMs: 60_000,
      }),
      leases.tryAcquire({
        leaseKey: "collector:lease-location",
        ownerId: "owner-b",
        ttlMs: 60_000,
      }),
    ]);
    const winner = first ?? second;
    const loserId = first === null ? "owner-a" : "owner-b";

    expect([first, second].filter((lease) => lease !== null)).toHaveLength(1);
    expect(winner).not.toBeNull();
    expect(
      await leases.renew({
        leaseKey: "collector:lease-location",
        ownerId: loserId,
        ttlMs: 60_000,
      }),
    ).toBeNull();
    expect(
      await leases.release("collector:lease-location", loserId),
    ).toBe(false);
    if (winner !== null) {
      expect(
        await leases.renew({
          leaseKey: winner.leaseKey,
          ownerId: winner.ownerId,
          ttlMs: 60_000,
        }),
      ).not.toBeNull();
      expect(await leases.release(winner.leaseKey, winner.ownerId)).toBe(true);
    }
  });

  it("reacquires an expired lease using PostgreSQL time", async () => {
    await truncateCollectorData(pool);
    const leases = new PostgresLeaseStore(pool);
    const databaseTime = await pool.query<{ now: Date }>(
      "SELECT clock_timestamp() AS now",
    );
    const first = await leases.tryAcquire({
      leaseKey: "collector:expiry-location",
      ownerId: "owner-a",
      ttlMs: 60_000,
    });
    expect(first).not.toBeNull();
    expect(new Date(first?.expiresAt ?? 0).valueOf()).toBeGreaterThan(
      databaseTime.rows[0]?.now.valueOf() ?? 0,
    );

    await pool.query(
      `UPDATE collector_leases
       SET expires_at = clock_timestamp() - interval '1 second'
       WHERE lease_key = $1`,
      ["collector:expiry-location"],
    );
    const second = await leases.tryAcquire({
      leaseKey: "collector:expiry-location",
      ownerId: "owner-b",
      ttlMs: 60_000,
    });
    expect(second?.ownerId).toBe("owner-b");
  });
});

async function resetTestDatabase(pool: Pool): Promise<void> {
  await pool.query("DROP TABLE IF EXISTS collector_leases");
  await pool.query("DROP TABLE IF EXISTS threshold_events");
  await pool.query("DROP TABLE IF EXISTS collector_snapshots");
  await pool.query("DROP TABLE IF EXISTS collector_observations");
  await pool.query("DROP TABLE IF EXISTS avelren_schema_migrations");
}

async function truncateCollectorData(pool: Pool): Promise<void> {
  await pool.query(
    `TRUNCATE TABLE notification_outbox, push_devices, threshold_events,
                    collector_snapshots, collector_observations, collector_leases`,
  );
}
