import { describe, expect, it } from "vitest";
import type { ClaimedNotification, NotificationOutboxStore } from "../../src/push/outbox-store.js";
import { PushProviderError, type PushProvider } from "../../src/push/provider.js";
import { TokenCrypto } from "../../src/push/token-crypto.js";
import { NotificationWorker } from "../../src/push/worker.js";

const crypto = new TokenCrypto({
  activeKeyId: "v1", encryptionKeys: new Map([["v1", Buffer.alloc(32, 1)]]),
  fingerprintKey: Buffer.alloc(32, 2),
});

const item = (attemptCount = 1): ClaimedNotification => {
  const encrypted = crypto.encrypt("device-token-value-123");
  return {
    id: "1", deviceId: "2", attemptCount,
    payload: { schemaVersion: "1", eventId: "a".repeat(64), locationId: "location-1",
      threshold: 50, observedCount: 60, observedAt: "2026-07-20T10:15:30.000Z" },
    ...encrypted,
  };
};

class FakeStore implements NotificationOutboxStore {
  sent = 0; rescheduled = 0; disabled = 0; failed = 0;
  constructor(private readonly items: readonly ClaimedNotification[]) {}
  async claim(): Promise<readonly ClaimedNotification[]> { return this.items; }
  async markSent(): Promise<boolean> { this.sent++; return true; }
  async reschedule(): Promise<boolean> { this.rescheduled++; return true; }
  async markPermanentFailure(): Promise<boolean> { this.failed++; return true; }
  async disableInvalidToken(): Promise<boolean> { this.disabled++; return true; }
}

const options = { owner: "worker-1", batchSize: 10, concurrency: 2, claimTtlMs: 60_000,
  maxAttempts: 3, retryBaseMs: 1_000, retryMaxMs: 10_000, random: () => 0.5 };

describe("NotificationWorker", () => {
  it("marks successful messages sent and never resends within a run", async () => {
    const store = new FakeStore([item()]);
    const provider: PushProvider = { send: async () => ({ messageId: "messages/1" }) };
    await new NotificationWorker(store, provider, crypto, options).runOnce();
    expect(store.sent).toBe(1);
    expect(store.rescheduled).toBe(0);
  });

  it("reschedules transient and rate-limit errors with bounded backoff", async () => {
    for (const kind of ["transient", "rate_limited"] as const) {
      const store = new FakeStore([item()]);
      const provider: PushProvider = { send: async () => { throw new PushProviderError(kind, 2_000); } };
      await new NotificationWorker(store, provider, crypto, options).runOnce();
      expect(store.rescheduled).toBe(1);
    }
  });

  it("atomically disables invalid tokens", async () => {
    const store = new FakeStore([item()]);
    const provider: PushProvider = { send: async () => { throw new PushProviderError("invalid_token"); } };
    await new NotificationWorker(store, provider, crypto, options).runOnce();
    expect(store.disabled).toBe(1);
  });

  it("does not retry permanent or exhausted failures", async () => {
    const store = new FakeStore([item(3)]);
    const provider: PushProvider = { send: async () => { throw new PushProviderError("transient"); } };
    await new NotificationWorker(store, provider, crypto, options).runOnce();
    expect(store.failed).toBe(1);
    expect(store.rescheduled).toBe(0);
  });

  it("coalesces overlapping worker runs", async () => {
    let release!: () => void;
    const deferred = new Promise<Readonly<{ messageId: string }>>((resolve) => {
      release = () => resolve({ messageId: "messages/1" });
    });
    const provider: PushProvider = { send: () => deferred };
    const store = new FakeStore([item()]);
    const worker = new NotificationWorker(store, provider, crypto, options);
    const first = worker.runOnce();
    const second = worker.runOnce();
    expect(second).toBe(first);
    await Promise.resolve();
    release();
    await first;
  });
});
