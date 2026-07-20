import type { SnapshotStore } from "../collector/snapshot-store.js";
import {
  DEFAULT_STALE_AFTER_MS,
  MissingWorkloadSnapshotError,
  type Clock,
} from "./in-memory-workload-provider.js";
import type { WorkloadProvider, WorkloadSnapshot } from "./workload.js";

export interface SnapshotWorkloadProviderOptions {
  snapshotStore: SnapshotStore;
  clock?: Clock;
  staleAfterMs?: number;
}

export class SnapshotWorkloadProvider implements WorkloadProvider {
  private readonly snapshotStore: SnapshotStore;
  private readonly clock: Clock;
  private readonly staleAfterMs: number;

  public constructor({
    snapshotStore,
    clock = () => new Date(),
    staleAfterMs = DEFAULT_STALE_AFTER_MS,
  }: SnapshotWorkloadProviderOptions) {
    this.snapshotStore = snapshotStore;
    this.clock = clock;
    this.staleAfterMs = staleAfterMs;
  }

  public async getCurrent(): Promise<WorkloadSnapshot> {
    const state = await this.snapshotStore.getLatest();

    if (state === null) {
      throw new MissingWorkloadSnapshotError();
    }

    return {
      ...state.snapshot,
      freshness: this.resolveFreshness(state.snapshot.receivedAt),
    };
  }

  private resolveFreshness(receivedAt: string): "fresh" | "stale" {
    const ageMs = this.clock().getTime() - new Date(receivedAt).getTime();
    return ageMs <= this.staleAfterMs ? "fresh" : "stale";
  }
}
