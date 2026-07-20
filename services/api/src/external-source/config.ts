import * as ipaddr from "ipaddr.js";

import { MINIMUM_POLL_INTERVAL_MS } from "../polling/polling-coordinator.js";

const HOUR_MS = 3_600_000;

export interface ExternalSourceConfig {
  enabled: boolean;
  url?: URL;
  allowedHost?: string;
  locationId?: string;
  parserMode?: "html-count";
  countSelector?: string;
  observedAtSelector?: string;
  timeoutMs: number;
  maxResponseBytes: number;
  maxHeaderBytes: number;
  pollIntervalMs: number;
  backoffBaseMs: number;
  backoffMaxMs: number;
  circuitFailures: number;
  circuitOpenMs: number;
  maxRetryAfterMs: number;
  claimTtlMs: number;
}

export function parseExternalSourceConfig(env: NodeJS.ProcessEnv): ExternalSourceConfig {
  const enabled = parseEnabled(env.EXTERNAL_SOURCE_ENABLED);
  const common = {
    enabled,
    timeoutMs: integer(env.EXTERNAL_SOURCE_TIMEOUT_MS, 15_000, 1_000, 30_000),
    maxResponseBytes: integer(env.EXTERNAL_SOURCE_MAX_RESPONSE_BYTES, 262_144, 1_024, 1_048_576),
    maxHeaderBytes: integer(env.EXTERNAL_SOURCE_MAX_HEADER_BYTES, 16_384, 1_024, 65_536),
    pollIntervalMs: integer(env.EXTERNAL_SOURCE_POLL_INTERVAL_MS, MINIMUM_POLL_INTERVAL_MS, MINIMUM_POLL_INTERVAL_MS, 86_400_000),
    backoffBaseMs: integer(env.EXTERNAL_SOURCE_BACKOFF_BASE_MS, MINIMUM_POLL_INTERVAL_MS, MINIMUM_POLL_INTERVAL_MS, 86_400_000),
    backoffMaxMs: integer(env.EXTERNAL_SOURCE_BACKOFF_MAX_MS, HOUR_MS, MINIMUM_POLL_INTERVAL_MS, 86_400_000),
    circuitFailures: integer(env.EXTERNAL_SOURCE_CIRCUIT_FAILURES, 5, 1, 100),
    circuitOpenMs: integer(env.EXTERNAL_SOURCE_CIRCUIT_OPEN_MS, 900_000, MINIMUM_POLL_INTERVAL_MS, 86_400_000),
    maxRetryAfterMs: integer(env.EXTERNAL_SOURCE_MAX_RETRY_AFTER_MS, HOUR_MS, MINIMUM_POLL_INTERVAL_MS, 86_400_000),
    claimTtlMs: integer(env.EXTERNAL_SOURCE_CLAIM_TTL_MS, MINIMUM_POLL_INTERVAL_MS, MINIMUM_POLL_INTERVAL_MS, 86_400_000),
  };
  if (!enabled) return common;

  const rawUrl = required(env.EXTERNAL_SOURCE_URL);
  const allowedHost = required(env.EXTERNAL_SOURCE_ALLOWED_HOST).toLowerCase();
  const locationId = required(env.EXTERNAL_SOURCE_LOCATION_ID);
  const parserMode = required(env.EXTERNAL_SOURCE_PARSER_MODE);
  const countSelector = selector(required(env.EXTERNAL_SOURCE_COUNT_SELECTOR));
  const observedAtSelector = env.EXTERNAL_SOURCE_OBSERVED_AT_SELECTOR === undefined
    ? undefined
    : selector(env.EXTERNAL_SOURCE_OBSERVED_AT_SELECTOR);
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    throw configError();
  }
  const hostname = url.hostname.toLowerCase();
  if (
    rawUrl.length > 2_048 || url.protocol !== "https:" || url.username !== "" || url.password !== "" ||
    url.hash !== "" || url.search !== "" || (url.port !== "" && url.port !== "443") ||
    hostname !== allowedHost || ipaddr.isValid(hostname.replace(/^\[|\]$/gu, "")) ||
    !/^[a-z0-9.-]+$/u.test(allowedHost) || allowedHost.startsWith(".") ||
    allowedHost.endsWith(".") || allowedHost.includes("..") || parserMode !== "html-count" ||
    !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/u.test(locationId) ||
    common.backoffMaxMs < common.backoffBaseMs || common.claimTtlMs < common.timeoutMs
  ) throw configError();

  return {
    ...common, url, allowedHost, locationId, parserMode, countSelector,
    ...(observedAtSelector === undefined ? {} : { observedAtSelector }),
  };
}

function parseEnabled(value: string | undefined): boolean {
  if (value === undefined || value === "false") return false;
  if (value === "true") return true;
  throw configError();
}

function required(value: string | undefined): string {
  if (value === undefined || value.length === 0 || value.trim() !== value) throw configError();
  return value;
}

function selector(value: string): string {
  if (value.length === 0 || value.length > 256 || /[\u0000-\u001f\u007f]/u.test(value)) throw configError();
  return value;
}

function integer(value: string | undefined, fallback: number, minimum: number, maximum: number): number {
  if (value === undefined) return fallback;
  if (!/^(0|[1-9][0-9]*)$/u.test(value)) throw configError();
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) throw configError();
  return parsed;
}

function configError(): Error {
  return new Error("External source configuration is invalid");
}
