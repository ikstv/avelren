import { describe, expect, it, vi } from "vitest";

import {
  MINIMUM_POLL_INTERVAL_MS,
  PollingCoordinator,
  validatePollInterval,
  type PollingScheduler,
} from "../../src/polling/polling-coordinator.js";
import { createCollectorRuntime } from "../../src/collector/collector-runtime.js";
import type { SourceClient } from "../../src/polling/source-client.js";
import { InMemorySnapshotStore } from "../../src/collector/snapshot-store.js";
import { InMemoryThresholdEventStore } from "../../src/collector/threshold-event-store.js";

class ManualScheduler implements PollingScheduler {
  public readonly delays: number[] = [];
  private readonly tasks = new Map<number, () => void>();
  private nextHandle = 1;

  public setTimeout(callback: () => void, delayMs: number): unknown {
    const handle = this.nextHandle;
    this.nextHandle += 1;
    this.delays.push(delayMs);
    this.tasks.set(handle, callback);
    return handle;
  }

  public clearTimeout(handle: unknown): void {
    if (typeof handle === "number") {
      this.tasks.delete(handle);
    }
  }

  public runNext(): void {
    const next = this.tasks.entries().next();

    if (next.done) {
      throw new Error("No scheduled task is available");
    }

    const [handle, callback] = next.value;
    this.tasks.delete(handle);
    callback();
  }

  public get pendingCount(): number {
    return this.tasks.size;
  }
}

describe("poll interval validation", () => {
  it("accepts exactly 60 seconds", () => {
    expect(() => validatePollInterval(MINIMUM_POLL_INTERVAL_MS)).not.toThrow();
  });

  it.each([59_999, 60_000.5, Number.NaN, Number.POSITIVE_INFINITY])(
    "rejects an unsafe interval: %s",
    (intervalMs) => {
      expect(() => validatePollInterval(intervalMs)).toThrow(RangeError);
    },
  );

  it("rejects collector runtime polling below 60 seconds", () => {
    expect(() =>
      createCollectorRuntime({
        sourceClient: {
          fetch: vi.fn(),
        },
        snapshotStore: new InMemorySnapshotStore(),
        thresholdEventStore: new InMemoryThresholdEventStore(),
        intervalMs: MINIMUM_POLL_INTERVAL_MS - 1,
      }),
    ).toThrow(RangeError);
  });
});

describe("PollingCoordinator", () => {
  it("skips the source request when the distributed lease is unavailable", async () => {
    const scheduler = new ManualScheduler();
    const fetch = vi.fn<SourceClient<number>["fetch"]>();
    const coordinator = new PollingCoordinator({
      sourceClient: { fetch },
      intervalMs: MINIMUM_POLL_INTERVAL_MS,
      onValue: vi.fn(),
      scheduler,
      cycleLease: {
        runIfAcquired: vi.fn().mockResolvedValue(false),
      },
    });

    coordinator.start();

    await vi.waitFor(() => {
      expect(scheduler.pendingCount).toBe(1);
    });
    expect(fetch).not.toHaveBeenCalled();
    await coordinator.stop();
  });

  it("polls immediately, then waits at least the configured interval", async () => {
    const scheduler = new ManualScheduler();
    const fetch = vi.fn<SourceClient<number>["fetch"]>()
      .mockResolvedValueOnce(10)
      .mockResolvedValueOnce(20);
    const values: number[] = [];
    const coordinator = new PollingCoordinator({
      sourceClient: { fetch },
      intervalMs: MINIMUM_POLL_INTERVAL_MS,
      onValue(value) {
        values.push(value);
      },
      scheduler,
    });

    coordinator.start();

    await vi.waitFor(() => {
      expect(values).toEqual([10]);
    });
    expect(scheduler.delays).toEqual([MINIMUM_POLL_INTERVAL_MS]);
    expect(scheduler.pendingCount).toBe(1);

    scheduler.runNext();

    await vi.waitFor(() => {
      expect(values).toEqual([10, 20]);
    });
    expect(scheduler.delays).toEqual([
      MINIMUM_POLL_INTERVAL_MS,
      MINIMUM_POLL_INTERVAL_MS,
    ]);

    await coordinator.stop();
    expect(coordinator.isRunning).toBe(false);
    expect(scheduler.pendingCount).toBe(0);
  });

  it("does not create overlapping cycles when start is called twice", async () => {
    const scheduler = new ManualScheduler();
    let resolveFetch: ((value: number) => void) | undefined;
    const fetch = vi.fn<SourceClient<number>["fetch"]>(
      () =>
        new Promise<number>((resolve) => {
          resolveFetch = resolve;
        }),
    );
    const coordinator = new PollingCoordinator({
      sourceClient: { fetch },
      intervalMs: MINIMUM_POLL_INTERVAL_MS,
      onValue: vi.fn(),
      scheduler,
    });

    coordinator.start();
    coordinator.start();

    expect(fetch).toHaveBeenCalledTimes(1);
    expect(scheduler.pendingCount).toBe(0);

    resolveFetch?.(7);
    await vi.waitFor(() => {
      expect(scheduler.pendingCount).toBe(1);
    });

    await coordinator.stop();
  });

  it("reports client errors and continues scheduling", async () => {
    const scheduler = new ManualScheduler();
    const failure = new Error("temporary failure");
    const onError = vi.fn();
    const coordinator = new PollingCoordinator({
      sourceClient: {
        fetch: vi.fn<SourceClient<number>["fetch"]>().mockRejectedValue(failure),
      },
      intervalMs: MINIMUM_POLL_INTERVAL_MS,
      onValue: vi.fn(),
      onError,
      scheduler,
    });

    coordinator.start();

    await vi.waitFor(() => {
      expect(onError).toHaveBeenCalledWith(failure);
    });
    expect(scheduler.pendingCount).toBe(1);

    await coordinator.stop();
  });
});
