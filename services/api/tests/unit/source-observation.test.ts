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
  it("accepts an exact valid object", () => {
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

  it("rejects an extra string field", () => {
    expect(() =>
      normalizeSourceObservation({ ...observation, sourceName: "external" }),
    ).toThrow(TypeError);
  });

  it("rejects an extra field with undefined value", () => {
    expect(() =>
      normalizeSourceObservation({ ...observation, unexpected: undefined }),
    ).toThrow(TypeError);
  });

  it("rejects an extra non-enumerable field", () => {
    const input = { ...observation };
    Object.defineProperty(input, "hidden", {
      value: "secret",
      enumerable: false,
    });

    expect(() => normalizeSourceObservation(input)).toThrow(TypeError);
  });

  it("rejects a symbol field", () => {
    const marker = Symbol("marker");
    const input = { ...observation, [marker]: true };

    expect(() => normalizeSourceObservation(input)).toThrow(TypeError);
  });

  it("rejects accessor fields without executing getters", () => {
    let getterCalls = 0;
    const input = {
      vehicleCount: observation.vehicleCount,
      observedAt: observation.observedAt,
    };
    Object.defineProperty(input, "locationId", {
      enumerable: true,
      get() {
        getterCalls += 1;
        return observation.locationId;
      },
    });

    expect(() => normalizeSourceObservation(input)).toThrow(TypeError);
    expect(getterCalls).toBe(0);
  });

  it("rejects objects with non-standard prototypes", () => {
    class ObservationPayload {
      public locationId = observation.locationId;
      public vehicleCount = observation.vehicleCount;
      public observedAt = observation.observedAt;
    }

    expect(() => normalizeSourceObservation(new ObservationPayload())).toThrow(
      TypeError,
    );
  });

  it("rejects missing required fields", () => {
    expect(() =>
      normalizeSourceObservation({
        locationId: observation.locationId,
        vehicleCount: observation.vehicleCount,
      }),
    ).toThrow(TypeError);
  });

  it("rejects computed observationId in the input payload", () => {
    expect(() =>
      normalizeSourceObservation({
        ...observation,
        observationId: "0".repeat(64),
      }),
    ).toThrow(TypeError);
  });

  it("does not disclose payload values in validation errors", () => {
    const sensitiveValue = "secret-source-document";

    expect(() =>
      normalizeSourceObservation({
        ...observation,
        sourceName: sensitiveValue,
      }),
    ).toThrow(/^(?!.*secret-source-document).*$/u);
  });

  it.each([null, [], "payload", 7, true])(
    "rejects non-object payloads: %s",
    (payload) => {
      expect(() => normalizeSourceObservation(payload)).toThrow(TypeError);
    },
  );

  it("derives a stable SHA-256 observationId", () => {
    expect(deriveObservationId(observation)).toBe(
      deriveObservationId({ ...observation }),
    );
    expect(deriveObservationId(observation)).toMatch(/^[0-9a-f]{64}$/u);
  });
});
