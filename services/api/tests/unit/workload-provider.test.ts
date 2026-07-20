import { describe, expect, it } from "vitest";

import { InMemorySnapshotStore } from "../../src/collector/snapshot-store.js";
import { parseDemoMode } from "../../src/config.js";
import {
  DEFAULT_STALE_AFTER_MS,
  InMemoryWorkloadProvider,
  MissingWorkloadSnapshotError,
} from "../../src/workload/in-memory-workload-provider.js";
import { SnapshotWorkloadProvider } from "../../src/workload/snapshot-workload-provider.js";

const snapshot = {
  locationId: "loc-1",
  vehicleCount: 125,
  observedAt: "2026-07-20T08:00:00.000Z",
  receivedAt: "2026-07-20T08:00:00.000Z",
  freshness: "fresh" as const,
  sequence: 0,
};

describe("WorkloadProvider", () => {
  it("throws 503-compatible error when no snapshot exists", async () => {
    const provider = new InMemoryWorkloadProvider();

    await expect(provider.getCurrent()).rejects.toBeInstanceOf(
      MissingWorkloadSnapshotError,
    );
  });

  it("resolves fresh then stale through an injected clock", async () => {
    let now = new Date("2026-07-20T08:00:30.000Z");
    const store = new InMemorySnapshotStore();
    const provider = new SnapshotWorkloadProvider({
      snapshotStore: store,
      clock: () => now,
      staleAfterMs: DEFAULT_STALE_AFTER_MS,
    });

    await store.set({
      snapshot,
      latestObservationId: "a".repeat(64),
    });

    expect((await provider.getCurrent()).freshness).toBe("fresh");
    now = new Date("2026-07-20T08:02:00.000Z");
    expect((await provider.getCurrent()).freshness).toBe("stale");
  });

  it("enables demo mode only for exact true", () => {
    expect(parseDemoMode(undefined)).toBe(false);
    expect(parseDemoMode("false")).toBe(false);
    expect(parseDemoMode("true")).toBe(true);
    expect(() => parseDemoMode("TRUE")).toThrow(Error);
    expect(() => parseDemoMode("1")).toThrow(Error);
  });
});
