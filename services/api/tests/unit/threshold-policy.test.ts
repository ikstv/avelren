import { describe, expect, it } from "vitest";

import {
  MAX_SUPPORTED_VEHICLE_COUNT,
  ThresholdPolicy,
} from "../../src/thresholds/threshold-policy.js";

describe("ThresholdPolicy", () => {
  it("uses the first value only as a baseline", () => {
    const policy = new ThresholdPolicy();

    expect(policy.evaluate(null, 150)).toEqual([]);
  });

  it("emits an event when a 50-vehicle threshold is reached", () => {
    const policy = new ThresholdPolicy();

    expect(policy.evaluate(49, 50)).toEqual([
      {
        type: "workload.threshold-crossed",
        threshold: 50,
        previousVehicleCount: 49,
        currentVehicleCount: 50,
      },
    ]);
  });

  it("emits every threshold crossed by a single update", () => {
    const policy = new ThresholdPolicy();

    expect(policy.evaluate(40, 160).map((event) => event.threshold)).toEqual([
      50, 100, 150,
    ]);
  });

  it("does not emit events for unchanged or decreasing values", () => {
    const policy = new ThresholdPolicy();

    expect(policy.evaluate(100, 100)).toEqual([]);
    expect(policy.evaluate(150, 20)).toEqual([]);
  });

  it("rejects invalid steps and vehicle counts", () => {
    expect(() => new ThresholdPolicy(0)).toThrow(RangeError);
    expect(() => new ThresholdPolicy(1.5)).toThrow(RangeError);

    const policy = new ThresholdPolicy();
    expect(() => policy.evaluate(-1, 50)).toThrow(RangeError);
    expect(() => policy.evaluate(0, -1)).toThrow(RangeError);
    expect(() => policy.evaluate(0, MAX_SUPPORTED_VEHICLE_COUNT + 1)).toThrow(
      RangeError,
    );
  });
});
