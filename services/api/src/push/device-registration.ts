import type { Pool, PoolClient } from "pg";
import { generateInstallationCredential, hashInstallationCredential,
  verifyInstallationCredential } from "./credential-hasher.js";
import { PayloadValidationError, readExactObject } from "./exact-object.js";
import type { TokenCrypto } from "./token-crypto.js";

const INSTALLATION_PATTERN = /^[A-Za-z0-9_-]{22,128}$/;
const TOKEN_PATTERN = /^[A-Za-z0-9_:.\-]{20,4096}$/;
const LOCALE_PATTERN = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/;

export interface RegistrationInput {
  readonly installationId: string;
  readonly token: string;
  readonly platform: "android";
  readonly locale: string;
}

const stringField = (object: Readonly<Record<string, unknown>>, field: string,
  pattern: RegExp): string => {
  const value = object[field];
  if (typeof value !== "string" || !pattern.test(value)) throw new PayloadValidationError();
  return value;
};

export function parseRegistrationInput(value: unknown): RegistrationInput {
  const object = readExactObject(value, ["installationId", "token", "platform", "locale"]);
  if (object.platform !== "android") throw new PayloadValidationError();
  return {
    installationId: stringField(object, "installationId", INSTALLATION_PATTERN),
    token: stringField(object, "token", TOKEN_PATTERN),
    platform: "android",
    locale: stringField(object, "locale", LOCALE_PATTERN),
  };
}

export function parseTokenInput(value: unknown): Readonly<{ token: string }> {
  const object = readExactObject(value, ["token"]);
  return { token: stringField(object, "token", TOKEN_PATTERN) };
}

export function parseHeartbeatInput(value: unknown): Readonly<{ locale: string }> {
  const object = readExactObject(value, ["locale"]);
  return { locale: stringField(object, "locale", LOCALE_PATTERN) };
}

export function parseInstallationId(value: unknown): string {
  if (typeof value !== "string" || !INSTALLATION_PATTERN.test(value)) {
    throw new PayloadValidationError();
  }
  return value;
}

interface CredentialRow {
  readonly id: string;
  readonly credential_salt: Buffer;
  readonly credential_hash: Buffer;
}

export class DeviceAuthenticationError extends Error {
  constructor() {
    super("Installation authentication failed");
    this.name = "DeviceAuthenticationError";
  }
}

export class PostgresDeviceRegistrationService {
  public constructor(private readonly pool: Pool, private readonly tokenCrypto: TokenCrypto) {}

  public async register(input: RegistrationInput): Promise<Readonly<{
    status: "registered";
    installationCredential?: string;
  }>> {
    const encrypted = this.tokenCrypto.encrypt(input.token);
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const inserted = await client.query<{ id: string }>(
        `INSERT INTO push_devices (
           installation_id, token_ciphertext, token_iv, token_auth_tag,
           token_fingerprint, encryption_key_id, credential_salt, credential_hash,
           platform, locale
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
         ON CONFLICT DO NOTHING
         RETURNING id::text`,
        [input.installationId, encrypted.ciphertext, encrypted.iv, encrypted.authTag,
          encrypted.fingerprint, encrypted.keyId, Buffer.alloc(16), Buffer.alloc(32),
          input.platform, input.locale],
      );
      const row = inserted.rows[0];
      if (!row) {
        await client.query("COMMIT");
        return { status: "registered" };
      }

      const credential = generateInstallationCredential();
      const verifier = await hashInstallationCredential(credential);
      const updated = await client.query(
        `UPDATE push_devices SET credential_salt = $1, credential_hash = $2
         WHERE id = $3`,
        [verifier.salt, verifier.hash, row.id],
      );
      if (updated.rowCount !== 1) throw new Error("Push registration failed");
      await client.query("COMMIT");
      return { status: "registered", installationCredential: credential };
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  public async rotateToken(installationId: string, credential: string, token: string): Promise<void> {
    const encrypted = this.tokenCrypto.encrypt(token);
    await this.authenticatedTransaction(installationId, credential, async (client, row) => {
      await client.query(
        `UPDATE push_devices SET token_ciphertext = $1, token_iv = $2, token_auth_tag = $3,
           token_fingerprint = $4, encryption_key_id = $5, enabled = TRUE,
           disabled_at = NULL, disabled_reason = NULL, updated_at = clock_timestamp(),
           last_seen_at = clock_timestamp() WHERE id = $6`,
        [encrypted.ciphertext, encrypted.iv, encrypted.authTag, encrypted.fingerprint,
          encrypted.keyId, row.id],
      );
    });
  }

  public async heartbeat(installationId: string, credential: string, locale: string): Promise<void> {
    await this.authenticatedTransaction(installationId, credential, async (client, row) => {
      await client.query(
        `UPDATE push_devices SET locale = $1, last_seen_at = clock_timestamp(),
         updated_at = clock_timestamp() WHERE id = $2`, [locale, row.id],
      );
    });
  }

  public async disable(installationId: string, credential: string): Promise<void> {
    await this.authenticatedTransaction(installationId, credential, async (client, row) => {
      await client.query(
        `UPDATE push_devices SET enabled = FALSE,
         disabled_at = COALESCE(disabled_at, clock_timestamp()),
         disabled_reason = COALESCE(disabled_reason, 'client_request'),
         updated_at = clock_timestamp() WHERE id = $1`, [row.id],
      );
    });
  }

  private async authenticatedTransaction(installationId: string, credential: string,
    operation: (client: PoolClient, row: CredentialRow) => Promise<void>): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await client.query<CredentialRow>(
        `SELECT id::text, credential_salt, credential_hash FROM push_devices
         WHERE installation_id = $1 FOR UPDATE`, [installationId],
      );
      const row = result.rows[0];
      const valid = row
        ? await verifyInstallationCredential(credential, {
            salt: row.credential_salt, hash: row.credential_hash,
          })
        : await verifyInstallationCredential(credential, {
            salt: Buffer.alloc(16), hash: Buffer.alloc(32),
          });
      if (!row || !valid) throw new DeviceAuthenticationError();
      await operation(client, row);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }
}
