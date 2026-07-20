import type { Pool, PoolClient, QueryResultRow } from "pg";

import type {
  CollectorMutation,
  CollectorMutationBuilder,
  CollectorTransactionStore,
  ObservationApplyResult,
} from "../collector/collector-transaction-store.js";
import {
  deriveObservationId,
  normalizeSourceObservation,
  type SourceObservation,
} from "../collector/source-observation.js";
import type {
  SnapshotState,
  SnapshotStore,
} from "../collector/snapshot-store.js";
import {
  deriveThresholdEventId,
  type PendingThresholdEvent,
  type ThresholdEventStore,
} from "../collector/threshold-event-store.js";
import {
  MAX_VEHICLE_COUNT,
  validateWorkloadSnapshot,
} from "../workload/workload.js";

export const DEFAULT_OUTBOX_BATCH_SIZE = 100;
export const MAX_OUTBOX_BATCH_SIZE = 1_000;
const EVENT_INSERT_BATCH_SIZE = 100;
const SHA256_HEX_PATTERN = /^[0-9a-f]{64}$/u;

interface SnapshotRow extends QueryResultRow {
  location_id: string;
  vehicle_count: number;
  observed_at: Date | string;
  received_at: Date | string;
  freshness: "fresh" | "stale" | "unknown";
  sequence: string | number;
  latest_observation_id: string | null;
}

interface EventRow extends QueryResultRow {
  event_id: string;
  location_id: string;
  threshold_value: number;
  previous_vehicle_count: number;
  current_vehicle_count: number;
  observed_at: Date | string;
  created_at: Date | string;
  status: "pending";
}

export class PostgresCollectorStore
  implements SnapshotStore, ThresholdEventStore, CollectorTransactionStore
{
  public constructor(private readonly pool: Pool) {}

  public async get(locationId: string): Promise<SnapshotState | null> {
    validateLocationId(locationId);
    try {
      return await readSnapshot(this.pool, locationId, false);
    } catch {
      throw storageError();
    }
  }

  public async getLatest(): Promise<SnapshotState | null> {
    try {
      const result = await this.pool.query<SnapshotRow>(
        `${SNAPSHOT_SELECT}
         ORDER BY received_at DESC, sequence DESC
         LIMIT 1`,
      );
      return result.rows[0] === undefined ? null : mapSnapshot(result.rows[0]);
    } catch {
      throw storageError();
    }
  }

  public async set(state: SnapshotState): Promise<void> {
    validateSnapshotState(state);
    const client = await connect(this.pool);
    try {
      await client.query("BEGIN");
      await lockLocation(client, state.snapshot.locationId);
      await upsertSnapshot(client, state);
      await client.query("COMMIT");
    } catch {
      await rollbackQuietly(client);
      throw storageError();
    } finally {
      client.release();
    }
  }

  public async addPending(events: PendingThresholdEvent[]): Promise<void> {
    for (const event of events) {
      validatePendingEvent(event);
    }
    if (events.length === 0) {
      return;
    }

    const client = await connect(this.pool);
    try {
      await client.query("BEGIN");
      await insertPendingEvents(client, events);
      await client.query("COMMIT");
    } catch {
      await rollbackQuietly(client);
      throw storageError();
    } finally {
      client.release();
    }
  }

  public async getAllPending(
    limit = DEFAULT_OUTBOX_BATCH_SIZE,
  ): Promise<PendingThresholdEvent[]> {
    validateBatchLimit(limit);
    try {
      const result = await this.pool.query<EventRow>(
        `SELECT event_id, location_id, threshold_value,
                previous_vehicle_count, current_vehicle_count,
                observed_at, created_at, status
         FROM threshold_events
         WHERE status = 'pending'
         ORDER BY created_at, threshold_value, event_id
         LIMIT $1`,
        [limit],
      );
      return result.rows.map(mapEvent);
    } catch {
      throw storageError();
    }
  }

  public async removePending(eventIds: string[]): Promise<void> {
    for (const eventId of eventIds) {
      validateSha256Id(eventId, "eventId");
    }
    if (eventIds.length === 0) {
      return;
    }
    try {
      await this.pool.query(
        `DELETE FROM threshold_events
         WHERE status = 'pending' AND event_id = ANY($1::text[])`,
        [eventIds],
      );
    } catch {
      throw storageError();
    }
  }

  public async applyObservation(
    observation: SourceObservation,
    observationId: string,
    buildMutation: CollectorMutationBuilder,
  ): Promise<ObservationApplyResult> {
    const normalized = normalizeSourceObservation(observation);
    validateSha256Id(observationId, "observationId");
    if (deriveObservationId(normalized) !== observationId) {
      throw new TypeError("observationId does not match the observation");
    }

    const client = await connect(this.pool);
    try {
      await client.query("BEGIN");
      await lockLocation(client, normalized.locationId);

      const inserted = await client.query(
        `INSERT INTO collector_observations
           (observation_id, location_id, vehicle_count, observed_at)
         VALUES ($1, $2, $3, $4::timestamptz)
         ON CONFLICT (observation_id) DO NOTHING
         RETURNING observation_id`,
        [
          observationId,
          normalized.locationId,
          normalized.vehicleCount,
          normalized.observedAt,
        ],
      );
      if (inserted.rowCount === 0) {
        await client.query("COMMIT");
        return "duplicate";
      }

      const current = await readSnapshot(client, normalized.locationId, true);
      const mutation = await buildMutation(current);
      if (mutation === null) {
        await client.query("COMMIT");
        return "ignored";
      }

      validateMutation(mutation, normalized, observationId);
      await insertPendingEvents(client, mutation.events);
      await upsertSnapshot(client, mutation.state);
      await client.query("COMMIT");
      return "applied";
    } catch {
      await rollbackQuietly(client);
      throw storageError();
    } finally {
      client.release();
    }
  }
}

