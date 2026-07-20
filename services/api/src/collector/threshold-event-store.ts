import { createHash } from "node:crypto";

import type { SourceObservation } from "./source-observation.js";

export type ThresholdEventStatus = "pending";

export interface PendingThresholdEvent {
  eventId: string;
  locationId: string;
  threshold: number;
  previousVehicleCount: number;
  currentVehicleCount: number;
  observedAt: string;
  createdAt: string;
  status: ThresholdEventStatus;
}

export interface ThresholdEventStore {
  addPending(events: PendingThresholdEvent[]): Promise<void>;
  getAllPending(): Promise<PendingThresholdEvent[]>;
  removePending(eventIds: string[]): Promise<void>;
}

export class InMemoryThresholdEventStore implements ThresholdEventStore {
  private readonly events = new Map<string, PendingThresholdEvent>();
  private queue: Promise<unknown> = Promise.resolve();

  public async addPending(events: PendingThresholdEvent[]): Promise<void> {
    await this.withLock(async () => {
      for (const event of events) {
        if (!this.events.has(event.eventId)) {
          this.events.set(event.eventId, { ...event });
        }
      }
    });
  }

  public async getAllPending(): Promise<PendingThresholdEvent[]> {
    return await this.withLock(async () =>
      Array.from(this.events.values()).map((event) => ({ ...event })),
    );
  }

  public async removePending(eventIds: string[]): Promise<void> {
    await this.withLock(async () => {
      for (const eventId of eventIds) {
        this.events.delete(eventId);
      }
    });
  }

  private async withLock<T>(action: () => Promise<T>): Promise<T> {
    const current = this.queue;
    let release: () => void = () => {
      void 0;
    };

    this.queue = new Promise<void>((resolve) => {
      release = resolve;
    });

    await current;
    try {
      return await action();
    } finally {
      release();
    }
  }
}

export function deriveThresholdEventId(
  event: Omit<PendingThresholdEvent, "eventId" | "status">,
): string {
  return createHash("sha256")
    .update(event.locationId)
    .update("|")
    .update(String(event.threshold))
    .update("|")
    .update(String(event.previousVehicleCount))
    .update("|")
    .update(String(event.currentVehicleCount))
    .update("|")
    .update(event.observedAt)
    .digest("hex");
}

export function normalizeThresholdEventFromSource(
  locationId: SourceObservation["locationId"],
  threshold: number,
  previousVehicleCount: number,
  currentVehicleCount: number,
  observedAt: string,
  createdAt: string,
): PendingThresholdEvent {
  return {
    eventId: deriveThresholdEventId({
      locationId,
      threshold,
      previousVehicleCount,
      currentVehicleCount,
      observedAt,
      createdAt,
    }),
    locationId,
    threshold,
    previousVehicleCount,
    currentVehicleCount,
    observedAt,
    createdAt,
    status: "pending",
  };
}
