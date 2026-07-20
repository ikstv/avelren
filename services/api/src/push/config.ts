import { validateTokenKeyring, type TokenKeyring } from "./token-crypto.js";

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

const decodeKey = (value: string): Buffer => {
  if (!/^[A-Za-z0-9+/]{43}=$/.test(value)) {
    throw new Error("Invalid push cryptography configuration");
  }
  const key = Buffer.from(value, "base64");
  if (key.length !== 32 || key.toString("base64") !== value) {
    throw new Error("Invalid push cryptography configuration");
  }
  return key;
};

export interface PushConfig {
  readonly enabled: boolean;
  readonly projectId?: string;
  readonly keyring?: TokenKeyring;
  readonly providerTimeoutMs: number;
  readonly workerIntervalMs: number;
  readonly batchSize: number;
  readonly concurrency: number;
  readonly claimTtlMs: number;
  readonly maxAttempts: number;
  readonly retryBaseMs: number;
  readonly retryMaxMs: number;
}

export function parsePushConfig(env: NodeJS.ProcessEnv): PushConfig {
  const rawEnabled = env.PUSH_ENABLED;
  if (rawEnabled !== undefined && rawEnabled !== "true" && rawEnabled !== "false") {
    throw new Error("PUSH_ENABLED must be exactly true or false");
  }
  const enabled = rawEnabled === "true";
  const base = {
    enabled,
    providerTimeoutMs: readInt(env, "PUSH_PROVIDER_TIMEOUT_MS", 10_000, 1_000, 60_000),
    workerIntervalMs: readInt(env, "PUSH_WORKER_INTERVAL_MS", 5_000, 1_000, 60_000),
    batchSize: readInt(env, "PUSH_WORKER_BATCH_SIZE", 25, 1, 100),
    concurrency: readInt(env, "PUSH_WORKER_CONCURRENCY", 4, 1, 16),
    claimTtlMs: readInt(env, "PUSH_CLAIM_TTL_MS", 60_000, 10_000, 600_000),
    maxAttempts: readInt(env, "PUSH_MAX_ATTEMPTS", 8, 1, 32),
    retryBaseMs: readInt(env, "PUSH_RETRY_BASE_MS", 1_000, 100, 60_000),
    retryMaxMs: readInt(env, "PUSH_RETRY_MAX_MS", 900_000, 1_000, 86_400_000),
  } as const;
  if (base.claimTtlMs < base.providerTimeoutMs + 5_000) {
    throw new Error("PUSH_CLAIM_TTL_MS must exceed the provider timeout");
  }
  const projectId = env.FCM_PROJECT_ID;
  const activeKeyId = env.PUSH_TOKEN_ACTIVE_KEY_ID;
  const serializedKeys = env.PUSH_TOKEN_ENCRYPTION_KEYS;
  const fingerprintKey = env.PUSH_TOKEN_FINGERPRINT_KEY;
  const hasCryptoConfiguration = [activeKeyId, serializedKeys, fingerprintKey]
    .some((value) => value !== undefined && value !== "");
  if (!enabled && !hasCryptoConfiguration) return base;
  if (!activeKeyId || !serializedKeys || !fingerprintKey) {
    throw new Error("Push is enabled but required configuration is incomplete");
  }
  const encryptionKeys = new Map<string, Buffer>();
  for (const item of serializedKeys.split(",")) {
    const separator = item.indexOf(":");
    if (separator <= 0) throw new Error("Invalid push cryptography configuration");
    const keyId = item.slice(0, separator);
    if (encryptionKeys.has(keyId)) throw new Error("Invalid push cryptography configuration");
    encryptionKeys.set(keyId, decodeKey(item.slice(separator + 1)));
  }
  if (!encryptionKeys.has(activeKeyId)) throw new Error("Invalid push cryptography configuration");
  const keyring = { activeKeyId, encryptionKeys, fingerprintKey: decodeKey(fingerprintKey) };
  validateTokenKeyring(keyring);
  if (!enabled) return base;
  if (!projectId || !/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(projectId)) {
    throw new Error("Push is enabled but required configuration is incomplete");
  }
  return {
    ...base,
    projectId,
    keyring,
  };
}
