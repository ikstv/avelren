import { createHash } from "node:crypto";

import { MAX_VEHICLE_COUNT } from "../workload/workload.js";

export interface SourceObservation {
  locationId: string;
  vehicleCount: number;
  observedAt: string;
}

const MAX_LOCATION_ID_LENGTH = 128;

export function normalizeSourceObservation(
  observation: SourceObservation,
): SourceObservation {
  if (!isNonEmptyString(observation.locationId)) {
    throw new TypeError("locationId must be a non-empty string");
  }

  const locationId = observation.locationId.trim();
  if (locationId.length > MAX_LOCATION_ID_LENGTH) {
    throw new TypeError(
      `locationId must not exceed ${MAX_LOCATION_ID_LENGTH} characters`,
    );
  }

  if (
    !Number.isSafeInteger(observation.vehicleCount) ||
    observation.vehicleCount < 0
  ) {
    throw new TypeError("vehicleCount must be a non-negative safe integer");
  }
  if (observation.vehicleCount > MAX_VEHICLE_COUNT) {
    throw new TypeError(
      `vehicleCount must not exceed ${MAX_VEHICLE_COUNT}`,
    );
  }

  if (!isIsoUtcTimestamp(observation.observedAt)) {
    throw new TypeError("observedAt must be an ISO 8601 UTC timestamp");
  }

  return {
    locationId,
    vehicleCount: observation.vehicleCount,
    observedAt: observation.observedAt,
  };
}

export function deriveObservationId(observation: SourceObservation): string {
  const normalized = normalizeSourceObservation(observation);

  return createHash("sha256")
    .update(normalized.locationId)
    .update("|")
    .update(String(normalized.vehicleCount))
    .update("|")
    .update(normalized.observedAt)
    .digest("hex");
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isIsoUtcTimestamp(value: string): boolean {
  if (!isNonEmptyString(value)) {
    return false;
  }

  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
}
