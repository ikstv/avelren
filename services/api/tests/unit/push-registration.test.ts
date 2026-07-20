import type { Pool } from "pg";
import { describe, expect, it } from "vitest";
import { PostgresDeviceRegistrationService } from "../../src/push/device-registration.js";
import { TokenCrypto } from "../../src/push/token-crypto.js";

const crypto = new TokenCrypto({
  activeKeyId: "v1",
  encryptionKeys: new Map([["v1", Buffer.alloc(32, 31)]]),
  fingerprintKey: Buffer.alloc(32, 32),
});
const input = {
  installationId: "installation_identifier_12345",
  token: "token-value-1234567890",
  platform: "android" as const,
  locale: "uk-UA",
};

class RegistrationClient {
  readonly statements: string[] = [];
  released = false;
  constructor(private readonly insertWins: boolean, private readonly commitFails = false) {}

  async query(sql: string): Promise<{ rowCount: number; rows: Array<{ id: string }> }> {
    this.statements.push(sql);
    if (sql.includes("INSERT INTO push_devices")) {
      return { rowCount: this.insertWins ? 1 : 0, rows: this.insertWins ? [{ id: "7" }] : [] };
    }
    if (sql.startsWith("UPDATE push_devices")) return { rowCount: 1, rows: [] };
    if (sql === "COMMIT" && this.commitFails) throw new Error("commit failed");
    return { rowCount: 0, rows: [] };
  }

  release(): void { this.released = true; }
}

const serviceWith = (client: RegistrationClient): PostgresDeviceRegistrationService =>
  new PostgresDeviceRegistrationService({
    connect: async () => client,
  } as unknown as Pool, crypto);

describe("one-time device registration", () => {
  it("returns a credential only after creating and committing a row", async () => {
    const client = new RegistrationClient(true);
    const result = await serviceWith(client).register(input);
    expect(result.installationCredential).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(client.statements).toContain("COMMIT");
    expect(client.released).toBe(true);
  });

  it("returns a neutral response without credential or mutation on conflict", async () => {
    const client = new RegistrationClient(false);
    await expect(serviceWith(client).register(input)).resolves.toEqual({ status: "registered" });
    expect(client.statements.some((sql) => sql.startsWith("UPDATE push_devices"))).toBe(false);
    expect(client.statements).toContain("COMMIT");
  });

  it("does not return a credential when commit fails", async () => {
    const client = new RegistrationClient(true, true);
    await expect(serviceWith(client).register(input)).rejects.toThrow("commit failed");
    expect(client.statements).toContain("ROLLBACK");
    expect(client.released).toBe(true);
  });
});
