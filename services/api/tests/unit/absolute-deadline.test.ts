import { EventEmitter } from "node:events";
import type { ClientRequest, IncomingMessage } from "node:http";
import { PassThrough } from "node:stream";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  NodeHttpsTransport,
  SecureExternalSourceClient,
  type AddressResolver,
} from "../../src/external-source/secure-http-client.js";

describe("absolute external HTTP deadline", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("terminates a connection that never returns headers", async () => {
    const harness = createHarness();
    const pending = client(harness.transport).fetch({}, new AbortController().signal);
    const rejection = expect(pending).rejects.toMatchObject({ code: "timeout" });
    await vi.advanceTimersByTimeAsync(1_000);
    await rejection;
    expect(harness.request.destroyed).toBe(true);
    expect(harness.request.socketClosed).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("destroys a response that returns headers but never completes its body", async () => {
    const harness = createHarness();
    const pending = client(harness.transport).fetch({}, new AbortController().signal);
    await vi.advanceTimersByTimeAsync(0);
    const response = harness.respond();
    const rejection = expect(pending).rejects.toMatchObject({ code: "timeout" });
    await vi.advanceTimersByTimeAsync(1_000);
    await rejection;
    expect(response.destroyed).toBe(true);
    expect(harness.request.destroyed).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("terminates an infinite slow stream despite regular chunks", async () => {
    const harness = createHarness();
    const pending = client(harness.transport).fetch({}, new AbortController().signal);
    await vi.advanceTimersByTimeAsync(0);
    const response = harness.respond();
    const rejection = expect(pending).rejects.toMatchObject({ code: "timeout" });
    for (let index = 0; index < 4; index += 1) {
      await vi.advanceTimersByTimeAsync(200);
      response.write(Buffer.from("x"));
    }
    await vi.advanceTimersByTimeAsync(200);
    await rejection;
    expect(harness.request.inactivityTimeoutValues).toEqual([1_000, 0]);
    expect(response.destroyed).toBe(true);
    expect(harness.request.destroyed).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("clears the absolute timer after a successful response", async () => {
    const harness = createHarness();
    const pending = client(harness.transport).fetch({}, new AbortController().signal);
    await vi.advanceTimersByTimeAsync(0);
    harness.respond().end(Buffer.from("<html></html>"));
    await expect(pending).resolves.toMatchObject({ status: "ok" });
    expect(vi.getTimerCount()).toBe(0);
  });

  it("clears the absolute timer after an ordinary network error", async () => {
    const harness = createHarness();
    const pending = client(harness.transport).fetch({}, new AbortController().signal);
    const rejection = expect(pending).rejects.toMatchObject({ code: "network" });
    await vi.advanceTimersByTimeAsync(0);
    harness.request.emit("error", new Error("internal-network-marker"));
    await rejection;
    expect(vi.getTimerCount()).toBe(0);
  });

  it("settles once when completion races the deadline", async () => {
    const harness = createHarness();
    const pending = client(harness.transport).fetch({}, new AbortController().signal);
    let settlements = 0;
    void pending.then(() => { settlements += 1; }, () => { settlements += 1; });
    await vi.advanceTimersByTimeAsync(0);
    const response = harness.respond();
    setTimeout(() => response.end(Buffer.from("<html></html>")), 1_000);
    await vi.advanceTimersByTimeAsync(1_000);
    await expect(pending).rejects.toMatchObject({ code: "timeout" });
    await vi.advanceTimersByTimeAsync(0);
    expect(settlements).toBe(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("settles once when the body limit races the deadline", async () => {
    const harness = createHarness();
    const pending = client(harness.transport, 1).fetch({}, new AbortController().signal);
    let settlements = 0;
    void pending.then(() => { settlements += 1; }, () => { settlements += 1; });
    await vi.advanceTimersByTimeAsync(0);
    const response = harness.respond();
    setTimeout(() => response.write(Buffer.from("xx")), 999);
    await vi.advanceTimersByTimeAsync(1_000);
    await expect(pending).rejects.toMatchObject({ code: "response-too-large" });
    expect(settlements).toBe(1);
    expect(response.destroyed).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("returns a normalized timeout without connection metadata", async () => {
    const harness = createHarness();
    const pending = client(harness.transport).fetch({}, new AbortController().signal);
    const rejection = pending.catch((error: unknown) => error);
    await vi.advanceTimersByTimeAsync(1_000);
    const error = await rejection;
    expect(error).toMatchObject({ message: "External source request failed", code: "timeout" });
    expect(String(error)).not.toMatch(/example\.invalid|8\.8\.8\.8|header-marker|body-marker/u);
  });
});

class ControlledRequest extends EventEmitter {
  public destroyed = false;
  public socketClosed = false;
  public readonly inactivityTimeoutValues: number[] = [];

  public setTimeout(milliseconds: number, _callback?: () => void): this {
    this.inactivityTimeoutValues.push(milliseconds);
    return this;
  }

  public end(): this { return this; }

  public destroy(error?: Error): this {
    if (this.destroyed) return this;
    this.destroyed = true;
    this.socketClosed = true;
    if (error !== undefined) queueMicrotask(() => this.emit("error", error));
    return this;
  }
}

class ControlledResponse extends PassThrough {
  public readonly statusCode = 200;
  public readonly headers = { "content-type": "text/html; charset=utf-8" };
}

function createHarness(): Readonly<{
  request: ControlledRequest;
  transport: NodeHttpsTransport;
  respond: () => ControlledResponse;
}> {
  const request = new ControlledRequest();
  let callback: ((response: IncomingMessage) => void) | undefined;
  const factory = ((_url: URL, _options: unknown, onResponse: (response: IncomingMessage) => void) => {
    callback = onResponse;
    return request as unknown as ClientRequest;
  }) as unknown as typeof import("node:https").request;
  return {
    request,
    transport: new NodeHttpsTransport(factory),
    respond: () => {
      if (callback === undefined) throw new Error("Controlled request has not started");
      const response = new ControlledResponse();
      callback(response as unknown as IncomingMessage);
      return response;
    },
  };
}

function client(transport: NodeHttpsTransport, maxResponseBytes = 1_024): SecureExternalSourceClient {
  const resolver: AddressResolver = {
    resolve: vi.fn().mockResolvedValue([{ address: "8.8.8.8", family: 4 }]),
  };
  return new SecureExternalSourceClient({
    url: new URL("https://source.example.invalid/data"),
    allowedHost: "source.example.invalid",
    timeoutMs: 1_000,
    maxResponseBytes,
    maxHeaderBytes: 1_024,
    maxRetryAfterMs: 120_000,
    resolver,
    transport,
  });
}