const SNAPSHOT_SELECT = `SELECT location_id, vehicle_count, observed_at,
                                received_at, freshness, sequence,
                                latest_observation_id
                         FROM collector_snapshots`;

async function connect(pool: Pool): Promise<PoolClient> {
  try {
    return await pool.connect();
  } catch {
    throw storageError();
  }
}

async function readSnapshot(
  queryable: Pool | PoolClient,
  locationId: string,
  forUpdate: boolean,
): Promise<SnapshotState | null> {
  const result = await queryable.query<SnapshotRow>(
    `${SNAPSHOT_SELECT}
     WHERE location_id = $1${forUpdate ? " FOR UPDATE" : ""}`,
    [locationId],
  );
  return result.rows[0] === undefined ? null : mapSnapshot(result.rows[0]);
}

async function lockLocation(client: PoolClient, locationId: string): Promise<void> {
  await client.query(
    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
    [locationId],
  );
}

async function upsertSnapshot(
  client: PoolClient,
  state: SnapshotState,
): Promise<void> {
  const result = await client.query(
    `INSERT INTO collector_snapshots
       (location_id, vehicle_count, observed_at, received_at,
        freshness, sequence, latest_observation_id)
     VALUES ($1, $2, $3::timestamptz, $4::timestamptz, $5, $6, $7)
     ON CONFLICT (location_id) DO UPDATE
     SET vehicle_count = EXCLUDED.vehicle_count,
         observed_at = EXCLUDED.observed_at,
         received_at = EXCLUDED.received_at,
         freshness = EXCLUDED.freshness,
         sequence = EXCLUDED.sequence,
         latest_observation_id = EXCLUDED.latest_observation_id
     WHERE collector_snapshots.sequence < EXCLUDED.sequence
     RETURNING location_id`,
    [
      state.snapshot.locationId,
      state.snapshot.vehicleCount,
      state.snapshot.observedAt,
      state.snapshot.receivedAt,
      state.snapshot.freshness,
      state.snapshot.sequence,
      state.latestObservationId,
    ],
  );
  if (result.rowCount !== 1) {
    throw new Error("Snapshot sequence conflict");
  }
}

async function insertPendingEvents(
  client: PoolClient,
  events: PendingThresholdEvent[],
): Promise<void> {
  for (let offset = 0; offset < events.length; offset += EVENT_INSERT_BATCH_SIZE) {
    const batch = events.slice(offset, offset + EVENT_INSERT_BATCH_SIZE);
    const values: unknown[] = [];
    const rows = batch.map((event, index) => {
      const base = index * 8;
      values.push(
        event.eventId,
        event.locationId,
        event.threshold,
        event.previousVehicleCount,
        event.currentVehicleCount,
        event.observedAt,
        event.createdAt,
        event.status,
      );
      return `($${base + 1}, $${base + 2}, $${base + 3}, $${base + 4}, $${base + 5}, $${base + 6}::timestamptz, $${base + 7}::timestamptz, $${base + 8})`;
    });

    await client.query(
      `INSERT INTO threshold_events
         (event_id, location_id, threshold_value, previous_vehicle_count,
          current_vehicle_count, observed_at, created_at, status)
       VALUES ${rows.join(", ")}
       ON CONFLICT DO NOTHING`,
      values,
    );
  }
}

