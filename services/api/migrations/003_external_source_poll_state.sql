CREATE TABLE external_source_poll_state (
  source_key varchar(64) PRIMARY KEY,
  next_allowed_at timestamptz NOT NULL,
  last_attempt_at timestamptz NOT NULL,
  last_success_at timestamptz,
  etag varchar(512),
  last_modified varchar(512),
  consecutive_failures integer NOT NULL DEFAULT 0,
  circuit_open_until timestamptz,
  claim_owner varchar(128),
  claim_expires_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT external_source_poll_state_failures_nonnegative
    CHECK (consecutive_failures >= 0),
  CONSTRAINT external_source_poll_state_claim_pair
    CHECK ((claim_owner IS NULL) = (claim_expires_at IS NULL))
);
