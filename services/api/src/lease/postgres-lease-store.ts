import type { Pool, QueryResultRow } from "pg";

import type { CycleLease } from "./cycle-lease.js";

export const MINIMUM_LEASE_TTL_MS = 60_000;
const MAX_LEASE_KEY_LENGTH = 256;
const MAX_OWNER_ID_LENGTH = 128;

export interface LeaseRecord {
  leaseKey: string;
  ownerId: string;
  expiresAt: string;
}

export interface LeaseRequest {
  leaseKey: string;
  ownerId: string;
  ttlMs: number;
}

export interface LeaseStore {
  tryAcquire(request: LeaseRequest): Promise<LeaseRecord | null>;
  renew(request: LeaseRequest): Promise<LeaseRecord | null>;
  release(leaseKey: string, ownerId: string): Promise<boolean>;
}

interface LeaseRow extends QueryResultRow {
  lease_key: string;
  owner_id: string;
  expires_at: Date | string;
}

export class PostgresLeaseStore implements LeaseStore {
  public constructor(private readonly pool: Pool) {}

  public async tryAcquire(request: LeaseRequest): Promise<LeaseRecord | null> {
    validateLeaseRequest(request);
    try {
      const result = await this.pool.query<LeaseRow>(
        `INSERT INTO collector_leases (lease_key, owner_id, expires_at)
         VALUES ($1, $2, clock_timestamp() + ($3::double precision * interval '1 millisecond'))
         ON CONFLICT (lease_key) DO UPDATE
         SET owner_id = EXCLUDED.owner_id,
             expires_at = clock_timestamp() + ($3::double precision * interval '1 millisecond')
         WHERE collector_leases.expires_at <= clock_timestamp()
            OR collector_leases.owner_id = EXCLUDED.owner_id
         RETURNING lease_key, owner_id, expires_at`,
        [request.leaseKey, request.ownerId, request.ttlMs],
      );
      return result.rows[0] === undefined ? null : mapLease(result.rows[0]);
    } catch {
      throw new Error("PostgreSQL lease operation failed");
    }
  }

  public async renew(request: LeaseRequest): Promise<LeaseRecord | null> {
    validateLeaseRequest(request);
    try {
      const result = await this.pool.query<LeaseRow>(
        `UPDATE collector_leases
         SET expires_at = clock_timestamp() + ($3::double precision * interval '1 millisecond')
         WHERE lease_key = $1
           AND owner_id = $2
           AND expires_at > clock_timestamp()
         RETURNING lease_key, owner_id, expires_at`,
        [request.leaseKey, request.ownerId, request.ttlMs],
      );
      return result.rows[0] === undefined ? null : mapLease(result.rows[0]);
    } catch {
      throw new Error("PostgreSQL lease operation failed");
    }
  }

  public async release(leaseKey: string, ownerId: string): Promise<boolean> {
    validateLeaseIdentity(leaseKey, ownerId);
    try {
      const result = await this.pool.query(
        `DELETE FROM collector_leases
         WHERE lease_key = $1 AND owner_id = $2`,
        [leaseKey, ownerId],
      );
      return result.rowCount === 1;
    } catch {
      throw new Error("PostgreSQL lease operation failed");
    }
  }
}

export interface PostgresCycleLeaseOptions extends LeaseRequest {
  store: LeaseStore;
  scheduler?: Pick<typeof globalThis, "setTimeout" | "clearTimeout">;
}

export class PostgresCycleLease implements CycleLease {
  private readonly store: LeaseStore;
  private readonly request: LeaseRequest;
  private readonly scheduler: Pick<
    typeof globalThis,
    "setTimeout" | "clearTimeout"
  >;

  public constructor(options: PostgresCycleLeaseOptions) {
    validateLeaseRequest(options);
    this.store = options.store;
    this.request = {
      leaseKey: options.leaseKey,
      ownerId: options.ownerId,
      ttlMs: options.ttlMs,
    };
    this.scheduler = options.scheduler ?? globalThis;
  }

  public async runIfAcquired(
    action: (leaseSignal: AbortSignal) => Promise<void>,
  ): Promise<boolean> {
    const acquired = await this.store.tryAcquire(this.request);
    if (acquired === null) {
      return false;
    }

    const leaseAbortController = new AbortController();
    const heartbeatDelayMs = Math.max(
      1_000,
      Math.floor(this.request.ttlMs / 3),
    );
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let activeRenewal: Promise<void> | undefined;
    let renewalFailed = false;

    const scheduleRenewal = (): void => {
      timer = this.scheduler.setTimeout(() => {
        activeRenewal = (async () => {
          try {
            const renewed = await this.store.renew(this.request);
            if (renewed === null) {
              renewalFailed = true;
              leaseAbortController.abort();
              return;
            }
            if (!stopped) {
              scheduleRenewal();
            }
          } catch {
            renewalFailed = true;
            leaseAbortController.abort();
          }
        })();
      }, heartbeatDelayMs);
    };

    scheduleRenewal();
    let actionError: unknown;
    try {
      await action(leaseAbortController.signal);
    } catch (error) {
      actionError = error;
    } finally {
      stopped = true;
      if (timer !== undefined) {
        this.scheduler.clearTimeout(timer);
      }
      await activeRenewal;
      try {
        await this.store.release(this.request.leaseKey, this.request.ownerId);
      } catch {
        if (actionError === undefined) {
          actionError = new Error("PostgreSQL lease release failed");
        }
      }
    }

    if (actionError !== undefined) {
      throw actionError;
    }
    if (renewalFailed) {
      throw new Error("PostgreSQL lease was lost during collection");
    }
    return true;
  }
}

function validateLeaseRequest(request: LeaseRequest): void {
  validateLeaseIdentity(request.leaseKey, request.ownerId);
  if (
    !Number.isSafeInteger(request.ttlMs) ||
    request.ttlMs < MINIMUM_LEASE_TTL_MS
  ) {
    throw new RangeError(
      `ttlMs must be a safe integer greater than or equal to ${MINIMUM_LEASE_TTL_MS}`,
    );
  }
}

function validateLeaseIdentity(leaseKey: string, ownerId: string): void {
  if (
    typeof leaseKey !== "string" ||
    leaseKey.length === 0 ||
    leaseKey.length > MAX_LEASE_KEY_LENGTH
  ) {
    throw new TypeError("leaseKey is invalid");
  }
  if (
    typeof ownerId !== "string" ||
    ownerId.length === 0 ||
    ownerId.length > MAX_OWNER_ID_LENGTH
  ) {
    throw new TypeError("ownerId is invalid");
  }
}

function mapLease(row: LeaseRow): LeaseRecord {
  return {
    leaseKey: row.lease_key,
    ownerId: row.owner_id,
    expiresAt: toIsoTimestamp(row.expires_at),
  };
}

function toIsoTimestamp(value: Date | string): string {
  const parsed = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(parsed.valueOf())) {
    throw new Error("PostgreSQL returned an invalid lease timestamp");
  }
  return parsed.toISOString();
}
