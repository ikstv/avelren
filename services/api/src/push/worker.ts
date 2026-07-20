import type { TokenCrypto } from "./token-crypto.js";
import type { ClaimedNotification, NotificationOutboxStore } from "./outbox-store.js";
import { PushProviderError, type PushProvider } from "./provider.js";

export interface WorkerOptions {
  readonly owner: string;
  readonly batchSize: number;
  readonly concurrency: number;
  readonly claimTtlMs: number;
  readonly maxAttempts: number;
  readonly retryBaseMs: number;
  readonly retryMaxMs: number;
  readonly random?: () => number;
}

const stringifyPayload = (payload: Readonly<Record<string, unknown>>): Readonly<Record<string, string>> => {
  const keys = ["schemaVersion", "eventId", "locationId", "threshold", "observedCount", "observedAt"];
  if (Reflect.ownKeys(payload).length !== keys.length ||
    Reflect.ownKeys(payload).some((key) => typeof key !== "string" || !keys.includes(key))) {
    throw new PushProviderError("permanent");
  }
  const output: Record<string, string> = {};
  for (const key of keys) {
    const value = payload[key];
    if ((typeof value !== "string" && typeof value !== "number") || String(value).length > 256) {
      throw new PushProviderError("permanent");
    }
    output[key] = String(value);
  }
  return output;
};

export class NotificationWorker {
  private activeRun: Promise<void> | undefined;
  private stopping = false;

  public constructor(
    private readonly store: NotificationOutboxStore,
    private readonly provider: PushProvider,
    private readonly crypto: TokenCrypto,
    private readonly options: WorkerOptions,
  ) {}

  public runOnce(): Promise<void> {
    if (this.stopping) return Promise.resolve();
    if (!this.activeRun) {
      this.activeRun = this.performRun().finally(() => { this.activeRun = undefined; });
    }
    return this.activeRun;
  }

  public async stop(): Promise<void> {
    this.stopping = true;
    await this.activeRun;
  }

  private async performRun(): Promise<void> {
    const claimed = await this.store.claim(
      this.options.owner, this.options.batchSize, this.options.claimTtlMs,
    );
    let cursor = 0;
    const runners = Array.from({ length: Math.min(this.options.concurrency, claimed.length) }, async () => {
      while (cursor < claimed.length) {
        const item = claimed[cursor++];
        if (item) await this.process(item);
      }
    });
    await Promise.all(runners);
  }

  private async process(item: ClaimedNotification): Promise<void> {
    try {
      const token = this.crypto.decrypt({
        ciphertext: item.ciphertext, iv: item.iv, authTag: item.authTag, keyId: item.keyId,
      });
      const response = await this.provider.send({ token, data: stringifyPayload(item.payload) });
      await this.store.markSent(item.id, this.options.owner, response.messageId);
    } catch (error) {
      const providerError = error instanceof PushProviderError
        ? error : new PushProviderError("permanent");
      if (providerError.kind === "invalid_token") {
        await this.store.disableInvalidToken(item.id, this.options.owner);
        return;
      }
      if (providerError.kind === "permanent" || item.attemptCount >= this.options.maxAttempts) {
        await this.store.markPermanentFailure(item.id, this.options.owner, providerError.kind);
        return;
      }
      const random = this.options.random ?? Math.random;
      const exponential = Math.min(
        this.options.retryBaseMs * 2 ** Math.max(0, item.attemptCount - 1),
        this.options.retryMaxMs,
      );
      const jittered = Math.floor(exponential * (0.75 + random() * 0.5));
      const delay = Math.min(
        Math.max(jittered, providerError.retryAfterMs ?? 0),
        this.options.retryMaxMs,
      );
      await this.store.reschedule(item.id, this.options.owner, delay, providerError.kind);
    }
  }
}
