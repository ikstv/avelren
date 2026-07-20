import { describe, expect, it } from "vitest";

import {
  MAX_VEHICLE_COUNT,
  validateWorkloadSnapshot,
  type WorkloadSnapshot,
} from "../../src/workload/workload.js";

const validSnapshot: WorkloadSnapshot = {
  locationId: "demo",
  vehicleCount: 125,
  observedAt: "2026-07-20T08:00:00.000Z",
  receivedAt: "2026-07-20T08:00:01.000Z",
  freshness: "fresh",
  sequence: 3,
};

describe("validateWorkloadSnapshot", () => {
  it("accepts the public API contract", () => {
    expect(() => validateWorkloadSnapshot(validSnapshot)).not.toThrow();
  });

  it("rejects values above the supported workload bound", () => {
    expect(() =>
      validateWorkloadSnapshot({
        ...validSnapshot,
        vehicleCount: MAX_VEHICLE_COUNT + 1,
      }),
    ).toThrow(TypeError);
  });

  it("rejects non-canonical timestamps", () => {
    expect(() =>
      validateWorkloadSnapshot({
        ...validSnapshot,
        observedAt: "2026-07-20T08:00:00Z",
      }),
    ).toThrow(TypeError);
  });
});
