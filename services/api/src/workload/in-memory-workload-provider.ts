import {
  validateWorkloadSnapshot,
  type WorkloadProvider,
  type WorkloadSnapshot,
} from "./workload.js";

export type Clock = () => Date;

export const DEFAULT_STALE_AFTER_MS = 60_000;

export class MissingWorkloadSnapshotError extends Error {
  public readonly statusCode = 503;
  public readonly code = "snapshot_unavailable";

  public constructor() {
    super("No workload snapshot available yet");
  }
}

interface InMemoryWorkloadProviderOptions {
  clock?: Clock;
  staleAfterMs?: number;
}

export class InMemoryWorkloadProvider implements WorkloadProvider {
  private snapshot: WorkloadSnapshot | null;
  private readonly clock: Clock;
  private readonly staleAfterMs: number;

  public constructor(
    initialSnapshot?: WorkloadSnapshot,
    options: InMemoryWorkloadProviderOptions = {},
  ) {
    this.clock = options.clock ?? (() => new Date());
    this.staleAfterMs = options.staleAfterMs ?? DEFAULT_STALE_AFTER_MS;
    this.snapshot = null;

    if (initialSnapshot !== undefined) {
      validateWorkloadSnapshot(initialSnapshot);
      this.snapshot = { ...initialSnapshot };
    }
  }

  public static demo(clock: Clock = () => new Date()): InMemoryWorkloadProvider {
    const now = clock().toISOString();

    return new InMemoryWorkloadProvider(
      {
      locationId: "demo",
      vehicleCount: 0,
      observedAt: now,
      receivedAt: now,
      freshness: "fresh",
      sequence: 0,
      },
      { clock, staleAfterMs: DEFAULT_STALE_AFTER_MS },
    );
  }

  public async getCurrent(): Promise<WorkloadSnapshot> {
    if (this.snapshot === null) {
      throw new MissingWorkloadSnapshotError();
    }

    const freshness = this.resolveFreshness(this.snapshot.receivedAt);
    return {
      ...this.snapshot,
      freshness,
    };
  }

  public setCurrent(nextSnapshot: WorkloadSnapshot): void {
    validateWorkloadSnapshot(nextSnapshot);
    this.snapshot = { ...nextSnapshot };
  }

  public getLastSnapshot(): WorkloadSnapshot | null {
    return this.snapshot === null ? null : { ...this.snapshot };
  }

  private resolveFreshness(receivedAt: string): "fresh" | "stale" {
    const ageMs = this.clock().getTime() - new Date(receivedAt).getTime();
    return ageMs <= this.staleAfterMs ? "fresh" : "stale";
  }
}
