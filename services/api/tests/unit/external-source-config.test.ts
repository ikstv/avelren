import { describe, expect, it } from "vitest";
import { parseExternalSourceConfig } from "../../src/external-source/config.js";

const valid = {
  EXTERNAL_SOURCE_ENABLED: "true",
  EXTERNAL_SOURCE_URL: "https://source.example.invalid/data",
  EXTERNAL_SOURCE_ALLOWED_HOST: "source.example.invalid",
  EXTERNAL_SOURCE_LOCATION_ID: "location-placeholder",
  EXTERNAL_SOURCE_PARSER_MODE: "html-count",
  EXTERNAL_SOURCE_COUNT_SELECTOR: "[data-avelren-count]",
};

describe("external source configuration", () => {
  it("is disabled by default", () => {
    expect(parseExternalSourceConfig({})).toMatchObject({ enabled: false, pollIntervalMs: 60_000 });
  });
  it("accepts complete neutral HTTPS configuration", () => {
    expect(parseExternalSourceConfig(valid)).toMatchObject({ enabled: true, allowedHost: "source.example.invalid" });
  });
  it.each([
    { EXTERNAL_SOURCE_URL: undefined },
    { EXTERNAL_SOURCE_URL: "http://source.example.invalid/data" },
    { EXTERNAL_SOURCE_URL: "https://user@source.example.invalid/data" },
    { EXTERNAL_SOURCE_URL: "https://source.example.invalid/data#fragment" },
    { EXTERNAL_SOURCE_URL: "https://source.example.invalid/data?unsafe=1" },
    { EXTERNAL_SOURCE_URL: "https://other.example.invalid/data" },
    { EXTERNAL_SOURCE_URL: "https://127.0.0.1/data", EXTERNAL_SOURCE_ALLOWED_HOST: "127.0.0.1" },
    { EXTERNAL_SOURCE_POLL_INTERVAL_MS: "59999" },
    { EXTERNAL_SOURCE_CLAIM_TTL_MS: "1000" },
  ])("rejects incomplete or unsafe enabled configuration", (override) => {
    expect(() => parseExternalSourceConfig({ ...valid, ...override })).toThrow("External source configuration is invalid");
  });
  it("does not reveal a configured value", () => {
    const marker = "sensitive-placeholder-value";
    try { parseExternalSourceConfig({ ...valid, EXTERNAL_SOURCE_URL: marker }); }
    catch (error) { expect(String(error)).not.toContain(marker); }
  });
});
