CREATE TABLE push_devices (
  id BIGSERIAL PRIMARY KEY,
  installation_id VARCHAR(128) NOT NULL UNIQUE,
  token_ciphertext BYTEA NOT NULL,
  token_iv BYTEA NOT NULL,
  token_auth_tag BYTEA NOT NULL,
  token_fingerprint CHAR(64) NOT NULL UNIQUE,
  encryption_key_id VARCHAR(64) NOT NULL,
  credential_salt BYTEA NOT NULL,
  credential_hash BYTEA NOT NULL,
  platform VARCHAR(16) NOT NULL CHECK (platform = 'android'),
  locale VARCHAR(35) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  disabled_at TIMESTAMPTZ,
  disabled_reason VARCHAR(64),
  CHECK ((enabled AND disabled_at IS NULL AND disabled_reason IS NULL) OR NOT enabled)
);

CREATE TABLE notification_outbox (
  id BIGSERIAL PRIMARY KEY,
  threshold_event_id VARCHAR(64) NOT NULL REFERENCES threshold_events(event_id) ON DELETE CASCADE,
  device_id BIGINT NOT NULL REFERENCES push_devices(id) ON DELETE CASCADE,
  notification_type VARCHAR(64) NOT NULL CHECK (notification_type = 'threshold_crossed'),
  payload JSONB NOT NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'claimed', 'sent', 'failed')),
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  available_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  claim_owner VARCHAR(128),
  claim_expires_at TIMESTAMPTZ,
  provider_message_id VARCHAR(512),
  last_error_code VARCHAR(64),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  sent_at TIMESTAMPTZ,
  UNIQUE (threshold_event_id, device_id),
  CHECK (
    (status = 'claimed' AND claim_owner IS NOT NULL AND claim_expires_at IS NOT NULL)
    OR (status <> 'claimed' AND claim_owner IS NULL AND claim_expires_at IS NULL)
  )
);

CREATE INDEX notification_outbox_claim_idx
  ON notification_outbox (available_at, id)
  WHERE status IN ('pending', 'claimed');

CREATE OR REPLACE FUNCTION enqueue_threshold_notifications()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO notification_outbox (
    threshold_event_id, device_id, notification_type, payload
  )
  SELECT
    NEW.event_id,
    device.id,
    'threshold_crossed',
    jsonb_build_object(
      'schemaVersion', '1',
      'eventId', NEW.event_id,
      'locationId', NEW.location_id,
      'threshold', NEW.threshold_value,
      'observedCount', NEW.current_vehicle_count,
      'observedAt', to_char(NEW.observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    )
  FROM push_devices AS device
  WHERE device.enabled = TRUE
  ON CONFLICT (threshold_event_id, device_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER threshold_event_notification_outbox
AFTER INSERT ON threshold_events
FOR EACH ROW
EXECUTE FUNCTION enqueue_threshold_notifications();
