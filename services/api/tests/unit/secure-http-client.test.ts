import { describe, expect, it, vi } from "vitest";
import { ExternalSourceHttpError, SecureExternalSourceClient, isPublicAddress, type AddressResolver, type ExternalHttpTransport, type RawHttpsResponse } from "../../src/external-source/secure-http-client.js";

describe("secure external HTTPS client", () => {
  it.each(["0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1", "192.0.2.1", "192.168.1.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "::", "::1", "fc00::1", "fe80::1", "ff02::1", "2001:db8::1", "2002:0808:0808::1", "::ffff:127.0.0.1"])(
    "rejects special address %s", (address) => expect(isPublicAddress(address)).toBe(false),
  );
  it.each(["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"])(
    "accepts global address %s", (address) => expect(isPublicAddress(address)).toBe(true),
  );
  it("rejects a mixed safe and unsafe DNS answer", async () => {
    const transport = fakeTransport(ok());
    const resolver = { resolve: vi.fn().mockResolvedValue([{ address: "8.8.8.8", family: 4 }, { address: "127.0.0.1", family: 4 }]) } as AddressResolver;
    await expect(client(transport, resolver).fetch({}, new AbortController().signal)).rejects.toMatchObject({ code: "network" });
    expect(transport.request).not.toHaveBeenCalled();
  });
  it("bounds DNS resolution time without starting HTTP", async () => {
    const transport = fakeTransport(ok());
    const resolver = { resolve: vi.fn(() => new Promise<never>(() => undefined)) } as AddressResolver;
    await expect(client(transport, resolver, 1).fetch({}, new AbortController().signal)).rejects.toMatchObject({ code: "network" });
    expect(transport.request).not.toHaveBeenCalled();
  });
  it("pins a validated address and uses minimal headers", async () => {
    const transport = fakeTransport(ok());
    await client(transport).fetch({ etag: '"safe"' }, new AbortController().signal);
    const request = vi.mocked(transport.request).mock.calls[0]?.[0];
    expect(request).toMatchObject({ pinnedAddress: "8.8.8.8", pinnedFamily: 4, headers: {
      accept: "text/html", "accept-encoding": "identity", "user-agent": "Avelren-collector/1", "if-none-match": '"safe"',
    } });
    expect(request?.headers).not.toHaveProperty("authorization");
    expect(request?.headers).not.toHaveProperty("cookie");
  });
  it.each([
    [302, {}, "redirect"], [403, {}, "forbidden"], [500, {}, "server"], [404, {}, "status"],
    [200, { "content-type": "application/json" }, "content-type"],
    [200, { "content-type": "text/html", "content-encoding": "gzip" }, "content-encoding"],
  ] as const)("rejects unsafe status or response metadata", async (statusCode, headers, code) => {
    await expect(client(fakeTransport({ statusCode, headers, body: Buffer.alloc(0) })).fetch({}, new AbortController().signal)).rejects.toMatchObject({ code });
  });
  it("enforces decoded response size", async () => {
    await expect(client(fakeTransport({ ...ok(), body: Buffer.alloc(1025) })).fetch({}, new AbortController().signal)).rejects.toMatchObject({ code: "response-too-large" });
  });
  it("handles 304 without bytes", async () => {
    await expect(client(fakeTransport({ statusCode: 304, headers: { etag: '"next"' }, body: Buffer.alloc(0) })).fetch({}, new AbortController().signal)).resolves.toMatchObject({ status: "not-modified", metadata: { etag: '"next"' } });
  });
  it("preserves validators when 304 omits cache headers", async () => {
    await expect(client(fakeTransport({ statusCode: 304, headers: {}, body: Buffer.alloc(0) })).fetch(
      { etag: '"existing"', lastModified: "Mon, 20 Jul 2026 08:00:00 GMT" },
      new AbortController().signal,
    )).resolves.toMatchObject({ metadata: {
      etag: '"existing"', lastModified: "Mon, 20 Jul 2026 08:00:00 GMT",
    } });
  });
  it("bounds Retry-After and rejects header injection", async () => {
    await expect(client(fakeTransport({ statusCode: 429, headers: { "retry-after": "999999" }, body: Buffer.alloc(0) })).fetch({}, new AbortController().signal)).rejects.toMatchObject({ code: "rate-limited", retryAfterMs: 120_000 });
    await expect(client(fakeTransport(ok())).fetch({ etag: '"safe"\r\nCookie: unsafe' }, new AbortController().signal)).rejects.toBeInstanceOf(ExternalSourceHttpError);
  });
  it.each([
    { etag: "not-quoted" },
    { lastModified: "not-an-http-date" },
  ])("rejects malformed cache validators", async (cache) => {
    await expect(client(fakeTransport(ok())).fetch(cache, new AbortController().signal)).rejects.toMatchObject({ code: "metadata" });
  });
});

function client(transport: ExternalHttpTransport, resolver: AddressResolver = { resolve: vi.fn().mockResolvedValue([{ address: "8.8.8.8", family: 4 }]) }, timeoutMs = 1000): SecureExternalSourceClient {
  return new SecureExternalSourceClient({ url: new URL("https://source.example.invalid/data"), allowedHost: "source.example.invalid", timeoutMs, maxResponseBytes: 1024, maxHeaderBytes: 1024, maxRetryAfterMs: 120_000, resolver, transport, clock: () => new Date("2026-07-20T08:00:00.000Z") });
}
function fakeTransport(response: RawHttpsResponse): ExternalHttpTransport { return { request: vi.fn().mockResolvedValue(response) }; }
function ok(): RawHttpsResponse { return { statusCode: 200, headers: { "content-type": "text/html; charset=utf-8" }, body: Buffer.from("<html></html>") }; }
