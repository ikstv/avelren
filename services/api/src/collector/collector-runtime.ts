import { PollingCoordinator } from "../polling/polling-coordinator.js";
import { MINIMUM_POLL_INTERVAL_MS } from "../polling/polling-coordinator.js";
import type { SourceClient } from "../polling/source-client.js";
import { ThresholdPolicy } from "../thresholds/threshold-policy.js";
import type { ThresholdEventStore } from "./threshold-event-store.js";
import type { SnapshotStore } from "./snapshot-store.js";
import { CollectorService } from "./collector-service.js";
import type { SourceCollectorInput } from "./collector-service.js";
import type { CollectorTransactionStore } from "./collector-transaction-store.js";
import type { CycleLease } from "../lease/cycle-lease.js";

export interface CollectorRuntimeOptions {
  sourceClient: SourceClient<SourceCollectorInput>;
  snapshotStore: SnapshotStore;
  thresholdEventStore: ThresholdEventStore;
  intervalMs?: number;
  thresholdPolicy?: ThresholdPolicy;
  clock?: () => Date;
  transactionStore?: CollectorTransactionStore;
  cycleLease?: CycleLease;
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
  transactionStore,
  cycleLease,
}: CollectorRuntimeOptions): CollectorRuntime {
  const collectorOptions = {
    snapshotStore,
    thresholdEventStore,
  };
  const collectorService = new CollectorService({
    ...collectorOptions,
    ...(thresholdPolicy === undefined ? {} : { thresholdPolicy }),
    ...(clock === undefined ? {} : { clock }),
    ...(transactionStore === undefined ? {} : { transactionStore }),
  });

  const coordinator = new PollingCoordinator<SourceCollectorInput>({
    sourceClient,
    intervalMs,
    onValue: (observation) => collectorService.ingest(observation),
    ...(cycleLease === undefined ? {} : { cycleLease }),
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
