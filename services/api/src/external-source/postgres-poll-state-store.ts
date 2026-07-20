import type { Pool, QueryResultRow } from "pg";
import type { ExternalSourceCacheMetadata } from "./external-source-adapter.js";

export interface PollReservation extends ExternalSourceCacheMetadata { sourceKey: string; ownerId: string }
export interface PollReservationRequest { sourceKey: string; ownerId: string; minimumIntervalMs: number; claimTtlMs: number }
export interface PollFailurePolicy {
  minimumIntervalMs: number; backoffBaseMs: number; backoffMaxMs: number;
  circuitFailures: number; circuitOpenMs: number; retryAfterMs?: number;
}
export interface ExternalSourcePollStateStore {
  tryReserve(request: PollReservationRequest): Promise<PollReservation | null>;
  recordSuccess(reservation: PollReservation, metadata: ExternalSourceCacheMetadata): Promise<boolean>;
  recordFailure(reservation: PollReservation, policy: PollFailurePolicy): Promise<boolean>;
}
interface PollStateRow extends QueryResultRow { etag: string | null; last_modified: string | null }

export class PostgresExternalSourcePollStateStore implements ExternalSourcePollStateStore {
  public constructor(private readonly pool: Pool) {}

  public async tryReserve(request: PollReservationRequest): Promise<PollReservation | null> {
    validateReservation(request);
    try {
      const result = await this.pool.query<PollStateRow>(
        `INSERT INTO external_source_poll_state (
           source_key, next_allowed_at, last_attempt_at, claim_owner, claim_expires_at
         ) VALUES (
           $1, clock_timestamp() + ($3::double precision * interval '1 millisecond'),
           clock_timestamp(), $2,
           clock_timestamp() + ($4::double precision * interval '1 millisecond')
         )
         ON CONFLICT (source_key) DO UPDATE SET
           next_allowed_at = clock_timestamp() + ($3::double precision * interval '1 millisecond'),
           last_attempt_at = clock_timestamp(), claim_owner = $2,
           claim_expires_at = clock_timestamp() + ($4::double precision * interval '1 millisecond'),
           updated_at = clock_timestamp()
         WHERE external_source_poll_state.next_allowed_at <= clock_timestamp()
           AND (external_source_poll_state.circuit_open_until IS NULL
                OR external_source_poll_state.circuit_open_until <= clock_timestamp())
           AND (external_source_poll_state.claim_expires_at IS NULL
                OR external_source_poll_state.claim_expires_at <= clock_timestamp())
         RETURNING etag, last_modified`,
        [request.sourceKey, request.ownerId, request.minimumIntervalMs, request.claimTtlMs],
      );
      const row = result.rows[0];
      if (row === undefined) return null;
      return {
        sourceKey: request.sourceKey, ownerId: request.ownerId,
        ...(row.etag === null ? {} : { etag: row.etag }),
        ...(row.last_modified === null ? {} : { lastModified: row.last_modified }),
      };
    } catch { throw stateError(); }
  }

  public async recordSuccess(reservation: PollReservation, metadata: ExternalSourceCacheMetadata): Promise<boolean> {
    try {
      const result = await this.pool.query(
        `UPDATE external_source_poll_state SET
           last_success_at = clock_timestamp(), etag = $3, last_modified = $4,
           consecutive_failures = 0, circuit_open_until = NULL,
           claim_owner = NULL, claim_expires_at = NULL, updated_at = clock_timestamp()
         WHERE source_key = $1 AND claim_owner = $2 AND claim_expires_at > clock_timestamp()`,
        [reservation.sourceKey, reservation.ownerId, metadata.etag ?? null, metadata.lastModified ?? null],
      );
      return result.rowCount === 1;
    } catch { throw stateError(); }
  }

  public async recordFailure(reservation: PollReservation, policy: PollFailurePolicy): Promise<boolean> {
    validateFailurePolicy(policy);
    try {
      const result = await this.pool.query(
        `UPDATE external_source_poll_state SET
           consecutive_failures = consecutive_failures + 1,
           next_allowed_at = GREATEST(next_allowed_at, clock_timestamp() + (GREATEST(
             $3::double precision, $4::double precision,
             LEAST($6::double precision,
               $5::double precision * power(2::double precision, LEAST(consecutive_failures, 20)))
           ) * interval '1 millisecond')),
           circuit_open_until = CASE WHEN consecutive_failures + 1 >= $7
             THEN clock_timestamp() + ($8::double precision * interval '1 millisecond')
             ELSE circuit_open_until END,
           claim_owner = NULL, claim_expires_at = NULL, updated_at = clock_timestamp()
         WHERE source_key = $1 AND claim_owner = $2 AND claim_expires_at > clock_timestamp()`,
        [reservation.sourceKey, reservation.ownerId, policy.minimumIntervalMs,
          policy.retryAfterMs ?? 0, policy.backoffBaseMs, policy.backoffMaxMs,
          policy.circuitFailures, policy.circuitOpenMs],
      );
      return result.rowCount === 1;
    } catch { throw stateError(); }
  }
}

function stateError(): Error { return new Error("External source polling state operation failed"); }

function validateReservation(request: PollReservationRequest): void {
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/u.test(request.sourceKey) ||
      !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/u.test(request.ownerId) ||
      !safeDuration(request.minimumIntervalMs) || !safeDuration(request.claimTtlMs)) {
    throw stateError();
  }
}

function validateFailurePolicy(policy: PollFailurePolicy): void {
  if (!safeDuration(policy.minimumIntervalMs) || !safeDuration(policy.backoffBaseMs) ||
      !safeDuration(policy.backoffMaxMs) || policy.backoffMaxMs < policy.backoffBaseMs ||
      !safeDuration(policy.circuitOpenMs) || !Number.isSafeInteger(policy.circuitFailures) ||
      policy.circuitFailures < 1 || policy.circuitFailures > 100 ||
      (policy.retryAfterMs !== undefined &&
       (!Number.isSafeInteger(policy.retryAfterMs) || policy.retryAfterMs < 0 || policy.retryAfterMs > 86_400_000))) {
    throw stateError();
  }
}

function safeDuration(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 60_000 && value <= 86_400_000;
}
