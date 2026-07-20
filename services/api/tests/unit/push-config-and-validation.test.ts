import { describe, expect, it } from "vitest";
import { parsePushConfig } from "../../src/push/config.js";
import { hashInstallationCredential, verifyInstallationCredential } from "../../src/push/credential-hasher.js";
import { parseRegistrationInput } from "../../src/push/device-registration.js";
import { TokenCrypto } from "../../src/push/token-crypto.js";

const base64Key = Buffer.alloc(32, 7).toString("base64");
const otherBase64Key = Buffer.alloc(32, 8).toString("base64");
const legacyBase64Key = Buffer.alloc(32, 9).toString("base64");

describe("push configuration", () => {
  it("is disabled without production defaults", () => {
    expect(parsePushConfig({}).enabled).toBe(false);
  });

  it("fails closed for invalid or incomplete enabled configuration", () => {
    expect(() => parsePushConfig({ PUSH_ENABLED: "TRUE" })).toThrow();
    expect(() => parsePushConfig({ PUSH_ENABLED: "true" })).toThrow();
  });

  it("accepts an explicit complete keyring", () => {
    const config = parsePushConfig({
      PUSH_ENABLED: "true",
      FCM_PROJECT_ID: "avelren-test-project",
      PUSH_TOKEN_ACTIVE_KEY_ID: "v2",
      PUSH_TOKEN_ENCRYPTION_KEYS: `v1:${legacyBase64Key},v2:${base64Key}`,
      PUSH_TOKEN_FINGERPRINT_KEY: otherBase64Key,
    });
    expect(config.keyring?.encryptionKeys.size).toBe(2);
  });

  it("rejects a fingerprint key equal to the active or a legacy encryption key", () => {
    const configuration = {
      PUSH_ENABLED: "true",
      FCM_PROJECT_ID: "avelren-test-project",
      PUSH_TOKEN_ACTIVE_KEY_ID: "v2",
      PUSH_TOKEN_ENCRYPTION_KEYS: `v1:${legacyBase64Key},v2:${base64Key}`,
    };
    expect(() => parsePushConfig({
      ...configuration, PUSH_TOKEN_FINGERPRINT_KEY: base64Key,
    })).toThrow("Push cryptographic keys must be distinct");
    expect(() => parsePushConfig({
      ...configuration, PUSH_TOKEN_FINGERPRINT_KEY: legacyBase64Key,
    })).toThrow("Push cryptographic keys must be distinct");
  });

  it("rejects duplicate encryption material and non-canonical base64", () => {
    expect(() => parsePushConfig({
      PUSH_ENABLED: "true",
      FCM_PROJECT_ID: "avelren-test-project",
      PUSH_TOKEN_ACTIVE_KEY_ID: "v2",
      PUSH_TOKEN_ENCRYPTION_KEYS: `v1:${base64Key},v2:${base64Key}`,
      PUSH_TOKEN_FINGERPRINT_KEY: otherBase64Key,
    })).toThrow("Push cryptographic keys must be distinct");
    const nonCanonical = `${base64Key.slice(0, -2)}d=`;
    expect(Buffer.from(nonCanonical, "base64")).toEqual(Buffer.from(base64Key, "base64"));
    expect(() => parsePushConfig({
      PUSH_ENABLED: "true",
      FCM_PROJECT_ID: "avelren-test-project",
      PUSH_TOKEN_ACTIVE_KEY_ID: "v2",
      PUSH_TOKEN_ENCRYPTION_KEYS: `v2:${nonCanonical}`,
      PUSH_TOKEN_FINGERPRINT_KEY: otherBase64Key,
    })).toThrow("Invalid push cryptography configuration");
  });

  it("validates explicitly supplied keys even while push is disabled", () => {
    expect(() => parsePushConfig({
      PUSH_ENABLED: "false",
      PUSH_TOKEN_ACTIVE_KEY_ID: "v1",
      PUSH_TOKEN_ENCRYPTION_KEYS: `v1:${base64Key}`,
      PUSH_TOKEN_FINGERPRINT_KEY: base64Key,
    })).toThrow("Push cryptographic keys must be distinct");
  });

  it("enforces key separation when crypto is constructed directly", () => {
    const material = Buffer.alloc(32, 21);
    expect(() => new TokenCrypto({
      activeKeyId: "v1", encryptionKeys: new Map([["v1", material]]),
      fingerprintKey: Buffer.from(material),
    })).toThrow("Push cryptographic keys must be distinct");
    try {
      new TokenCrypto({
        activeKeyId: "v1", encryptionKeys: new Map([["v1", material]]),
        fingerprintKey: Buffer.from(material),
      });
    } catch (error) {
      expect(String(error)).not.toContain(material.toString("base64"));
    }
  });
});

describe("registration validation", () => {
  const valid = {
    installationId: "installation_identifier_12345",
    token: "token-value-1234567890",
    platform: "android",
    locale: "uk-UA",
  };

  it("accepts only the exact plain registration object", () => {
    expect(parseRegistrationInput(valid).platform).toBe("android");
    expect(() => parseRegistrationInput({ ...valid, extra: undefined })).toThrow("Invalid request payload");
    expect(() => parseRegistrationInput(Object.assign(Object.create({}), valid))).toThrow();
    expect(() => parseRegistrationInput(Object.assign(Object.create(null), valid))).toThrow();
  });

  it("rejects symbol, non-enumerable, accessor, and invalid values without running getters", () => {
    const symbolValue = { ...valid, [Symbol("secret")]: "value" };
    expect(() => parseRegistrationInput(symbolValue)).toThrow();
    const hidden = { ...valid };
    Object.defineProperty(hidden, "hidden", { value: undefined, enumerable: false });
    expect(() => parseRegistrationInput(hidden)).toThrow();
    let getterRan = false;
    const accessor = { ...valid };
    Object.defineProperty(accessor, "token", { get: () => { getterRan = true; return valid.token; } });
    expect(() => parseRegistrationInput(accessor)).toThrow();
    expect(getterRan).toBe(false);
    expect(() => parseRegistrationInput({ ...valid, platform: "ios" })).toThrow();
  });

  it("does not expose rejected values in validation errors", () => {
    const secret = "secret-payload-value";
    try { parseRegistrationInput({ ...valid, token: secret }); } catch (error) {
      expect(String(error)).not.toContain(secret);
    }
  });
});

describe("installation credential verifier", () => {
  it("uses a salted memory-hard verifier and timing-safe comparison", async () => {
    const verifier = await hashInstallationCredential("credential-value");
    expect(await verifyInstallationCredential("credential-value", verifier)).toBe(true);
    expect(await verifyInstallationCredential("wrong-value", verifier)).toBe(false);
  });
});
