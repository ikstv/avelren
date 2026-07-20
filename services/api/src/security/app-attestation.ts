import { createHash, timingSafeEqual } from "node:crypto";
import { applicationDefault, initializeApp } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";

const APP_ID_PATTERN = /^[A-Za-z0-9:_-]{6,256}$/;
const PROJECT_ID_PATTERN = /^[a-z][a-z0-9-]{4,28}[a-z0-9]$/;
const TOKEN_PATTERN = /^[A-Za-z0-9._-]{20,8192}$/;

export type AppAttestationMode = "disabled" | "fake" | "firebase";
export type AppAttestationErrorKind = "invalid" | "unavailable";

export class AppAttestationError extends Error {
  public constructor(public readonly kind: AppAttestationErrorKind) {
    super("Application attestation failed");
    this.name = "AppAttestationError";
  }
}

export interface AppAttestationVerifier {
  verify(token: string): Promise<Readonly<{ appId: string }>>;
}

export interface AppAttestationConfig {
  readonly mode: AppAttestationMode;
  readonly projectId?: string;
  readonly allowedAppIds: readonly string[];
  readonly fakeTokenSha256?: string;
  readonly timeoutMs: number;
  readonly cacheMaxEntries: number;
  readonly cacheTtlMs: number;
  readonly maxTokenAgeSeconds: number;
  readonly clockSkewSeconds: number;
}

interface DecodedToken {
  readonly appId: string;
  readonly issuedAt: number;
  readonly expiresAt: number;
}

export interface FirebaseAppCheckClient {
  verifyToken(token: string): Promise<Readonly<{
    appId: string;
    token: Readonly<{ iat?: unknown; exp?: unknown }>;
  }>>;
}

const readInt = (env: NodeJS.ProcessEnv, name: string, fallback: number,
  minimum: number, maximum: number): number => {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`Invalid ${name} configuration`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`Invalid ${name} configuration`);
  }
  return value;
};

const parseAllowedAppIds = (value: string | undefined): readonly string[] => {
  if (!value) return [];
  const values = value.split(",");
  if (values.some((item) => !APP_ID_PATTERN.test(item)) || new Set(values).size !== values.length) {
    throw new Error("Invalid Firebase App Check application configuration");
  }
  return Object.freeze([...values]);
};

export function parseAppAttestationConfig(
  env: NodeJS.ProcessEnv,
  pushEnabled: boolean,
): AppAttestationConfig {
  const rawMode = env.APP_ATTESTATION_MODE ?? "disabled";
  if (rawMode !== "disabled" && rawMode !== "fake" && rawMode !== "firebase") {
    throw new Error("APP_ATTESTATION_MODE must be disabled, fake, or firebase");
  }
  if (pushEnabled && rawMode === "disabled") {
    throw new Error("Push requires application attestation");
  }
  if (env.NODE_ENV === "production" && pushEnabled && rawMode !== "firebase") {
    throw new Error("Production push requires Firebase App Check");
  }

  const base = {
    mode: rawMode,
    allowedAppIds: parseAllowedAppIds(env.FIREBASE_APP_CHECK_APP_IDS),
    timeoutMs: readInt(env, "APP_ATTESTATION_TIMEOUT_MS", 5_000, 500, 30_000),
    cacheMaxEntries: readInt(env, "APP_ATTESTATION_CACHE_MAX_ENTRIES", 256, 0, 10_000),
    cacheTtlMs: readInt(env, "APP_ATTESTATION_CACHE_TTL_MS", 60_000, 0, 300_000),
    maxTokenAgeSeconds: readInt(env, "APP_ATTESTATION_MAX_TOKEN_AGE_SECONDS", 3_600, 60, 86_400),
    clockSkewSeconds: readInt(env, "APP_ATTESTATION_CLOCK_SKEW_SECONDS", 60, 0, 300),
  } as const;

  if (rawMode === "disabled") return base;
  if (base.allowedAppIds.length === 0) {
    throw new Error("Application attestation requires an allowed application ID");
  }
  if (rawMode === "fake") {
    if (env.NODE_ENV === "production") throw new Error("Fake attestation is not allowed in production");
    const fakeTokenSha256 = env.APP_ATTESTATION_FAKE_TOKEN_SHA256;
    if (!fakeTokenSha256 || !/^[a-f0-9]{64}$/.test(fakeTokenSha256)) {
      throw new Error("Fake attestation requires a SHA-256 token digest");
    }
    return { ...base, fakeTokenSha256 };
  }

  const projectId = env.FIREBASE_PROJECT_ID;
  if (!projectId || !PROJECT_ID_PATTERN.test(projectId)) {
    throw new Error("Firebase App Check configuration is incomplete");
  }
  return { ...base, projectId };
}

const tokenDigest = (token: string): string => createHash("sha256").update(token).digest("hex");

