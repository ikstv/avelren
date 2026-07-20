import { describe, expect, it, vi } from "vitest";
import { CoordinatedExternalSourceClient } from "../../src/external-source/coordinated-source-client.js";
import { ExternalSourceAdapter } from "../../src/external-source/external-source-adapter.js";
import { ExternalSourceHttpError } from "../../src/external-source/secure-http-client.js";
import type { ExternalSourcePollStateStore, PollReservation } from "../../src/external-source/postgres-poll-state-store.js";

const reservation: PollReservation = { sourceKey: "primary", ownerId: "owner" };
const observation = { locationId: "location-placeholder", vehicleCount: 50, observedAt: "2026-07-20T08:00:00.000Z", observationId: "a".repeat(64) };

describe("CoordinatedExternalSourceClient", () => {
  it("does not request without a reservation", async () => {
    const source = { fetch: vi.fn() };
    await make(fakeState(null), source, { parse: vi.fn() }).fetch(new AbortController().signal);
    expect(source.fetch).not.toHaveBeenCalled();
  });
  it("does not ingest 304", async () => {
    const state = fakeState(reservation); const collector = { ingest: vi.fn() };
    const source = { fetch: vi.fn().mockResolvedValue({ status: "not-modified", receivedAt: new Date(), metadata: { etag: '"same"' } }) };
    await make(state, source, { parse: vi.fn() }, collector).fetch(new AbortController().signal);
    expect(collector.ingest).not.toHaveBeenCalled();
    expect(state.recordSuccess).toHaveBeenCalled();
  });
  it("ingests before completing reservation", async () => {
    const calls: string[] = []; const state = fakeState(reservation);
    vi.mocked(state.recordSuccess).mockImplementation(async () => { calls.push("success"); return true; });
    const collector = { ingest: vi.fn(async () => { calls.push("ingest"); }) };
    const source = { fetch: vi.fn().mockResolvedValue({ status: "ok", body: Buffer.from("safe"), receivedAt: new Date(), metadata: {} }) };
    await make(state, source, { parse: vi.fn().mockReturnValue(observation) }, collector).fetch(new AbortController().signal);
    expect(calls).toEqual(["ingest", "success"]);
  });
  it("records bounded Retry-After", async () => {
    const state = fakeState(reservation);
    const source = { fetch: vi.fn().mockRejectedValue(new ExternalSourceHttpError("rate-limited", 120_000)) };
    await expect(make(state, source, { parse: vi.fn() }).fetch(new AbortController().signal)).rejects.toThrow("External source collection cycle failed");
    expect(state.recordFailure).toHaveBeenCalledWith(reservation, expect.objectContaining({ minimumIntervalMs: 60_000, retryAfterMs: 120_000 }));
  });
  it("does not expose collector failure", async () => {
    const state = fakeState(reservation);
    const source = { fetch: vi.fn().mockResolvedValue({ status: "ok", body: Buffer.from("safe"), receivedAt: new Date(), metadata: {} }) };
    const collector = { ingest: vi.fn().mockRejectedValue(new Error("sensitive-marker")) };
    await expect(make(state, source, { parse: vi.fn().mockReturnValue(observation) }, collector).fetch(new AbortController().signal)).rejects.toThrow("External source collection cycle failed");
    expect(state.recordSuccess).not.toHaveBeenCalled();
    expect(state.recordFailure).toHaveBeenCalledOnce();
  });
});

function make(state: ExternalSourcePollStateStore, source: any, parser: any, collector: any = { ingest: vi.fn() }): CoordinatedExternalSourceClient {
  return new CoordinatedExternalSourceClient(new ExternalSourceAdapter(source, parser), collector, state, {
    reservation: { sourceKey: "primary", ownerId: "owner", minimumIntervalMs: 60_000, claimTtlMs: 60_000 },
    failurePolicy: { minimumIntervalMs: 60_000, backoffBaseMs: 60_000, backoffMaxMs: 600_000, circuitFailures: 3, circuitOpenMs: 300_000 },
  });
}
function fakeState(result: PollReservation | null): ExternalSourcePollStateStore {
  return { tryReserve: vi.fn().mockResolvedValue(result), recordSuccess: vi.fn().mockResolvedValue(true), recordFailure: vi.fn().mockResolvedValue(true) };
}
