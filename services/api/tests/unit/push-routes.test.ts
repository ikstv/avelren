import { describe, expect, it } from "vitest";
import { buildApp } from "../../src/http/app.js";
import type { RegistrationService } from "../../src/push/routes.js";

class FakeRegistrationService implements RegistrationService {
  registrations = 0;
  rotations = 0;
  async register(): Promise<{ status: "registered"; installationCredential?: string }> {
    this.registrations += 1;
    return { status: "registered", installationCredential: "c".repeat(43) };
  }
  async rotateToken(): Promise<void> { this.rotations += 1; }
  async heartbeat(): Promise<void> {}
  async disable(): Promise<void> {}
}

class ConflictRegistrationService extends FakeRegistrationService {
  override async register(): Promise<{ status: "registered" }> {
    this.registrations += 1;
    return { status: "registered" };
  }
}

const input = {
  installationId: "installation_identifier_12345",
  token: "token-value-1234567890",
  platform: "android",
  locale: "uk-UA",
};

describe("push registration routes", () => {
  it("registers an exact valid request and returns the one-time credential", async () => {
    const service = new FakeRegistrationService();
    const app = buildApp({ pushRegistrationService: service });
    const response = await app.inject({ method: "POST", url: "/v1/push/installations", payload: input });
    expect(response.statusCode).toBe(201);
    expect(response.json()).toEqual({ status: "registered", installationCredential: "c".repeat(43) });
    expect(service.registrations).toBe(1);
    await app.close();
  });

  it("rejects an unexpected field before service execution", async () => {
    const service = new FakeRegistrationService();
    const app = buildApp({ pushRegistrationService: service });
    const response = await app.inject({ method: "POST", url: "/v1/push/installations",
      payload: { ...input, unexpected: true } });
    expect(response.statusCode).toBe(400);
    expect(response.body).not.toContain("token-value");
    expect(service.registrations).toBe(0);
    await app.close();
  });

  it("returns the same neutral response for an existing installation conflict", async () => {
    const app = buildApp({ pushRegistrationService: new ConflictRegistrationService() });
    const response = await app.inject({ method: "POST", url: "/v1/push/installations", payload: input });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: "registered" });
    expect(response.body).not.toContain("token-value");
    await app.close();
  });

  it("requires an installation credential for token rotation", async () => {
    const service = new FakeRegistrationService();
    const app = buildApp({ pushRegistrationService: service });
    const response = await app.inject({ method: "PUT",
      url: `/v1/push/installations/${input.installationId}/token`,
      payload: { token: input.token } });
    expect(response.statusCode).toBe(401);
    expect(service.rotations).toBe(0);
    await app.close();
  });

  it("enforces the global registration body limit", async () => {
    const app = buildApp({ pushRegistrationService: new FakeRegistrationService() });
    const response = await app.inject({ method: "POST", url: "/v1/push/installations",
      payload: { ...input, token: "x".repeat(17_000) } });
    expect(response.statusCode).toBe(413);
    await app.close();
  });
});
