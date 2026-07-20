import { describe, expect, it } from "vitest";

import {
  deriveObservationId,
  normalizeSourceObservation,
} from "../../src/collector/source-observation.js";

const observation = {
  locationId: "loc-1",
  vehicleCount: 42,
  observedAt: "2026-07-20T08:00:00.000Z",
};

describe("SourceObservation", () => {
  it("normalizes and validates fields", () => {
    expect(
      normalizeSourceObservation({
        ...observation,
        locationId: " loc-1 ",
      }),
    ).toEqual(observation);
  });

  it("rejects invalid values", () => {
    expect(() =>
      normalizeSourceObservation({ ...observation, locationId: " " }),
    ).toThrow(TypeError);
    expect(() =>
      normalizeSourceObservation({ ...observation, vehicleCount: -1 }),
    ).toThrow(TypeError);
    expect(() =>
      normalizeSourceObservation({
        ...observation,
        observedAt: "2026-07-20T08:00:00Z",
      }),
    ).toThrow(TypeError);
  });

  it("derives a stable SHA-256 observationId", () => {
    expect(deriveObservationId(observation)).toBe(
      deriveObservationId({ ...observation }),
    );
    expect(deriveObservationId(observation)).toMatch(/^[0-9a-f]{64}$/u);
  });
});
