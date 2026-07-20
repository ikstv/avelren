import { GoogleAuth } from "google-auth-library";

const RESPONSE_LIMIT_BYTES = 64 * 1024;

export type ProviderErrorKind = "transient" | "rate_limited" | "invalid_token" | "permanent";

export class PushProviderError extends Error {
  public constructor(
    public readonly kind: ProviderErrorKind,
    public readonly retryAfterMs?: number,
  ) {
    super("Push provider request failed");
    this.name = "PushProviderError";
  }
}

export interface PushMessage {
  readonly token: string;
  readonly data: Readonly<Record<string, string>>;
}

export interface PushProvider {
  send(message: PushMessage): Promise<Readonly<{ messageId: string }>>;
}

export interface AccessTokenProvider {
  getAccessToken(): Promise<string>;
}

export class GoogleAdcAccessTokenProvider implements AccessTokenProvider {
  private readonly auth = new GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/firebase.messaging"],
  });

  public async getAccessToken(): Promise<string> {
    const client = await this.auth.getClient();
    const response = await client.getAccessToken();
    const token = typeof response === "string" ? response : response?.token;
    if (!token) throw new PushProviderError("transient");
    return token;
  }
}

const retryAfterMs = (response: Response): number | undefined => {
  const value = response.headers.get("retry-after");
  if (!value || !/^\d+$/.test(value)) return undefined;
  return Math.min(Number(value) * 1_000, 86_400_000);
};

const providerReason = (body: string): string | undefined => {
  try {
    const decoded = JSON.parse(body) as {
      error?: { details?: Array<{ errorCode?: unknown }> };
    };
    for (const detail of decoded.error?.details ?? []) {
      if (typeof detail.errorCode === "string") return detail.errorCode;
    }
  } catch {
    return undefined;
  }
  return undefined;
};

const classify = (status: number, body: string): ProviderErrorKind => {
  const reason = providerReason(body);
  if (reason === "UNREGISTERED") return "invalid_token";
  if (reason === "QUOTA_EXCEEDED") return "rate_limited";
  if (status === 429) return "rate_limited";
  if (status === 408 || status >= 500) return "transient";
  return "permanent";
};

async function readLimited(response: Response): Promise<string> {
  const advertised = response.headers.get("content-length");
  if (advertised && /^\d+$/.test(advertised) && Number(advertised) > RESPONSE_LIMIT_BYTES) {
    throw new PushProviderError("permanent");
  }
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const part = await reader.read();
    if (part.done) break;
    size += part.value.length;
    if (size > RESPONSE_LIMIT_BYTES) {
      await reader.cancel();
      throw new PushProviderError("permanent");
    }
    chunks.push(part.value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder().decode(bytes);
}

export class FcmHttpV1Provider implements PushProvider {
  private readonly endpoint: string;

  public constructor(
    projectId: string,
    private readonly accessTokens: AccessTokenProvider,
    private readonly timeoutMs: number,
    private readonly request: typeof fetch = fetch,
  ) {
    if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(projectId) ||
      !Number.isSafeInteger(timeoutMs) || timeoutMs < 1_000 || timeoutMs > 60_000) {
      throw new Error("Invalid push provider configuration");
    }
    this.endpoint = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  }

  public async send(message: PushMessage): Promise<Readonly<{ messageId: string }>> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const accessToken = await this.accessTokens.getAccessToken();
      const response = await this.request(this.endpoint, {
        method: "POST",
        redirect: "error",
        headers: {
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ message: { token: message.token, data: message.data } }),
        signal: controller.signal,
      });
      const body = await readLimited(response);
      if (!response.ok) {
        throw new PushProviderError(classify(response.status, body), retryAfterMs(response));
      }
      if (!response.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
        throw new PushProviderError("permanent");
      }
      try {
        const decoded = JSON.parse(body) as unknown;
        if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) throw new Error();
        const name = (decoded as Record<string, unknown>).name;
        if (typeof name !== "string" || name.length < 1 || name.length > 512) throw new Error();
        return { messageId: name };
      } catch {
        throw new PushProviderError("permanent");
      }
    } catch (error) {
      if (error instanceof PushProviderError) throw error;
      throw new PushProviderError("transient");
    } finally {
      clearTimeout(timeout);
    }
  }
}
