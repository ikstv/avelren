import { describe, expect, it } from "vitest";

import { buildApp } from "../../src/http/app.js";
import { InMemoryWorkloadProvider } from "../../src/workload/in-memory-workload-provider.js";

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

  it("serves the current in-memory workload snapshot", async () => {
    const snapshot = {
      locationId: "demo",
      vehicleCount: 125,
      observedAt: "2026-07-20T08:00:00.000Z",
      receivedAt: "2026-07-20T08:00:01.000Z",
      freshness: "fresh" as const,
      sequence: 3,
    };
    const provider = new InMemoryWorkloadProvider(snapshot);
    const app = buildApp({ workloadProvider: provider });

    try {
      const response = await app.inject({ method: "GET", url: "/v1/workload" });

      expect(response.statusCode).toBe(200);
      expect(response.json()).toEqual(snapshot);
    } finally {
      await app.close();
    }
  });
});
