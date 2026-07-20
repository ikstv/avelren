import type { SourceObservation } from "./source-observation.js";
import type { SnapshotState } from "./snapshot-store.js";
import type { PendingThresholdEvent } from "./threshold-event-store.js";

export interface CollectorMutation {
  state: SnapshotState;
  events: PendingThresholdEvent[];
}

export type CollectorMutationBuilder = (
  current: SnapshotState | null,
) => CollectorMutation | null | Promise<CollectorMutation | null>;

export type ObservationApplyResult = "applied" | "duplicate" | "ignored";

export interface CollectorTransactionStore {
  applyObservation(
    observation: SourceObservation,
    observationId: string,
    buildMutation: CollectorMutationBuilder,
  ): Promise<ObservationApplyResult>;
}
