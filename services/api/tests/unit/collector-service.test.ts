import { describe, expect, it } from "vitest";

import { CollectorService } from "../../src/collector/collector-service.js";
import { InMemorySnapshotStore } from "../../src/collector/snapshot-store.js";
import {
  deriveThresholdEventId,
  InMemoryThresholdEventStore,
  type PendingThresholdEvent,
  type ThresholdEventStore,
} from "../../src/collector/threshold-event-store.js";

const baseline = {
  locationId: "loc-1",
  vehicleCount: 40,
  observedAt: "2026-07-20T08:00:00.000Z",
};

function buildCollector(clock = () => new Date("2026-07-20T08:00:05.000Z")) {
  const snapshotStore = new InMemorySnapshotStore();
  const eventStore = new InMemoryThresholdEventStore();
  const collector = new CollectorService({
    snapshotStore,
    thresholdEventStore: eventStore,
    clock,
  });

  return { collector, snapshotStore, eventStore };
}

describe("CollectorService", () => {
  it("stores the first observation as baseline without events", async () => {
    const { collector, snapshotStore, eventStore } = buildCollector();

    await collector.ingest(baseline);

    const state = await snapshotStore.get("loc-1");
    expect(state?.snapshot.vehicleCount).toBe(40);
    expect(state?.snapshot.sequence).toBe(0);
    expect(state?.latestObservationId).toMatch(/^[0-9a-f]{64}$/u);
    expect(await eventStore.getAllPending()).toEqual([]);
  });

  it("emits a threshold event for 49 -> 50", async () => {
    const { collector, eventStore } = buildCollector();

    await collector.ingest({ ...baseline, vehicleCount: 49 });
    await collector.ingest({
      ...baseline,
      vehicleCount: 50,
      observedAt: "2026-07-20T08:01:00.000Z",
    });

    const events = await eventStore.getAllPending();
    expect(events).toMatchObject([
      {
        locationId: "loc-1",
        threshold: 50,
        previousVehicleCount: 49,
        currentVehicleCount: 50,
        observedAt: "2026-07-20T08:01:00.000Z",
        createdAt: "2026-07-20T08:00:05.000Z",
        status: "pending",
      },
    ]);
  });

  it("emits every crossed threshold for 40 -> 160", async () => {
    const { collector, eventStore } = buildCollector();

    await collector.ingest(baseline);
    await collector.ingest({
      ...baseline,
      vehicleCount: 160,
      observedAt: "2026-07-20T08:01:00.000Z",
    });

    const events = await eventStore.getAllPending();
    expect(events.map((event) => event.threshold)).toEqual([50, 100, 150]);
  });

  it("does not emit events for unchanged or decreasing values", async () => {
    const { collector, eventStore } = buildCollector();

    await collector.ingest({ ...baseline, vehicleCount: 100 });
    await collector.ingest({
      ...baseline,
      vehicleCount: 100,
      observedAt: "2026-07-20T08:01:00.000Z",
    });
    await collector.ingest({
      ...baseline,
      vehicleCount: 80,
      observedAt: "2026-07-20T08:02:00.000Z",
    });

    expect(await eventStore.getAllPending()).toEqual([]);
  });

  it("ignores duplicate observations by deterministic observationId", async () => {
    const { collector, snapshotStore, eventStore } = buildCollector();

    await collector.ingest(baseline);
    await collector.ingest(baseline);

    const state = await snapshotStore.get("loc-1");
    expect(state?.snapshot.sequence).toBe(0);
    expect(await eventStore.getAllPending()).toEqual([]);
  });

  it("ignores out-of-order observations", async () => {
    const { collector, snapshotStore, eventStore } = buildCollector();

    await collector.ingest({
      ...baseline,
      vehicleCount: 100,
      observedAt: "2026-07-20T08:02:00.000Z",
    });
    await collector.ingest({
      ...baseline,
      vehicleCount: 160,
      observedAt: "2026-07-20T08:01:00.000Z",
    });

    const state = await snapshotStore.get("loc-1");
    expect(state?.snapshot.vehicleCount).toBe(100);
    expect(await eventStore.getAllPending()).toEqual([]);
  });

  it("keeps eventId stable and deduplicates repeated adds", async () => {
    const { collector, eventStore } = buildCollector();

    await collector.ingest({ ...baseline, vehicleCount: 49 });
    await collector.ingest({
      ...baseline,
      vehicleCount: 50,
      observedAt: "2026-07-20T08:01:00.000Z",
    });

    const [event] = await eventStore.getAllPending();
    if (event === undefined) {
      throw new Error("Expected threshold event");
    }
    const expectedId = deriveThresholdEventId({
      locationId: event.locationId,
      threshold: event.threshold,
      previousVehicleCount: event.previousVehicleCount,
      currentVehicleCount: event.currentVehicleCount,
      observedAt: event.observedAt,
      createdAt: event.createdAt,
    });
    await eventStore.addPending([event]);

    expect(event.eventId).toBe(expectedId);
    expect(await eventStore.getAllPending()).toHaveLength(1);
  });

  it("does not leave partial state when the outbox write fails", async () => {
    class FailingEventStore implements ThresholdEventStore {
      public async addPending(_events: PendingThresholdEvent[]): Promise<void> {
        throw new Error("outbox unavailable");
      }

      public async getAllPending(): Promise<PendingThresholdEvent[]> {
        return [];
      }

      public async removePending(_eventIds: string[]): Promise<void> {
        return undefined;
      }
    }

    const snapshotStore = new InMemorySnapshotStore();
    const collector = new CollectorService({
      snapshotStore,
      thresholdEventStore: new FailingEventStore(),
    });

    await expect(collector.ingest(baseline)).rejects.toThrow("outbox unavailable");
    expect(await snapshotStore.get("loc-1")).toBeNull();
  });

  it("serializes concurrent ingests for one location", async () => {
    const { collector, snapshotStore } = buildCollector();

    await Promise.all([
      collector.ingest(baseline),
      collector.ingest({
        ...baseline,
        vehicleCount: 80,
        observedAt: "2026-07-20T08:01:00.000Z",
      }),
      collector.ingest({
        ...baseline,
        vehicleCount: 160,
        observedAt: "2026-07-20T08:02:00.000Z",
      }),
    ]);

    const state = await snapshotStore.get("loc-1");
    expect(state?.snapshot.vehicleCount).toBe(160);
    expect(state?.snapshot.sequence).toBe(2);
  });
});
