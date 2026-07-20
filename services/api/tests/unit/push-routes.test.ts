import Fastify from "fastify";
import { describe, expect, it, vi } from "vitest";
import { buildApp } from "../../src/http/app.js";
import { AppAttestationError, type AppAttestationVerifier } from "../../src/security/app-attestation.js";
import { registerPushRoutes, RegistrationRateLimiter, type RegistrationService } from "../../src/push/routes.js";

class FakeRegistrationService implements RegistrationService {
  registrations = 0;
  rotations = 0;
  heartbeats = 0;
  disables = 0;
  async register(): Promise<{ status: "registered"; installationCredential?: string }> {
    this.registrations += 1;
    return { status: "registered", installationCredential: "c".repeat(43) };
  }
  async rotateToken(): Promise<void> { this.rotations += 1; }
  async heartbeat(): Promise<void> { this.heartbeats += 1; }
  async disable(): Promise<void> { this.disables += 1; }
}

class ConflictRegistrationService extends FakeRegistrationService {
  override async register(): Promise<{ status: "registered" }> {
    this.registrations += 1;
    return { status: "registered" };
  }
}

const validVerifier: AppAttestationVerifier = { verify: vi.fn().mockResolvedValue({ appId: "test-app" }) };
const headers = { "x-firebase-appcheck": "header.payload.signature" };
const input = {
  installationId: "installation_identifier_12345",
  token: "token-value-1234567890",
  platform: "android",
  locale: "uk-UA",
};

describe("push registration routes", () => {
  it("registers an exact attested request and returns the one-time credential", async () => {
    const service = new FakeRegistrationService();
    const app = buildApp({ pushRegistrationService: service, appAttestationVerifier: validVerifier });
    const response = await app.inject({ method: "POST", url: "/v1/push/installations", headers, payload: input });
    expect(response.statusCode).toBe(201);
    expect(response.json()).toEqual({ status: "registered", installationCredential: "c".repeat(43) });
    expect(service.registrations).toBe(1);
    await app.close();
  });

  it.each([["missing", undefined], ["oversized", "x".repeat(8_193)]])(
    "rejects %s App Check header before database mutation", async (_name, value) => {
      const service = new FakeRegistrationService();
      const app = buildApp({ pushRegistrationService: service, appAttestationVerifier: validVerifier });
      const response = await app.inject({ method: "POST", url: "/v1/push/installations",
        ...(value ? { headers: { "x-firebase-appcheck": value } } : {}), payload: input });
      expect(response.statusCode).toBe(401);
      expect(service.registrations).toBe(0);
      await app.close();
    },
  );

  it("normalizes invalid and unavailable verifier failures without token leakage", async () => {
    for (const kind of ["invalid", "unavailable"] as const) {
      const service = new FakeRegistrationService();
      const verifier = { verify: vi.fn().mockRejectedValue(new AppAttestationError(kind)) };
      const app = buildApp({ pushRegistrationService: service, appAttestationVerifier: verifier });
      const response = await app.inject({ method: "POST", url: "/v1/push/installations",
        headers, payload: input });
      expect(response.statusCode).toBe(kind === "invalid" ? 401 : 503);
      expect(response.body).not.toContain(headers["x-firebase-appcheck"]);
      expect(service.registrations).toBe(0);
      await app.close();
    }
  });

  it("rejects an unexpected field only after successful attestation", async () => {
    const service = new FakeRegistrationService();
    const app = buildApp({ pushRegistrationService: service, appAttestationVerifier: validVerifier });
    const response = await app.inject({ method: "POST", url: "/v1/push/installations",
      headers, payload: { ...input, unexpected: true } });
    expect(response.statusCode).toBe(400);
    expect(response.body).not.toContain("token-value");
    expect(service.registrations).toBe(0);
    await app.close();
  });

  it("returns the same neutral response for an attested existing installation", async () => {
    const app = buildApp({ pushRegistrationService: new ConflictRegistrationService(),
      appAttestationVerifier: validVerifier });
    const response = await app.inject({ method: "POST", url: "/v1/push/installations", headers, payload: input });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: "registered" });
    await app.close();
  });

  it("requires both attestation and installation credential for mutations", async () => {
    const service = new FakeRegistrationService();
    const app = buildApp({ pushRegistrationService: service, appAttestationVerifier: validVerifier });
    const noCredential = await app.inject({ method: "PUT",
      url: `/v1/push/installations/${input.installationId}/token`, headers,
      payload: { token: input.token } });
    expect(noCredential.statusCode).toBe(401);
    const noAttestation = await app.inject({ method: "PUT",
      url: `/v1/push/installations/${input.installationId}/token`,
      headers: { authorization: `Bearer ${"c".repeat(43)}` }, payload: { token: input.token } });
    expect(noAttestation.statusCode).toBe(401);
    const both = await app.inject({ method: "PUT",
      url: `/v1/push/installations/${input.installationId}/token`,
      headers: { ...headers, authorization: `Bearer ${"c".repeat(43)}` }, payload: { token: input.token } });
    expect(both.statusCode).toBe(204);
    expect(service.rotations).toBe(1);
    await app.close();
  });

  it("requires attestation for heartbeat and unregister", async () => {
    const service = new FakeRegistrationService();
    const app = buildApp({ pushRegistrationService: service, appAttestationVerifier: validVerifier });
    const authorization = `Bearer ${"c".repeat(43)}`;
    const heartbeat = await app.inject({ method: "PATCH",
      url: `/v1/push/installations/${input.installationId}`, headers: { ...headers, authorization },
      payload: { locale: "uk-UA" } });
    const disable = await app.inject({ method: "DELETE",
      url: `/v1/push/installations/${input.installationId}`, headers: { ...headers, authorization } });
    expect([heartbeat.statusCode, disable.statusCode]).toEqual([204, 204]);
    expect([service.heartbeats, service.disables]).toEqual([1, 1]);
    await app.close();
  });

  it("applies rate limiting before attestation", async () => {
    const app = Fastify();
    const verifier = { verify: vi.fn().mockResolvedValue({ appId: "test-app" }) };
    registerPushRoutes(app, new FakeRegistrationService(), verifier, new RegistrationRateLimiter(1));
    await app.inject({ method: "POST", url: "/v1/push/installations", headers, payload: input });
    const limited = await app.inject({ method: "POST", url: "/v1/push/installations", headers, payload: input });
    expect(limited.statusCode).toBe(429);
    expect(verifier.verify).toHaveBeenCalledTimes(1);
    await app.close();
  });

  it("enforces the global registration body limit", async () => {
    const app = buildApp({ pushRegistrationService: new FakeRegistrationService(),
      appAttestationVerifier: validVerifier });
    const response = await app.inject({ method: "POST", url: "/v1/push/installations", headers,
      payload: { ...input, token: "x".repeat(17_000) } });
    expect(response.statusCode).toBe(413);
    await app.close();
  });
});
