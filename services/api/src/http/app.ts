import Fastify, { type FastifyInstance } from "fastify";

import { InMemoryWorkloadProvider } from "../workload/in-memory-workload-provider.js";
import {
  MAX_VEHICLE_COUNT,
  WORKLOAD_FRESHNESS_VALUES,
  type WorkloadProvider,
} from "../workload/workload.js";

export interface BuildAppOptions {
  workloadProvider?: WorkloadProvider;
  logger?: boolean;
}

const healthResponseSchema = {
  type: "object",
  additionalProperties: false,
  required: ["status", "service"],
  properties: {
    status: { type: "string", enum: ["ok"] },
    service: { type: "string", enum: ["avelren-api"] },
  },
} as const;

const workloadResponseSchema = {
  type: "object",
  additionalProperties: false,
  required: [
    "locationId",
    "vehicleCount",
    "observedAt",
    "receivedAt",
    "freshness",
    "sequence",
  ],
  properties: {
    locationId: { type: "string", minLength: 1, maxLength: 128 },
    vehicleCount: { type: "integer", minimum: 0, maximum: MAX_VEHICLE_COUNT },
    observedAt: { type: "string", format: "date-time" },
    receivedAt: { type: "string", format: "date-time" },
    freshness: { type: "string", enum: [...WORKLOAD_FRESHNESS_VALUES] },
    sequence: { type: "integer", minimum: 0, maximum: Number.MAX_SAFE_INTEGER },
  },
} as const;

export function buildApp(options: BuildAppOptions = {}): FastifyInstance {
  const app = Fastify({ logger: options.logger ?? false });
  const workloadProvider = options.workloadProvider ?? InMemoryWorkloadProvider.demo();

  app.get(
    "/v1/health",
    {
      schema: {
        response: { 200: healthResponseSchema },
      },
    },
    async () => ({
      status: "ok" as const,
      service: "avelren-api" as const,
    }),
  );

  app.get(
    "/v1/workload",
    {
      schema: {
        response: { 200: workloadResponseSchema },
      },
    },
    async () => workloadProvider.getCurrent(),
  );

  return app;
}
