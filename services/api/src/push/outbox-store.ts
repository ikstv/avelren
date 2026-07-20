import type { Pool } from "pg";

export interface ClaimedNotification {
  readonly id: string;
  readonly deviceId: string;
  readonly attemptCount: number;
  readonly payload: Readonly<Record<string, unknown>>;
  readonly ciphertext: Buffer;
  readonly iv: Buffer;
  readonly authTag: Buffer;
  readonly keyId: string;
}

export interface NotificationOutboxStore {
  claim(owner: string, limit: number, claimTtlMs: number): Promise<readonly ClaimedNotification[]>;
  markSent(id: string, owner: string, messageId: string): Promise<boolean>;
  reschedule(id: string, owner: string, delayMs: number, errorCode: string): Promise<boolean>;
  markPermanentFailure(id: string, owner: string, errorCode: string): Promise<boolean>;
  disableInvalidToken(id: string, owner: string): Promise<boolean>;
}

interface OutboxRow {
  readonly id: string;
  readonly device_id: string;
  readonly attempt_count: number;
  readonly payload: Readonly<Record<string, unknown>>;
  readonly token_ciphertext: Buffer;
  readonly token_iv: Buffer;
  readonly token_auth_tag: Buffer;
  readonly encryption_key_id: string;
}

export class PostgresNotificationOutboxStore implements NotificationOutboxStore {
  public constructor(private readonly pool: Pool) {}

  public async claim(owner: string, limit: number, claimTtlMs: number): Promise<readonly ClaimedNotification[]> {
    const result = await this.pool.query<OutboxRow>(
      `WITH candidates AS (
         SELECT outbox.id FROM notification_outbox AS outbox
         JOIN push_devices AS device ON device.id = outbox.device_id
         WHERE device.enabled = TRUE
           AND outbox.available_at <= clock_timestamp()
           AND (outbox.status = 'pending' OR
             (outbox.status = 'claimed' AND outbox.claim_expires_at <= clock_timestamp()))
         ORDER BY outbox.available_at, outbox.id
         FOR UPDATE OF outbox SKIP LOCKED
         LIMIT $2
       ), claimed AS (
         UPDATE notification_outbox AS outbox
         SET status = 'claimed', claim_owner = $1,
             claim_expires_at = clock_timestamp() + ($3 * interval '1 millisecond'),
             attempt_count = outbox.attempt_count + 1
         FROM candidates WHERE outbox.id = candidates.id
         RETURNING outbox.*
       )
       SELECT claimed.id::text, claimed.device_id::text, claimed.attempt_count,
         claimed.payload, device.token_ciphertext, device.token_iv,
         device.token_auth_tag, device.encryption_key_id
       FROM claimed JOIN push_devices AS device ON device.id = claimed.device_id`,
      [owner, limit, claimTtlMs],
    );
    return result.rows.map((row) => ({
      id: row.id,
      deviceId: row.device_id,
      attemptCount: row.attempt_count,
      payload: row.payload,
      ciphertext: Buffer.from(row.token_ciphertext),
      iv: Buffer.from(row.token_iv),
      authTag: Buffer.from(row.token_auth_tag),
      keyId: row.encryption_key_id,
    }));
  }

  public async markSent(id: string, owner: string, messageId: string): Promise<boolean> {
    const result = await this.pool.query(
      `UPDATE notification_outbox SET status = 'sent', sent_at = clock_timestamp(),
       provider_message_id = $3, last_error_code = NULL,
       claim_owner = NULL, claim_expires_at = NULL
       WHERE id = $1 AND status = 'claimed' AND claim_owner = $2
         AND claim_expires_at > clock_timestamp()`, [id, owner, messageId],
    );
    return result.rowCount === 1;
  }

  public async reschedule(id: string, owner: string, delayMs: number, errorCode: string): Promise<boolean> {
    const result = await this.pool.query(
      `UPDATE notification_outbox SET status = 'pending',
       available_at = clock_timestamp() + ($3 * interval '1 millisecond'),
       last_error_code = $4, claim_owner = NULL, claim_expires_at = NULL
       WHERE id = $1 AND status = 'claimed' AND claim_owner = $2
         AND claim_expires_at > clock_timestamp()`, [id, owner, delayMs, errorCode],
    );
    return result.rowCount === 1;
  }

  public async markPermanentFailure(id: string, owner: string, errorCode: string): Promise<boolean> {
    const result = await this.pool.query(
      `UPDATE notification_outbox SET status = 'failed', last_error_code = $3,
       claim_owner = NULL, claim_expires_at = NULL
       WHERE id = $1 AND status = 'claimed' AND claim_owner = $2
         AND claim_expires_at > clock_timestamp()`, [id, owner, errorCode],
    );
    return result.rowCount === 1;
  }

  public async disableInvalidToken(id: string, owner: string): Promise<boolean> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const outbox = await client.query<{ device_id: string }>(
        `UPDATE notification_outbox SET status = 'failed', last_error_code = 'invalid_token',
         claim_owner = NULL, claim_expires_at = NULL
         WHERE id = $1 AND status = 'claimed' AND claim_owner = $2
           AND claim_expires_at > clock_timestamp()
         RETURNING device_id::text`, [id, owner],
      );
      const row = outbox.rows[0];
      if (!row) {
        await client.query("ROLLBACK");
        return false;
      }
      await client.query(
        `UPDATE push_devices SET enabled = FALSE, disabled_at = clock_timestamp(),
         disabled_reason = 'invalid_token', updated_at = clock_timestamp()
         WHERE id = $1`, [row.device_id],
      );
      await client.query("COMMIT");
      return true;
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }
}
