import Fastify, { type FastifyInstance } from "fastify";

import { InMemoryWorkloadProvider } from "../workload/in-memory-workload-provider.js";
import { MissingWorkloadSnapshotError } from "../workload/in-memory-workload-provider.js";
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

const workloadUnavailableResponseSchema = {
  type: "object",
  additionalProperties: false,
  required: ["error", "message", "status", "timestamp"],
  properties: {
    error: { type: "string", enum: ["snapshot_unavailable"] },
    message: { type: "string" },
    status: { type: "integer", const: 503 },
    timestamp: { type: "string", format: "date-time" },
  },
} as const;

export function buildApp(options: BuildAppOptions = {}): FastifyInstance {
  const app = Fastify({ logger: options.logger ?? false });
  const workloadProvider =
    options.workloadProvider ?? new InMemoryWorkloadProvider();

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
        response: {
          200: workloadResponseSchema,
          503: workloadUnavailableResponseSchema,
        },
      },
    },
    async (_request, reply) => {
      try {
        return await workloadProvider.getCurrent();
      } catch (error) {
        if (error instanceof MissingWorkloadSnapshotError) {
          return reply.code(503).send({
            error: error.code,
            message: "Workload snapshot is not available yet",
            status: 503,
            timestamp: new Date().toISOString(),
          });
        }

        throw error;
      }
    },
  );

  return app;
}
