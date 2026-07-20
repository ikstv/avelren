import { randomBytes, scrypt as nodeScrypt, timingSafeEqual } from "node:crypto";
const SALT_BYTES = 16;
const HASH_BYTES = 32;

export interface CredentialVerifier {
  readonly salt: Buffer;
  readonly hash: Buffer;
}

export function generateInstallationCredential(): string {
  return randomBytes(32).toString("base64url");
}

export async function hashInstallationCredential(
  credential: string,
  salt: Buffer = randomBytes(SALT_BYTES),
): Promise<CredentialVerifier> {
  const hash = await new Promise<Buffer>((resolve, reject) => {
    nodeScrypt(credential, salt, HASH_BYTES, {
      N: 16_384, r: 8, p: 1, maxmem: 64 * 1024 * 1024,
    }, (error, derivedKey) => {
      if (error) reject(error);
      else resolve(derivedKey);
    });
  });
  return { salt: Buffer.from(salt), hash };
}

export async function verifyInstallationCredential(
  credential: string,
  verifier: CredentialVerifier,
): Promise<boolean> {
  const candidate = await hashInstallationCredential(credential, verifier.salt);
  return candidate.hash.length === verifier.hash.length &&
    timingSafeEqual(candidate.hash, verifier.hash);
}
