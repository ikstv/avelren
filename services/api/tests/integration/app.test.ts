import { describe, expect, it, vi } from "vitest";

import { buildApp } from "../../src/http/app.js";
import {
  InMemoryWorkloadProvider,
  DEFAULT_STALE_AFTER_MS,
} from "../../src/workload/in-memory-workload-provider.js";
import type { SourceClient } from "../../src/polling/source-client.js";

describe("Avelren API", () => {
  it("serves the health endpoint", async () => {
    const app = buildApp();

    try {
      const response = await app.inject({ method: "GET", url: "/v1/health" });

      expect(response.statusCode).toBe(200);
      expect(response.json()).toEqual({
        status: "ok",
        service: "avelren-api",
      });
    } finally {
      await app.close();
    }
  });

  it("returns cached workload when available", async () => {
    const snapshot = {
      locationId: "demo",
      vehicleCount: 125,
      observedAt: "2026-07-20T08:00:00.000Z",
      receivedAt: "2026-07-20T08:00:01.000Z",
      freshness: "fresh" as const,
      sequence: 3,
    };
    const provider = new InMemoryWorkloadProvider(snapshot, {
      clock: () => new Date("2026-07-20T08:00:30.000Z"),
    });
    const app = buildApp({ workloadProvider: provider });

    try {
      const response = await app.inject({ method: "GET", url: "/v1/workload" });

      expect(response.statusCode).toBe(200);
      expect(response.json()).toEqual(snapshot);
    } finally {
      await app.close();
    }
  });

  it("returns 503 when workload snapshot is missing", async () => {
    const app = buildApp();

    try {
      const response = await app.inject({ method: "GET", url: "/v1/workload" });

      expect(response.statusCode).toBe(503);
      expect(response.json()).toEqual({
        error: "snapshot_unavailable",
        message: "Workload snapshot is not available yet",
        status: 503,
        timestamp: expect.any(String),
      });
    } finally {
      await app.close();
    }
  });

  it("returns stale when snapshot age exceeds the configured window", async () => {
    const now = new Date("2026-07-20T08:02:00.000Z");
    let current = new Date("2026-07-20T08:00:00.000Z");
    const provider = new InMemoryWorkloadProvider(undefined, {
      clock: () => current,
      staleAfterMs: DEFAULT_STALE_AFTER_MS,
    });
    const snapshot = {
      locationId: "demo",
      vehicleCount: 125,
      observedAt: "2026-07-20T08:00:00.000Z",
      receivedAt: "2026-07-20T08:00:00.000Z",
      freshness: "fresh" as const,
      sequence: 3,
    };
    provider.setCurrent(snapshot);
    const app = buildApp({ workloadProvider: provider });

    try {
      let response = await app.inject({ method: "GET", url: "/v1/workload" });
      expect(response.statusCode).toBe(200);
      expect(response.json().freshness).toBe("fresh");

      current = now;
      response = await app.inject({ method: "GET", url: "/v1/workload" });
      expect(response.statusCode).toBe(200);
      expect(response.json().freshness).toBe("stale");
    } finally {
      await app.close();
    }
  });

  it("does not trigger SourceClient when serving API requests", async () => {
    const sourceClient: SourceClient<unknown> = {
      fetch: vi.fn(),
    };
    const provider = new InMemoryWorkloadProvider({
      locationId: "demo",
      vehicleCount: 125,
      observedAt: "2026-07-20T08:00:00.000Z",
      receivedAt: "2026-07-20T08:00:01.000Z",
      freshness: "fresh",
      sequence: 3,
    });
    const app = buildApp({ workloadProvider: provider });

    try {
      const response = await app.inject({ method: "GET", url: "/v1/workload" });

      expect(response.statusCode).toBe(200);
      expect(sourceClient.fetch).not.toHaveBeenCalled();
    } finally {
      await app.close();
    }
  });
});
