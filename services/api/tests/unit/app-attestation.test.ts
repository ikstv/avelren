import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { AppAttestationError, FakeAppAttestationVerifier,
  FirebaseAppAttestationVerifier, parseAppAttestationConfig,
  type FirebaseAppCheckClient } from "../../src/security/app-attestation.js";

const token = "header.payload.signature";
const now = Date.parse("2026-07-20T12:00:00.000Z");
const appId = "1:000000000000:android:testapp";
const config = {
  allowedAppIds: [appId], timeoutMs: 50, cacheMaxEntries: 2, cacheTtlMs: 1_000,
  maxTokenAgeSeconds: 3_600, clockSkewSeconds: 60,
};
const validResult = {
  appId,
  token: { iat: Math.floor(now / 1_000) - 60, exp: Math.floor(now / 1_000) + 3_000 },
};

describe("application attestation configuration", () => {
  it("keeps disabled as a safe default only when push is disabled", () => {
    expect(parseAppAttestationConfig({}, false).mode).toBe("disabled");
    expect(() => parseAppAttestationConfig({}, true)).toThrow("Push requires application attestation");
  });

  it("allows deterministic fake mode only outside production", () => {
    const env = { APP_ATTESTATION_MODE: "fake", FIREBASE_APP_CHECK_APP_IDS: appId,
      APP_ATTESTATION_FAKE_TOKEN_SHA256: createHash("sha256").update(token).digest("hex") };
    expect(parseAppAttestationConfig(env, true).mode).toBe("fake");
    expect(() => parseAppAttestationConfig({ ...env, NODE_ENV: "production" }, true)).toThrow();
  });

  it("requires complete fixed Firebase configuration in production", () => {
    expect(() => parseAppAttestationConfig({
      NODE_ENV: "production", APP_ATTESTATION_MODE: "firebase",
      FIREBASE_APP_CHECK_APP_IDS: appId,
    }, true)).toThrow("Firebase App Check configuration is incomplete");
    expect(parseAppAttestationConfig({
      NODE_ENV: "production", APP_ATTESTATION_MODE: "firebase",
      FIREBASE_APP_CHECK_APP_IDS: appId, FIREBASE_PROJECT_ID: "avelren-test-project",
    }, true).projectId).toBe("avelren-test-project");
  });
});

describe("application attestation verifiers", () => {
  it("uses a deterministic fake token digest without network access", async () => {
    const digest = createHash("sha256").update(token).digest("hex");
    const verifier = new FakeAppAttestationVerifier(digest, appId);
    await expect(verifier.verify(token)).resolves.toEqual({ appId });
    await expect(verifier.verify("wrong.token.value.12345")).rejects.toMatchObject({ kind: "invalid" });
  });

  it("accepts official verifier claims and caches only a bounded digest", async () => {
    const client: FirebaseAppCheckClient = { verifyToken: vi.fn().mockResolvedValue(validResult) };
    const verifier = new FirebaseAppAttestationVerifier(client, config, () => now);
    await expect(verifier.verify(token)).resolves.toEqual({ appId });
    await expect(verifier.verify(token)).resolves.toEqual({ appId });
    expect(client.verifyToken).toHaveBeenCalledTimes(1);
  });

  it.each([
    ["expired", { ...validResult, token: { ...validResult.token, exp: Math.floor(now / 1_000) } }],
    ["future issued-at", { ...validResult, token: { ...validResult.token,
      iat: Math.floor(now / 1_000) + 61 } }],
    ["wrong app", { ...validResult, appId: "1:000000000000:android:other" }],
  ])("rejects %s claims", async (_name, result) => {
    const verifier = new FirebaseAppAttestationVerifier({
      verifyToken: vi.fn().mockResolvedValue(result),
    }, config, () => now);
    await expect(verifier.verify(token)).rejects.toMatchObject({ kind: "invalid" });
  });

  it.each(["wrong issuer", "wrong audience", "bad signature", "malformed token"])(
    "normalizes official verifier rejection for %s", async (reason) => {
      const secret = `secret-${reason}`;
      const verifier = new FirebaseAppAttestationVerifier({
        verifyToken: vi.fn().mockRejectedValue(Object.assign(new Error(secret), { code: "app-check/invalid-argument" })),
      }, config, () => now);
      try { await verifier.verify(token); } catch (error) {
        expect(error).toBeInstanceOf(AppAttestationError);
        expect(String(error)).not.toContain(secret);
      }
    },
  );

  it("normalizes verifier unavailability and timeout", async () => {
    const unavailable = new FirebaseAppAttestationVerifier({
      verifyToken: vi.fn().mockRejectedValue({ code: "app-check/internal-error" }),
    }, config, () => now);
    await expect(unavailable.verify(token)).rejects.toMatchObject({ kind: "unavailable" });
    const timeout = new FirebaseAppAttestationVerifier({ verifyToken: () => new Promise(() => {}) },
      config, () => now);
    await expect(timeout.verify(token)).rejects.toMatchObject({ kind: "unavailable" });
  });
});
