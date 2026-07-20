import type { CollectorService } from "../collector/collector-service.js";
import type { SourceClient } from "../polling/source-client.js";
import { ExternalSourceAdapter } from "./external-source-adapter.js";
import { ExternalSourceHttpError } from "./secure-http-client.js";
import type { ExternalSourcePollStateStore, PollFailurePolicy, PollReservationRequest } from "./postgres-poll-state-store.js";

export interface CoordinatedSourceClientOptions {
  reservation: PollReservationRequest;
  failurePolicy: Omit<PollFailurePolicy, "retryAfterMs">;
}

export class CoordinatedExternalSourceClient implements SourceClient<void> {
  public constructor(
    private readonly adapter: ExternalSourceAdapter,
    private readonly collector: CollectorService,
    private readonly stateStore: ExternalSourcePollStateStore,
    private readonly options: CoordinatedSourceClientOptions,
  ) {}

  public async fetch(signal: AbortSignal): Promise<void> {
    const reservation = await this.stateStore.tryReserve(this.options.reservation);
    if (reservation === null) return;
    try {
      const result = await this.adapter.poll(reservation, signal);
      if (result.status === "observation") await this.collector.ingest(result.observation);
      if (!await this.stateStore.recordSuccess(reservation, result.metadata)) throw new Error("Poll claim expired");
    } catch (error) {
      const retryAfterMs = error instanceof ExternalSourceHttpError ? error.retryAfterMs : undefined;
      try {
        await this.stateStore.recordFailure(reservation, {
          ...this.options.failurePolicy,
          ...(retryAfterMs === undefined ? {} : { retryAfterMs }),
        });
      } catch { throw cycleError(); }
      throw cycleError();
    }
  }
}

function cycleError(): Error { return new Error("External source collection cycle failed"); }