function validateMutation(
  mutation: CollectorMutation,
  observation: SourceObservation,
  observationId: string,
): void {
  validateSnapshotState(mutation.state);
  const snapshot = mutation.state.snapshot;
  if (
    snapshot.locationId !== observation.locationId ||
    snapshot.vehicleCount !== observation.vehicleCount ||
    snapshot.observedAt !== observation.observedAt ||
    mutation.state.latestObservationId !== observationId
  ) {
    throw new TypeError("Collector mutation does not match the observation");
  }
  for (const event of mutation.events) {
    validatePendingEvent(event);
    if (
      event.locationId !== observation.locationId ||
      event.observedAt !== observation.observedAt
    ) {
      throw new TypeError("Threshold event does not match the observation");
    }
  }
}

function validateSnapshotState(state: SnapshotState): void {
  validateWorkloadSnapshot(state.snapshot);
  if (state.latestObservationId !== null) {
    validateSha256Id(state.latestObservationId, "latestObservationId");
  }
}

function validatePendingEvent(event: PendingThresholdEvent): void {
  validateSha256Id(event.eventId, "eventId");
  validateLocationId(event.locationId);
  for (const value of [
    event.threshold,
    event.previousVehicleCount,
    event.currentVehicleCount,
  ]) {
    if (!Number.isSafeInteger(value) || value < 0 || value > MAX_VEHICLE_COUNT) {
      throw new TypeError("Threshold event count is invalid");
    }
  }
  if (
    event.threshold === 0 ||
    event.previousVehicleCount >= event.threshold ||
    event.currentVehicleCount < event.threshold ||
    event.status !== "pending"
  ) {
    throw new TypeError("Threshold event is invalid");
  }
  validateTimestamp(event.observedAt, "observedAt");
  validateTimestamp(event.createdAt, "createdAt");
  const expectedId = deriveThresholdEventId({
    locationId: event.locationId,
    threshold: event.threshold,
    previousVehicleCount: event.previousVehicleCount,
    currentVehicleCount: event.currentVehicleCount,
    observedAt: event.observedAt,
    createdAt: event.createdAt,
  });
  if (expectedId !== event.eventId) {
    throw new TypeError("eventId does not match the threshold event");
  }
}

function validateBatchLimit(limit: number): void {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_OUTBOX_BATCH_SIZE) {
    throw new RangeError(
      `limit must be between 1 and ${MAX_OUTBOX_BATCH_SIZE}`,
    );
  }
}

function validateLocationId(locationId: string): void {
  if (
    typeof locationId !== "string" ||
    locationId.trim().length === 0 ||
    locationId.length > 128
  ) {
    throw new TypeError("locationId is invalid");
  }
}

function validateSha256Id(value: string, field: string): void {
  if (typeof value !== "string" || !SHA256_HEX_PATTERN.test(value)) {
    throw new TypeError(`${field} must be a SHA-256 identifier`);
  }
}

function validateTimestamp(value: string, field: string): void {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf()) || parsed.toISOString() !== value) {
    throw new TypeError(`${field} must be an ISO 8601 UTC timestamp`);
  }
}

function mapSnapshot(row: SnapshotRow): SnapshotState {
  const state: SnapshotState = {
    snapshot: {
      locationId: row.location_id,
      vehicleCount: row.vehicle_count,
      observedAt: toIsoTimestamp(row.observed_at),
      receivedAt: toIsoTimestamp(row.received_at),
      freshness: row.freshness,
      sequence: Number(row.sequence),
    },
    latestObservationId: row.latest_observation_id,
  };
  validateSnapshotState(state);
  return state;
}

function mapEvent(row: EventRow): PendingThresholdEvent {
  const event: PendingThresholdEvent = {
    eventId: row.event_id,
    locationId: row.location_id,
    threshold: row.threshold_value,
    previousVehicleCount: row.previous_vehicle_count,
    currentVehicleCount: row.current_vehicle_count,
    observedAt: toIsoTimestamp(row.observed_at),
    createdAt: toIsoTimestamp(row.created_at),
    status: row.status,
  };
  validatePendingEvent(event);
  return event;
}

function toIsoTimestamp(value: Date | string): string {
  const parsed = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(parsed.valueOf())) {
    throw storageError();
  }
  return parsed.toISOString();
}

async function rollbackQuietly(client: PoolClient): Promise<void> {
  try {
    await client.query("ROLLBACK");
  } catch {
    // The original normalized storage error remains authoritative.
  }
}

function storageError(): Error {
  return new Error("PostgreSQL storage operation failed");
}
