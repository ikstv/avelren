import {
  validateWorkloadSnapshot,
  type WorkloadProvider,
  type WorkloadSnapshot,
} from "./workload.js";

export type Clock = () => Date;

export class InMemoryWorkloadProvider implements WorkloadProvider {
  private snapshot: WorkloadSnapshot;

  public constructor(initialSnapshot: WorkloadSnapshot) {
    validateWorkloadSnapshot(initialSnapshot);
    this.snapshot = { ...initialSnapshot };
  }

  public static demo(clock: Clock = () => new Date()): InMemoryWorkloadProvider {
    const now = clock().toISOString();

    return new InMemoryWorkloadProvider({
      locationId: "demo",
      vehicleCount: 0,
      observedAt: now,
      receivedAt: now,
      freshness: "unknown",
      sequence: 0,
    });
  }

  public async getCurrent(): Promise<WorkloadSnapshot> {
    return { ...this.snapshot };
  }

  public update(nextSnapshot: WorkloadSnapshot): void {
    validateWorkloadSnapshot(nextSnapshot);
    this.snapshot = { ...nextSnapshot };
  }
}
