CREATE TABLE collector_observations (
  observation_id char(64) PRIMARY KEY,
  location_id varchar(128) NOT NULL,
  vehicle_count integer NOT NULL CHECK (vehicle_count BETWEEN 0 AND 1000000),
  observed_at timestamptz NOT NULL,
  processed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX collector_observations_location_time_idx
  ON collector_observations (location_id, observed_at DESC);

CREATE TABLE collector_snapshots (
  location_id varchar(128) PRIMARY KEY,
  vehicle_count integer NOT NULL CHECK (vehicle_count BETWEEN 0 AND 1000000),
  observed_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL,
  freshness varchar(7) NOT NULL CHECK (freshness IN ('fresh', 'stale', 'unknown')),
  sequence bigint NOT NULL CHECK (sequence >= 0),
  latest_observation_id char(64) UNIQUE
    REFERENCES collector_observations (observation_id)
);

CREATE INDEX collector_snapshots_latest_idx
  ON collector_snapshots (received_at DESC, sequence DESC);

CREATE TABLE threshold_events (
  event_id char(64) PRIMARY KEY,
  location_id varchar(128) NOT NULL,
  threshold_value integer NOT NULL CHECK (threshold_value BETWEEN 1 AND 1000000),
  previous_vehicle_count integer NOT NULL
    CHECK (previous_vehicle_count BETWEEN 0 AND 1000000),
  current_vehicle_count integer NOT NULL
    CHECK (current_vehicle_count BETWEEN 0 AND 1000000),
  observed_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL,
  status varchar(7) NOT NULL CHECK (status = 'pending'),
  CONSTRAINT threshold_events_identity_unique UNIQUE
    (location_id, threshold_value, previous_vehicle_count,
     current_vehicle_count, observed_at),
  CONSTRAINT threshold_events_crossing_check CHECK
    (previous_vehicle_count < threshold_value
     AND current_vehicle_count >= threshold_value)
);

CREATE INDEX threshold_events_pending_idx
  ON threshold_events (created_at, event_id)
  WHERE status = 'pending';

CREATE TABLE collector_leases (
  lease_key varchar(256) PRIMARY KEY,
  owner_id varchar(128) NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE INDEX collector_leases_expiry_idx ON collector_leases (expires_at);
