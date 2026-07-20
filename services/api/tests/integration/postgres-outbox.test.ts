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
  const initialToken = `integration-token-${process.pid}-1234567890`;
  let initialCredential = "";

  beforeAll(async () => {
    await runMigrations(pool);
    const result = await registrations.register({
      installationId,
      token: initialToken,
      platform: "android",
      locale: "uk-UA",
    });
    initialCredential = result.installationCredential ?? "";
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

  it("returns the installation credential only for the created row", () => {
    expect(initialCredential).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });

  it("keeps every stored field unchanged on repeated unauthenticated registration", async () => {
    const before = await deviceState(installationId);
    const retried = await registrations.register({
      installationId,
      token: `different-token-${process.pid}-1234567890`,
      platform: "android",
      locale: "en-US",
    });
    expect(retried).toEqual({ status: "registered" });
    expect(await deviceState(installationId)).toEqual(before);
  });

  it("does not transfer a token fingerprint to another installation", async () => {
    const otherId = `integration_installation_${process.pid}_owner000`;
    const otherToken = `integration-token-owner-${process.pid}-1234567890`;
    const created = await registrations.register({
      installationId: otherId, token: otherToken, platform: "android", locale: "uk-UA",
    });
    expect(created.installationCredential).toBeDefined();
    const before = await deviceState(otherId);
    const conflict = await registrations.register({
      installationId: `integration_installation_${process.pid}_attacker`,
      token: otherToken, platform: "android", locale: "en-US",
    });
    expect(conflict).toEqual({ status: "registered" });
    expect(await deviceState(otherId)).toEqual(before);
  });

  it("permits authenticated rotation without changing the credential verifier", async () => {
    const before = await deviceState(installationId);
    await registrations.rotateToken(
      installationId, initialCredential, `rotated-token-${process.pid}-1234567890`,
    );
    const after = await deviceState(installationId);
    expect(after.token_fingerprint).not.toBe(before.token_fingerprint);
    expect(after.credential_salt).toBe(before.credential_salt);
    expect(after.credential_hash).toBe(before.credential_hash);
    await expect(registrations.rotateToken(
      installationId, "x".repeat(43), `rejected-token-${process.pid}-1234567890`,
    )).rejects.toThrow("Installation authentication failed");
    expect(await deviceState(installationId)).toEqual(after);
  });

  it("does not re-enable a disabled installation through initial registration", async () => {
    await registrations.disable(installationId, initialCredential);
    const before = await deviceState(installationId);
    const result = await registrations.register({
      installationId, token: initialToken, platform: "android", locale: "en-US",
    });
    expect(result).toEqual({ status: "registered" });
    expect(await deviceState(installationId)).toEqual(before);
  });

  it("serializes concurrent initial registrations at the database constraints", async () => {
    const concurrentId = `integration_installation_${process.pid}_parallel`;
    const concurrentToken = `integration-token-parallel-${process.pid}-1234567890`;
    const results = await Promise.all(Array.from({ length: 2 }, () => registrations.register({
      installationId: concurrentId, token: concurrentToken, platform: "android", locale: "uk-UA",
    })));
    expect(results.filter((result) => result.installationCredential !== undefined)).toHaveLength(1);
    const rows = await pool.query<{ count: string }>(
      "SELECT COUNT(*)::text AS count FROM push_devices WHERE installation_id = $1", [concurrentId],
    );
    expect(rows.rows[0]?.count).toBe("1");
    const winner = results.find((result) => result.installationCredential)?.installationCredential;
    expect(winner).toBeDefined();
    if (winner) await registrations.heartbeat(concurrentId, winner, "en-US");
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

  async function deviceState(id: string): Promise<Readonly<{
    token_fingerprint: string; credential_salt: string; credential_hash: string;
    platform: string; locale: string; enabled: boolean; disabled_at: string | null;
    disabled_reason: string | null;
  }>> {
    const result = await pool.query(
      `SELECT token_fingerprint, encode(credential_salt, 'hex') AS credential_salt,
        encode(credential_hash, 'hex') AS credential_hash, platform, locale, enabled,
        disabled_at::text, disabled_reason FROM push_devices WHERE installation_id = $1`, [id],
    );
    const row = result.rows[0];
    if (!row) throw new Error("Expected integration device row");
    return row;
  }
});
