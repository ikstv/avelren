import { describe, expect, it, vi } from "vitest";
import { FcmHttpV1Provider } from "../../src/push/provider.js";

const accessTokens = { getAccessToken: async () => "test-access-token" };
const message = { token: "device-token-value-123", data: { schemaVersion: "1" } };

describe("FcmHttpV1Provider", () => {
  it("constructs the fixed HTTPS endpoint and returns a normalized message id", async () => {
    const request = vi.fn(async (_input: string | URL | Request, _init?: RequestInit) =>
      new Response(JSON.stringify({ name: "messages/1" }), {
      status: 200, headers: { "content-type": "application/json" },
      }));
    const provider = new FcmHttpV1Provider("avelren-test-project", accessTokens, 1_000, request);
    await expect(provider.send(message)).resolves.toEqual({ messageId: "messages/1" });
    expect(request.mock.calls[0]?.[0]).toBe(
      "https://fcm.googleapis.com/v1/projects/avelren-test-project/messages:send",
    );
    expect(request.mock.calls[0]?.[1]?.redirect).toBe("error");
  });

  it.each([
    [429, "rate_limited"], [503, "transient"], [400, "permanent"], [404, "permanent"],
  ] as const)("normalizes status %s as %s", async (status, kind) => {
    const provider = new FcmHttpV1Provider("avelren-test-project", accessTokens, 1_000,
      async () => new Response("{}", { status, headers: { "content-type": "application/json" } }));
    await expect(provider.send(message)).rejects.toMatchObject({ kind });
  });

  it("disables only a provider-confirmed unregistered token", async () => {
    const body = JSON.stringify({ error: { details: [{ errorCode: "UNREGISTERED" }] } });
    const provider = new FcmHttpV1Provider("avelren-test-project", accessTokens, 1_000,
      async () => new Response(body, { status: 404, headers: { "content-type": "application/json" } }));
    await expect(provider.send(message)).rejects.toMatchObject({ kind: "invalid_token" });
  });

  it("rejects oversized responses", async () => {
    const provider = new FcmHttpV1Provider("avelren-test-project", accessTokens, 1_000,
      async () => new Response("x".repeat(70_000), { status: 200,
        headers: { "content-type": "application/json" } }));
    await expect(provider.send(message)).rejects.toMatchObject({ kind: "permanent" });
  });
});
