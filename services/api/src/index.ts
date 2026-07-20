export { buildApp, type BuildAppOptions } from "./http/app.js";
export { parseDemoMode } from "./config.js";
export {
  MINIMUM_POLL_INTERVAL_MS,
  PollingCoordinator,
  validatePollInterval,
  type PollingCoordinatorOptions,
  type PollingScheduler,
} from "./polling/polling-coordinator.js";
export type { SourceClient } from "./polling/source-client.js";
export {
  DEFAULT_THRESHOLD_STEP,
  MAX_SUPPORTED_VEHICLE_COUNT,
  ThresholdPolicy,
  type ThresholdCrossedEvent,
} from "./thresholds/threshold-policy.js";
export {
  InMemoryWorkloadProvider,
  type Clock,
} from "./workload/in-memory-workload-provider.js";
export {
  SnapshotWorkloadProvider,
  type SnapshotWorkloadProviderOptions,
} from "./workload/snapshot-workload-provider.js";
export {
  InMemorySnapshotStore,
  type SnapshotState,
  type SnapshotStore,
} from "./collector/snapshot-store.js";
export { InMemoryThresholdEventStore } from "./collector/threshold-event-store.js";
export { CollectorService, type SourceCollectorInput } from "./collector/collector-service.js";
export {
  createCollectorRuntime,
  type CollectorRuntime,
  type CollectorRuntimeOptions,
} from "./collector/collector-runtime.js";
export {
  MAX_VEHICLE_COUNT,
  WORKLOAD_FRESHNESS_VALUES,
  validateWorkloadSnapshot,
  type WorkloadFreshness,
  type WorkloadProvider,
  type WorkloadSnapshot,
} from "./workload/workload.js";
