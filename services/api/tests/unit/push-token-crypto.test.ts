import { describe, expect, it } from "vitest";
import { TokenCrypto } from "../../src/push/token-crypto.js";

const key = (byte: number): Buffer => Buffer.alloc(32, byte);
const crypto = new TokenCrypto({
  activeKeyId: "current",
  encryptionKeys: new Map([["current", key(1)], ["old", key(2)]]),
  fingerprintKey: key(3),
});

describe("TokenCrypto", () => {
  it("encrypts with AES-GCM without retaining plaintext", () => {
    const encrypted = crypto.encrypt("device-token-value-12345");
    expect(encrypted.ciphertext.toString("utf8")).not.toContain("device-token");
    expect(crypto.decrypt(encrypted)).toBe("device-token-value-12345");
  });

  it("creates stable keyed fingerprints", () => {
    expect(crypto.fingerprint("same-token")).toBe(crypto.fingerprint("same-token"));
    expect(crypto.fingerprint("same-token")).not.toBe(crypto.fingerprint("other-token"));
  });

  it("rejects tampered ciphertext without exposing token data", () => {
    const encrypted = crypto.encrypt("sensitive-device-token");
    encrypted.ciphertext[0] = (encrypted.ciphertext[0] ?? 0) ^ 1;
    expect(() => crypto.decrypt(encrypted)).toThrow("Stored push token cannot be decrypted");
    try { crypto.decrypt(encrypted); } catch (error) {
      expect(String(error)).not.toContain("sensitive-device-token");
    }
  });

  it("decrypts data encrypted by a retained rotation key", () => {
    const old = new TokenCrypto({
      activeKeyId: "old", encryptionKeys: new Map([["old", key(2)]]), fingerprintKey: key(3),
    });
    expect(crypto.decrypt(old.encrypt("rotated-token-value"))).toBe("rotated-token-value");
  });
});
