export const DEFAULT_THRESHOLD_STEP = 50;
export const MAX_SUPPORTED_VEHICLE_COUNT = 1_000_000;

export interface ThresholdCrossedEvent {
  type: "workload.threshold-crossed";
  threshold: number;
  previousVehicleCount: number;
  currentVehicleCount: number;
}

export class ThresholdPolicy {
  public readonly step: number;

  public constructor(step: number = DEFAULT_THRESHOLD_STEP) {
    assertPositiveSafeInteger(step, "step");
    this.step = step;
  }

  public evaluate(
    previousVehicleCount: number | null,
    currentVehicleCount: number,
  ): ThresholdCrossedEvent[] {
    assertNonNegativeSafeInteger(currentVehicleCount, "currentVehicleCount");

    if (previousVehicleCount === null) {
      return [];
    }

    assertNonNegativeSafeInteger(previousVehicleCount, "previousVehicleCount");

    if (currentVehicleCount <= previousVehicleCount) {
      return [];
    }

    const firstThresholdIndex = Math.floor(previousVehicleCount / this.step) + 1;
    const lastThresholdIndex = Math.floor(currentVehicleCount / this.step);
    const events: ThresholdCrossedEvent[] = [];

    for (let index = firstThresholdIndex; index <= lastThresholdIndex; index += 1) {
      events.push({
        type: "workload.threshold-crossed",
        threshold: index * this.step,
        previousVehicleCount,
        currentVehicleCount,
      });
    }

    return events;
  }
}

function assertPositiveSafeInteger(value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new RangeError(`${field} must be a positive safe integer`);
  }
}

function assertNonNegativeSafeInteger(value: number, field: string): void {
  if (
    !Number.isSafeInteger(value) ||
    value < 0 ||
    value > MAX_SUPPORTED_VEHICLE_COUNT
  ) {
    throw new RangeError(
      `${field} must be an integer between 0 and ${MAX_SUPPORTED_VEHICLE_COUNT}`,
    );
  }
}
