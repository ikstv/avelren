import {
  deriveObservationId,
  normalizeSourceObservation,
  type SourceObservation,
} from "./source-observation.js";
import {
  normalizeThresholdEventFromSource,
  type ThresholdEventStore,
} from "./threshold-event-store.js";
import type { SnapshotState, SnapshotStore } from "./snapshot-store.js";
import { ThresholdPolicy } from "../thresholds/threshold-policy.js";
import {
  type WorkloadSnapshot,
  validateWorkloadSnapshot,
} from "../workload/workload.js";

export type Clock = () => Date;

interface CollectorServiceOptions {
  snapshotStore: SnapshotStore;
  thresholdEventStore: ThresholdEventStore;
  thresholdPolicy?: ThresholdPolicy;
  clock?: Clock;
}

export type SourceCollectorInput = SourceObservation;

export class CollectorService {
  private readonly thresholdPolicy: ThresholdPolicy;
  private readonly snapshotStore: SnapshotStore;
  private readonly thresholdEventStore: ThresholdEventStore;
  private readonly clock: Clock;
  private queue: Promise<unknown> = Promise.resolve();

  public constructor({
    snapshotStore,
    thresholdEventStore,
    thresholdPolicy = new ThresholdPolicy(),
    clock = () => new Date(),
  }: CollectorServiceOptions) {
    this.thresholdPolicy = thresholdPolicy;
    this.snapshotStore = snapshotStore;
    this.thresholdEventStore = thresholdEventStore;
    this.clock = clock;
  }

  public async ingest(observation: SourceCollectorInput): Promise<void> {
    await this.withLock(async () => {
      const normalized = normalizeSourceObservation(observation);
      const current = await this.snapshotStore.get(normalized.locationId);
      const now = this.clock();

      const observationId = deriveObservationId(normalized);
      if (current?.latestObservationId === observationId) {
        return;
      }

      const observedAtDate = new Date(normalized.observedAt);
      if (
        current !== null &&
        observedAtDate <= new Date(current.snapshot.observedAt)
      ) {
        return;
      }

      const previousVehicleCount = current?.snapshot.vehicleCount ?? null;
      const thresholdEvents = this.thresholdPolicy.evaluate(
        previousVehicleCount,
        normalized.vehicleCount,
      );
      const sequence = current === null ? 0 : current.snapshot.sequence + 1;
      const nextSnapshot: WorkloadSnapshot = {
        locationId: normalized.locationId,
        vehicleCount: normalized.vehicleCount,
        observedAt: normalized.observedAt,
        receivedAt: now.toISOString(),
        freshness: "fresh",
        sequence,
      };
      validateWorkloadSnapshot(nextSnapshot);

      const events = thresholdEvents.map((event) =>
        normalizeThresholdEventFromSource(
          normalized.locationId,
          event.threshold,
          event.previousVehicleCount,
          event.currentVehicleCount,
          normalized.observedAt,
          now.toISOString(),
        ),
      );

      await this.thresholdEventStore.addPending(events);
      try {
        const nextState: SnapshotState = {
          snapshot: nextSnapshot,
          latestObservationId: observationId,
        };
        await this.snapshotStore.set(nextState);
      } catch (error) {
        await this.thresholdEventStore.removePending(
          events.map((event) => event.eventId),
        );
        throw error;
      }
    });
  }

  private async withLock<T>(action: () => Promise<T>): Promise<T> {
    const current = this.queue;
    let release: () => void = () => {
      void 0;
    };

    this.queue = new Promise<void>((resolve) => {
      release = resolve;
    });

    await current;
    try {
      return await action();
    } finally {
      release();
    }
  }
}
