import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Pool } from "pg";
import { runMigrations } from "../../src/storage/migrations.js";
import { PostgresDeviceRegistrationService } from "../../src/push/device-registration.js";
import { PostgresNotificationOutboxStore } from "../../src/push/outbox-store.js";
import { TokenCrypto } from "../../src/push/token-crypto.js";

const databaseUrl = process.env.TEST_DATABASE_URL ?? process.env.DATABASE_URL;
const integration = databaseUrl ? describe : describe.skip;

integration("PostgreSQL notification outbox", () => {
  const pool = new Pool({ connectionString: databaseUrl });
  const crypto = new TokenCrypto({
    activeKeyId: "test-v1",
    encryptionKeys: new Map([["test-v1", Buffer.alloc(32, 11)]]),
    fingerprintKey: Buffer.alloc(32, 12),
  });
  const registrations = new PostgresDeviceRegistrationService(pool, crypto);
  const locationId = `push-test-${process.pid}`;
  const eventId = "b".repeat(56) + process.pid.toString(16).padStart(8, "0").slice(-8);
  const installationId = `integration_installation_${process.pid}_000000`;

  beforeAll(async () => {
    await runMigrations(pool);
    await registrations.register({
      installationId,
      token: `integration-token-${process.pid}-1234567890`,
      platform: "android",
      locale: "uk-UA",
    });
  });

  afterAll(async () => {
    await pool.query("DELETE FROM threshold_events WHERE event_id = $1", [eventId]);
    await pool.query("DELETE FROM push_devices WHERE installation_id LIKE $1", [`integration_installation_${process.pid}%`]);
    await pool.end();
  });

  it("creates one deduplicated outbox row in the threshold event transaction", async () => {
    await pool.query(
      `INSERT INTO threshold_events (
         event_id, location_id, threshold_value, previous_vehicle_count,
         current_vehicle_count, observed_at, created_at, status
       ) VALUES ($1, $2, 50, 49, 50, clock_timestamp(), clock_timestamp(), 'pending')
       ON CONFLICT (event_id) DO NOTHING`, [eventId, locationId],
    );
    const result = await pool.query<{ count: string }>(
      "SELECT COUNT(*)::text AS count FROM notification_outbox WHERE threshold_event_id = $1", [eventId],
    );
    expect(result.rows[0]?.count).toBe("1");
  });

  it("retries initial registration idempotently for the same token", async () => {
    const retried = await registrations.register({
      installationId,
      token: `integration-token-${process.pid}-1234567890`,
      platform: "android",
      locale: "uk-UA",
    });
    expect(retried.installationCredential).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const rows = await pool.query<{ count: string }>(
      "SELECT COUNT(*)::text AS count FROM push_devices WHERE installation_id = $1",
      [installationId],
    );
    expect(rows.rows[0]?.count).toBe("1");
  });

  it("allows only one concurrent worker to claim the row", async () => {
    const first = new PostgresNotificationOutboxStore(pool);
    const second = new PostgresNotificationOutboxStore(pool);
    const [left, right] = await Promise.all([
      first.claim("owner-a", 1, 60_000), second.claim("owner-b", 1, 60_000),
    ]);
    expect(left.length + right.length).toBe(1);
    const claimed = left[0] ?? right[0];
    expect(claimed).toBeDefined();
    if (claimed) {
      const wrongOwner = await first.markSent(claimed.id, "not-owner", "messages/wrong");
      expect(wrongOwner).toBe(false);
      await first.reschedule(claimed.id, left.length ? "owner-a" : "owner-b", 0, "test_retry");
    }
  });

  it("does not enqueue an old event for a later registration", async () => {
    const before = await pool.query<{ count: string }>(
      "SELECT COUNT(*)::text AS count FROM notification_outbox WHERE threshold_event_id = $1", [eventId],
    );
    await registrations.register({
      installationId: `integration_installation_${process.pid}_later000`,
      token: `integration-token-later-${process.pid}-1234567890`,
      platform: "android",
      locale: "en-US",
    });
    const after = await pool.query<{ count: string }>(
      "SELECT COUNT(*)::text AS count FROM notification_outbox WHERE threshold_event_id = $1", [eventId],
    );
    expect(after.rows[0]?.count).toBe(before.rows[0]?.count);
  });
});
