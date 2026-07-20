import type { SourceClient } from "./source-client.js";
import type { CycleLease } from "../lease/cycle-lease.js";

export const MINIMUM_POLL_INTERVAL_MS = 60_000;

export interface PollingScheduler {
  setTimeout(callback: () => void, delayMs: number): unknown;
  clearTimeout(handle: unknown): void;
}

export interface PollingCoordinatorOptions<T> {
  sourceClient: SourceClient<T>;
  intervalMs: number;
  onValue: (value: T) => void | Promise<void>;
  onError?: (error: unknown) => void | Promise<void>;
  scheduler?: PollingScheduler;
  cycleLease?: CycleLease;
}

const systemScheduler: PollingScheduler = {
  setTimeout(callback, delayMs) {
    return setTimeout(callback, delayMs);
  },
  clearTimeout(handle) {
    clearTimeout(handle as ReturnType<typeof setTimeout>);
  },
};

export function validatePollInterval(intervalMs: number): void {
  if (!Number.isSafeInteger(intervalMs) || intervalMs < MINIMUM_POLL_INTERVAL_MS) {
    throw new RangeError(
      `intervalMs must be a safe integer greater than or equal to ${MINIMUM_POLL_INTERVAL_MS}`,
    );
  }
}

export class PollingCoordinator<T> {
  private readonly sourceClient: SourceClient<T>;
  private readonly intervalMs: number;
  private readonly onValue: (value: T) => void | Promise<void>;
  private readonly onError: ((error: unknown) => void | Promise<void>) | undefined;
  private readonly scheduler: PollingScheduler;
  private readonly cycleLease: CycleLease | undefined;

  private running = false;
  private timerHandle: unknown;
  private activeCycle: Promise<void> | undefined;
  private activeAbortController: AbortController | undefined;

  public constructor(options: PollingCoordinatorOptions<T>) {
    validatePollInterval(options.intervalMs);

    this.sourceClient = options.sourceClient;
    this.intervalMs = options.intervalMs;
    this.onValue = options.onValue;
    this.onError = options.onError;
    this.scheduler = options.scheduler ?? systemScheduler;
    this.cycleLease = options.cycleLease;
  }

  public get isRunning(): boolean {
    return this.running;
  }

  public start(): void {
    if (this.running) {
      return;
    }

    this.running = true;
    this.triggerCycle();
  }

  public async stop(): Promise<void> {
    this.running = false;

    if (this.timerHandle !== undefined) {
      this.scheduler.clearTimeout(this.timerHandle);
      this.timerHandle = undefined;
    }

    this.activeAbortController?.abort();

    if (this.activeCycle !== undefined) {
      await this.activeCycle;
    }
  }

  private triggerCycle(): void {
    if (!this.running || this.activeCycle !== undefined) {
      return;
    }

    this.timerHandle = undefined;
    const cycle = this.runCycle();
    this.activeCycle = cycle;

    void cycle.finally(() => {
      if (this.activeCycle === cycle) {
        this.activeCycle = undefined;
      }

      if (this.running) {
        this.scheduleNextCycle();
      }
    });
  }

  private async runCycle(): Promise<void> {
    const abortController = new AbortController();
    this.activeAbortController = abortController;

    try {
      if (this.cycleLease === undefined) {
        await this.fetchAndHandle(abortController.signal);
      } else {
        await this.cycleLease.runIfAcquired(async (leaseSignal) => {
          await this.fetchAndHandle(
            AbortSignal.any([abortController.signal, leaseSignal]),
          );
        });
      }
    } catch (error) {
      const stoppedByCoordinator = abortController.signal.aborted && !this.running;

      if (!stoppedByCoordinator) {
        await this.reportError(error);
      }
    } finally {
      if (this.activeAbortController === abortController) {
        this.activeAbortController = undefined;
      }
    }
  }

  private async fetchAndHandle(signal: AbortSignal): Promise<void> {
    const value = await this.sourceClient.fetch(signal);

    if (!signal.aborted) {
      await this.onValue(value);
    }
  }

  private scheduleNextCycle(): void {
    this.timerHandle = this.scheduler.setTimeout(() => {
      this.triggerCycle();
    }, this.intervalMs);
  }

  private async reportError(error: unknown): Promise<void> {
    if (this.onError === undefined) {
      return;
    }

    try {
      await this.onError(error);
    } catch {
      // Error reporting must not stop future polling cycles.
    }
  }
}
