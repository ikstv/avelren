import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";

const KEY_BYTES = 32;
const IV_BYTES = 12;
const TAG_BYTES = 16;

export interface EncryptedToken {
  readonly ciphertext: Buffer;
  readonly iv: Buffer;
  readonly authTag: Buffer;
  readonly keyId: string;
  readonly fingerprint: string;
}

export interface TokenKeyring {
  readonly activeKeyId: string;
  readonly encryptionKeys: ReadonlyMap<string, Buffer>;
  readonly fingerprintKey: Buffer;
}

const equalKeyMaterial = (left: Buffer, right: Buffer): boolean =>
  left.length === right.length && timingSafeEqual(left, right);

export function validateTokenKeyring(keyring: TokenKeyring): void {
  const activeKey = keyring.encryptionKeys.get(keyring.activeKeyId);
  if (!activeKey || activeKey.length !== KEY_BYTES ||
    keyring.fingerprintKey.length !== KEY_BYTES ||
    !/^[A-Za-z0-9._-]{1,64}$/.test(keyring.activeKeyId)) {
    throw new Error("Invalid push cryptography configuration");
  }
  const encryptionKeys = [...keyring.encryptionKeys.entries()];
  for (let index = 0; index < encryptionKeys.length; index += 1) {
    const entry = encryptionKeys[index];
    if (!entry) continue;
    const [keyId, key] = entry;
    if (!/^[A-Za-z0-9._-]{1,64}$/.test(keyId) || key.length !== KEY_BYTES) {
      throw new Error("Invalid push cryptography configuration");
    }
    if (equalKeyMaterial(key, keyring.fingerprintKey)) {
      throw new Error("Push cryptographic keys must be distinct");
    }
    for (let otherIndex = index + 1; otherIndex < encryptionKeys.length; otherIndex += 1) {
      const other = encryptionKeys[otherIndex];
      if (other && equalKeyMaterial(key, other[1])) {
        throw new Error("Push cryptographic keys must be distinct");
      }
    }
  }
}

export class TokenCrypto {
  public constructor(private readonly keyring: TokenKeyring) {
    validateTokenKeyring(keyring);
  }

  public encrypt(token: string): EncryptedToken {
    const key = this.keyring.encryptionKeys.get(this.keyring.activeKeyId);
    if (!key) throw new Error("Push encryption key is unavailable");
    const iv = randomBytes(IV_BYTES);
    const cipher = createCipheriv("aes-256-gcm", key, iv, { authTagLength: TAG_BYTES });
    const ciphertext = Buffer.concat([cipher.update(token, "utf8"), cipher.final()]);
    return {
      ciphertext,
      iv,
      authTag: cipher.getAuthTag(),
      keyId: this.keyring.activeKeyId,
      fingerprint: this.fingerprint(token),
    };
  }

  public decrypt(encrypted: Omit<EncryptedToken, "fingerprint">): string {
    const key = this.keyring.encryptionKeys.get(encrypted.keyId);
    if (!key || encrypted.iv.length !== IV_BYTES || encrypted.authTag.length !== TAG_BYTES) {
      throw new Error("Stored push token cannot be decrypted");
    }
    try {
      const decipher = createDecipheriv("aes-256-gcm", key, encrypted.iv, { authTagLength: TAG_BYTES });
      decipher.setAuthTag(encrypted.authTag);
      return Buffer.concat([decipher.update(encrypted.ciphertext), decipher.final()]).toString("utf8");
    } catch {
      throw new Error("Stored push token cannot be decrypted");
    }
  }

  public fingerprint(token: string): string {
    return createHmac("sha256", this.keyring.fingerprintKey).update(token, "utf8").digest("hex");
  }

  public fingerprintsEqual(left: string, right: string): boolean {
    const a = Buffer.from(left, "hex");
    const b = Buffer.from(right, "hex");
    return a.length === b.length && timingSafeEqual(a, b);
  }
}
