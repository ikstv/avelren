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
import type {
  CollectorMutation,
  CollectorTransactionStore,
} from "./collector-transaction-store.js";
import { ThresholdPolicy } from "../thresholds/threshold-policy.js";
import {
  type WorkloadSnapshot,
  validateWorkloadSnapshot,
} from "../workload/workload.js";

export type Clock = () => Date;

interface CollectorServiceOptions {
  snapshotStore: SnapshotStore;
  thresholdEventStore: ThresholdEventStore;
  transactionStore?: CollectorTransactionStore;
  thresholdPolicy?: ThresholdPolicy;
  clock?: Clock;
}

export type SourceCollectorInput = SourceObservation;

export class CollectorService {
  private readonly thresholdPolicy: ThresholdPolicy;
  private readonly snapshotStore: SnapshotStore;
  private readonly thresholdEventStore: ThresholdEventStore;
  private readonly transactionStore: CollectorTransactionStore | undefined;
  private readonly clock: Clock;
  private queue: Promise<unknown> = Promise.resolve();

  public constructor({
    snapshotStore,
    thresholdEventStore,
    transactionStore,
    thresholdPolicy = new ThresholdPolicy(),
    clock = () => new Date(),
  }: CollectorServiceOptions) {
    this.thresholdPolicy = thresholdPolicy;
    this.snapshotStore = snapshotStore;
    this.thresholdEventStore = thresholdEventStore;
    this.transactionStore = transactionStore;
    this.clock = clock;
  }

  public async ingest(observation: SourceCollectorInput): Promise<void> {
    await this.withLock(async () => {
      const normalized = normalizeSourceObservation(observation);
      const now = this.clock();
      const observationId = deriveObservationId(normalized);

      if (this.transactionStore !== undefined) {
        await this.transactionStore.applyObservation(
          normalized,
          observationId,
          (current) => this.buildMutation(normalized, observationId, current, now),
        );
        return;
      }

      const current = await this.snapshotStore.get(normalized.locationId);
      const mutation = this.buildMutation(
        normalized,
        observationId,
        current,
        now,
      );
      if (mutation === null) {
        return;
      }

      await this.thresholdEventStore.addPending(mutation.events);
      try {
        await this.snapshotStore.set(mutation.state);
      } catch (error) {
        await this.thresholdEventStore.removePending(
          mutation.events.map((event) => event.eventId),
        );
        throw error;
      }
    });
  }

  private buildMutation(
    normalized: SourceObservation,
    observationId: string,
    current: SnapshotState | null,
    now: Date,
  ): CollectorMutation | null {
    if (current?.latestObservationId === observationId) {
      return null;
    }

    if (
      current !== null &&
      new Date(normalized.observedAt) <= new Date(current.snapshot.observedAt)
    ) {
      return null;
    }

    const thresholdEvents = this.thresholdPolicy.evaluate(
      current?.snapshot.vehicleCount ?? null,
      normalized.vehicleCount,
    );
    const snapshot: WorkloadSnapshot = {
      locationId: normalized.locationId,
      vehicleCount: normalized.vehicleCount,
      observedAt: normalized.observedAt,
      receivedAt: now.toISOString(),
      freshness: "fresh",
      sequence: current === null ? 0 : current.snapshot.sequence + 1,
    };
    validateWorkloadSnapshot(snapshot);

    return {
      state: { snapshot, latestObservationId: observationId },
      events: thresholdEvents.map((event) =>
        normalizeThresholdEventFromSource(
          normalized.locationId,
          event.threshold,
          event.previousVehicleCount,
          event.currentVehicleCount,
          normalized.observedAt,
          now.toISOString(),
        ),
      ),
    };
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
