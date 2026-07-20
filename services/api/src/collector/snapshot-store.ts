import {
  validateWorkloadSnapshot,
  type WorkloadSnapshot,
} from "../workload/workload.js";

export interface SnapshotState {
  snapshot: WorkloadSnapshot;
  latestObservationId: string | null;
}

export interface SnapshotStore {
  get(locationId: string): Promise<SnapshotState | null>;
  getLatest(): Promise<SnapshotState | null>;
  set(state: SnapshotState): Promise<void>;
}

export class InMemorySnapshotStore implements SnapshotStore {
  private readonly states = new Map<string, SnapshotState>();
  private queue: Promise<unknown> = Promise.resolve();

  public async get(locationId: string): Promise<SnapshotState | null> {
    return await this.withLock(async () => {
      const current = this.states.get(locationId);
      if (current === undefined) {
        return null;
      }

      return cloneState(current);
    });
  }

  public async getLatest(): Promise<SnapshotState | null> {
    return await this.withLock(async () => {
      let latest: SnapshotState | null = null;

      for (const state of this.states.values()) {
        if (
          latest === null ||
          state.snapshot.receivedAt > latest.snapshot.receivedAt ||
          (state.snapshot.receivedAt === latest.snapshot.receivedAt &&
            state.snapshot.sequence > latest.snapshot.sequence)
        ) {
          latest = state;
        }
      }

      return latest === null ? null : cloneState(latest);
    });
  }

  public async set(state: SnapshotState): Promise<void> {
    validateSnapshotState(state);

    await this.withLock(async () => {
      const current = this.states.get(state.snapshot.locationId);
      if (
        current !== undefined &&
        state.snapshot.sequence <= current.snapshot.sequence
      ) {
        throw new Error("snapshot sequence must be strictly monotonic");
      }

      this.states.set(state.snapshot.locationId, cloneState(state));
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

function validateSnapshotState(state: SnapshotState): void {
  validateWorkloadSnapshot(state.snapshot);

  if (
    state.snapshot.sequence < 0 ||
    !Number.isSafeInteger(state.snapshot.sequence)
  ) {
    throw new TypeError("sequence must be a non-negative safe integer");
  }
}

function cloneState(state: SnapshotState): SnapshotState {
  return {
    snapshot: { ...state.snapshot },
    latestObservationId: state.latestObservationId,
  };
}
