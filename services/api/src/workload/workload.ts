export const WORKLOAD_FRESHNESS_VALUES = ["fresh", "stale", "unknown"] as const;
export const MAX_VEHICLE_COUNT = 1_000_000;

export type WorkloadFreshness = (typeof WORKLOAD_FRESHNESS_VALUES)[number];

export interface WorkloadSnapshot {
  locationId: string;
  vehicleCount: number;
  observedAt: string;
  receivedAt: string;
  freshness: WorkloadFreshness;
  sequence: number;
}

export interface WorkloadProvider {
  getCurrent(): Promise<WorkloadSnapshot>;
}

export function validateWorkloadSnapshot(snapshot: WorkloadSnapshot): void {
  if (snapshot.locationId.trim().length === 0) {
    throw new TypeError("locationId must not be empty");
  }
  if (snapshot.locationId.length > 128) {
    throw new TypeError("locationId must not exceed 128 characters");
  }

  assertNonNegativeSafeInteger(snapshot.vehicleCount, "vehicleCount");
  if (snapshot.vehicleCount > MAX_VEHICLE_COUNT) {
    throw new TypeError(`vehicleCount must not exceed ${MAX_VEHICLE_COUNT}`);
  }
  assertIsoTimestamp(snapshot.observedAt, "observedAt");
  assertIsoTimestamp(snapshot.receivedAt, "receivedAt");
  assertNonNegativeSafeInteger(snapshot.sequence, "sequence");

  if (!WORKLOAD_FRESHNESS_VALUES.includes(snapshot.freshness)) {
    throw new TypeError("freshness is invalid");
  }
}

function assertNonNegativeSafeInteger(value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new TypeError(`${field} must be a non-negative safe integer`);
  }
}

function assertIsoTimestamp(value: string, field: string): void {
  const parsed = new Date(value);

  if (Number.isNaN(parsed.valueOf()) || parsed.toISOString() !== value) {
    throw new TypeError(`${field} must be an ISO 8601 UTC timestamp`);
  }
}
