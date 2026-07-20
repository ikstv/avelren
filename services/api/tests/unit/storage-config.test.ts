import { describe, expect, it } from "vitest";

import { parseStorageConfig } from "../../src/config.js";

describe("storage configuration", () => {
  it("uses in-memory storage only outside production by default", () => {
    expect(parseStorageConfig({})).toEqual({ mode: "memory" });
  });

  it("fails closed when production storage mode is missing", () => {
    expect(() => parseStorageConfig({ NODE_ENV: "production" })).toThrow(
      "AVELREN_STORAGE_MODE must be set to postgres in production",
    );
  });

  it("rejects in-memory storage in production", () => {
    expect(() =>
      parseStorageConfig({
        NODE_ENV: "production",
        AVELREN_STORAGE_MODE: "memory",
      }),
    ).toThrow("Production storage must use PostgreSQL");
  });

  it("requires a valid PostgreSQL URL", () => {
    expect(() =>
      parseStorageConfig({ AVELREN_STORAGE_MODE: "postgres" }),
    ).toThrow("DATABASE_URL must be a valid PostgreSQL connection URL");
  });

  it("accepts explicit PostgreSQL production storage", () => {
    const databaseUrl =
      "postgresql://avelren:change-me@postgres.invalid:5432/avelren";
    expect(
      parseStorageConfig({
        NODE_ENV: "production",
        AVELREN_STORAGE_MODE: "postgres",
        DATABASE_URL: databaseUrl,
      }),
    ).toEqual({ mode: "postgres", databaseUrl });
  });

  it("does not disclose an invalid connection value in errors", () => {
    const sensitiveValue = "postgresql://sensitive-user:sensitive-value@";
    let message = "";
    try {
      parseStorageConfig({
        AVELREN_STORAGE_MODE: "postgres",
        DATABASE_URL: sensitiveValue,
      });
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    }
    expect(message).not.toContain("sensitive-user");
    expect(message).not.toContain("sensitive-value");
  });
});
