import { PollingCoordinator } from "../polling/polling-coordinator.js";
import { MINIMUM_POLL_INTERVAL_MS } from "../polling/polling-coordinator.js";
import type { SourceClient } from "../polling/source-client.js";
import { ThresholdPolicy } from "../thresholds/threshold-policy.js";
import type { ThresholdEventStore } from "./threshold-event-store.js";
import type { SnapshotStore } from "./snapshot-store.js";
import { CollectorService } from "./collector-service.js";
import type { SourceCollectorInput } from "./collector-service.js";

export interface CollectorRuntimeOptions {
  sourceClient: SourceClient<SourceCollectorInput>;
  snapshotStore: SnapshotStore;
  thresholdEventStore: ThresholdEventStore;
  intervalMs?: number;
  thresholdPolicy?: ThresholdPolicy;
  clock?: () => Date;
}

export interface CollectorRuntime {
  start(): void;
  stop(): Promise<void>;
}

export function createCollectorRuntime({
  sourceClient,
  snapshotStore,
  thresholdEventStore,
  intervalMs = MINIMUM_POLL_INTERVAL_MS,
  thresholdPolicy,
  clock,
}: CollectorRuntimeOptions): CollectorRuntime {
  const collectorOptions = {
    snapshotStore,
    thresholdEventStore,
  };
  const collectorService = new CollectorService({
    ...collectorOptions,
    ...(thresholdPolicy === undefined ? {} : { thresholdPolicy }),
    ...(clock === undefined ? {} : { clock }),
  });

  const coordinator = new PollingCoordinator<SourceCollectorInput>({
    sourceClient,
    intervalMs,
    onValue: (observation) => collectorService.ingest(observation),
  });

  return {
    start() {
      coordinator.start();
    },
    stop() {
      return coordinator.stop();
    },
  };
}
