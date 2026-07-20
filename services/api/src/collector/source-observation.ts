import { createHash } from "node:crypto";

import { MAX_VEHICLE_COUNT } from "../workload/workload.js";

export interface SourceObservation {
  locationId: string;
  vehicleCount: number;
  observedAt: string;
}

const MAX_LOCATION_ID_LENGTH = 128;
const SOURCE_OBSERVATION_FIELDS = [
  "locationId",
  "vehicleCount",
  "observedAt",
] as const;

type SourceObservationField = (typeof SOURCE_OBSERVATION_FIELDS)[number];
type SourceObservationInputFields = Record<SourceObservationField, unknown>;

export function normalizeSourceObservation(
  observation: unknown,
): SourceObservation {
  const input = readSourceObservationInputFields(observation);

  if (!isNonEmptyString(input.locationId)) {
    throw new TypeError("locationId must be a non-empty string");
  }

  const locationId = input.locationId.trim();
  if (locationId.length > MAX_LOCATION_ID_LENGTH) {
    throw new TypeError(
      `locationId must not exceed ${MAX_LOCATION_ID_LENGTH} characters`,
    );
  }

  const vehicleCount = input.vehicleCount;
  if (
    typeof vehicleCount !== "number" ||
    !Number.isSafeInteger(vehicleCount) ||
    vehicleCount < 0
  ) {
    throw new TypeError("vehicleCount must be a non-negative safe integer");
  }
  if (vehicleCount > MAX_VEHICLE_COUNT) {
    throw new TypeError(
      `vehicleCount must not exceed ${MAX_VEHICLE_COUNT}`,
    );
  }

  if (!isIsoUtcTimestamp(input.observedAt)) {
    throw new TypeError("observedAt must be an ISO 8601 UTC timestamp");
  }

  return {
    locationId,
    vehicleCount,
    observedAt: input.observedAt,
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

function readSourceObservationInputFields(
  observation: unknown,
): SourceObservationInputFields {
  if (
    typeof observation !== "object" ||
    observation === null ||
    Array.isArray(observation) ||
    Object.getPrototypeOf(observation) !== Object.prototype
  ) {
    throw new TypeError("SourceObservation must be a plain object");
  }

  const ownKeys = Reflect.ownKeys(observation);
  if (ownKeys.length !== SOURCE_OBSERVATION_FIELDS.length) {
    throw new TypeError("SourceObservation has an unexpected field set");
  }

  for (const key of ownKeys) {
    if (
      typeof key !== "string" ||
      !SOURCE_OBSERVATION_FIELDS.includes(key as SourceObservationField)
    ) {
      throw new TypeError("SourceObservation has an unexpected field set");
    }
  }

  return {
    locationId: readJsonDataField(observation, "locationId"),
    vehicleCount: readJsonDataField(observation, "vehicleCount"),
    observedAt: readJsonDataField(observation, "observedAt"),
  };
}

function readJsonDataField(
  observation: object,
  field: SourceObservationField,
): unknown {
  const descriptor = Object.getOwnPropertyDescriptor(observation, field);

  if (
    descriptor === undefined ||
    !descriptor.enumerable ||
    !("value" in descriptor) ||
    descriptor.get !== undefined ||
    descriptor.set !== undefined
  ) {
    throw new TypeError("SourceObservation has an invalid field descriptor");
  }

  return descriptor.value;
}

function isIsoUtcTimestamp(value: unknown): value is string {
  if (!isNonEmptyString(value)) {
    return false;
  }

  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value;
}