export class FakeAppAttestationVerifier implements AppAttestationVerifier {
  private readonly expected: Buffer;

  public constructor(expectedTokenSha256: string, private readonly appId: string) {
    if (!/^[a-f0-9]{64}$/.test(expectedTokenSha256) || !APP_ID_PATTERN.test(appId)) {
      throw new Error("Invalid fake attestation configuration");
    }
    this.expected = Buffer.from(expectedTokenSha256, "hex");
  }

  public async verify(token: string): Promise<Readonly<{ appId: string }>> {
    const actual = Buffer.from(tokenDigest(token), "hex");
    if (!TOKEN_PATTERN.test(token) || !timingSafeEqual(actual, this.expected)) {
      throw new AppAttestationError("invalid");
    }
    return { appId: this.appId };
  }
}

export class FirebaseAppAttestationVerifier implements AppAttestationVerifier {
  private readonly cache = new Map<string, Readonly<DecodedToken & { cachedUntil: number }>>();

  public constructor(
    private readonly client: FirebaseAppCheckClient,
    private readonly config: Pick<AppAttestationConfig, "allowedAppIds" | "timeoutMs" |
      "cacheMaxEntries" | "cacheTtlMs" | "maxTokenAgeSeconds" | "clockSkewSeconds">,
    private readonly clock: () => number = Date.now,
  ) {}

  public async verify(token: string): Promise<Readonly<{ appId: string }>> {
    if (!TOKEN_PATTERN.test(token)) throw new AppAttestationError("invalid");
    const digest = tokenDigest(token);
    const now = this.clock();
    const cached = this.cache.get(digest);
    if (cached && cached.cachedUntil > now) {
      this.validate(cached, now);
      return { appId: cached.appId };
    }
    this.cache.delete(digest);

    let timeout: NodeJS.Timeout | undefined;
    try {
      const result = await Promise.race([
        this.client.verifyToken(token),
        new Promise<never>((_resolve, reject) => {
          timeout = setTimeout(() => reject(new AppAttestationError("unavailable")),
            this.config.timeoutMs);
        }),
      ]);
      const decoded: DecodedToken = {
        appId: result.appId,
        issuedAt: this.claimTime(result.token.iat),
        expiresAt: this.claimTime(result.token.exp),
      };
      this.validate(decoded, now);
      this.remember(digest, decoded, now);
      return { appId: decoded.appId };
    } catch (error) {
      if (error instanceof AppAttestationError) throw error;
      const code = typeof error === "object" && error !== null && "code" in error
        ? String((error as { code: unknown }).code) : "";
      const kind = /internal|network|unavailable|timeout|too-many/i.test(code)
        ? "unavailable" : "invalid";
      throw new AppAttestationError(kind);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }

  private claimTime(value: unknown): number {
    if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
      throw new AppAttestationError("invalid");
    }
    return value;
  }

  private validate(token: DecodedToken, nowMs: number): void {
    const now = Math.floor(nowMs / 1_000);
    if (!this.config.allowedAppIds.includes(token.appId) ||
      token.issuedAt > now + this.config.clockSkewSeconds || token.expiresAt <= now ||
      now - token.issuedAt > this.config.maxTokenAgeSeconds + this.config.clockSkewSeconds ||
      token.expiresAt <= token.issuedAt) {
      throw new AppAttestationError("invalid");
    }
  }

  private remember(digest: string, token: DecodedToken, now: number): void {
    if (this.config.cacheMaxEntries === 0 || this.config.cacheTtlMs === 0) return;
    while (this.cache.size >= this.config.cacheMaxEntries) {
      const oldest = this.cache.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.cache.delete(oldest);
    }
    this.cache.set(digest, {
      ...token,
      cachedUntil: Math.min(now + this.config.cacheTtlMs, token.expiresAt * 1_000),
    });
  }
}

export function createAppAttestationVerifier(config: AppAttestationConfig): AppAttestationVerifier {
  if (config.mode === "disabled") throw new Error("Application attestation is disabled");
  if (config.mode === "fake") {
    if (!config.fakeTokenSha256) throw new Error("Fake attestation configuration is incomplete");
    const appId = config.allowedAppIds[0];
    if (!appId) throw new Error("Fake attestation configuration is incomplete");
    return new FakeAppAttestationVerifier(config.fakeTokenSha256, appId);
  }
  if (!config.projectId) throw new Error("Firebase App Check configuration is incomplete");
  const firebaseApp = initializeApp({
    credential: applicationDefault(),
    projectId: config.projectId,
  }, "avelren-app-check");
  const appCheck = getAppCheck(firebaseApp);
  return new FirebaseAppAttestationVerifier({
    verifyToken: async (token) => {
      const result = await appCheck.verifyToken(token);
      return { appId: result.appId, token: { iat: result.token.iat, exp: result.token.exp } };
    },
  }, config);
}
