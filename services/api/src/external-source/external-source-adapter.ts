import type { SourceObservation } from "../collector/source-observation.js";

export interface ExternalSourceCacheMetadata { etag?: string; lastModified?: string }
export interface ExternalSourceResponse {
  status: "ok" | "not-modified";
  body?: Uint8Array;
  receivedAt: Date;
  metadata: ExternalSourceCacheMetadata;
}
export interface ExternalSourceClient {
  fetch(cache: ExternalSourceCacheMetadata, signal: AbortSignal): Promise<ExternalSourceResponse>;
}
export interface ObservationParser {
  parse(body: Uint8Array, trustedObservedAt: Date): SourceObservation;
}
export type ExternalSourcePollResult =
  | Readonly<{ status: "not-modified"; metadata: ExternalSourceCacheMetadata }>
  | Readonly<{ status: "observation"; observation: SourceObservation; metadata: ExternalSourceCacheMetadata }>;

export class ExternalSourceAdapter {
  public constructor(private readonly client: ExternalSourceClient, private readonly parser: ObservationParser) {}

  public async poll(cache: ExternalSourceCacheMetadata, signal: AbortSignal): Promise<ExternalSourcePollResult> {
    const response = await this.client.fetch(cache, signal);
    if (response.status === "not-modified") return { status: "not-modified", metadata: response.metadata };
    if (response.body === undefined) throw new Error("External source response is invalid");
    return {
      status: "observation",
      observation: this.parser.parse(response.body, response.receivedAt),
      metadata: response.metadata,
    };
  }
}
