import type { FastifyInstance, FastifyRequest } from "fastify";
import { DeviceAuthenticationError, parseHeartbeatInput, parseInstallationId,
  parseRegistrationInput, parseTokenInput, type PostgresDeviceRegistrationService } from "./device-registration.js";
import { PayloadValidationError } from "./exact-object.js";

export interface RegistrationService {
  register(input: ReturnType<typeof parseRegistrationInput>): Promise<Readonly<{
    status: "registered";
    installationCredential?: string;
  }>>;
  rotateToken(installationId: string, credential: string, token: string): Promise<void>;
  heartbeat(installationId: string, credential: string, locale: string): Promise<void>;
  disable(installationId: string, credential: string): Promise<void>;
}

interface Bucket { count: number; resetAt: number }
export class RegistrationRateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  public constructor(private readonly limit = 30, private readonly windowMs = 60_000,
    private readonly now: () => number = Date.now) {}
  public allow(key: string): boolean {
    const now = this.now();
    const bucket = this.buckets.get(key);
    if (!bucket || bucket.resetAt <= now) {
      this.buckets.set(key, { count: 1, resetAt: now + this.windowMs });
      return true;
    }
    if (bucket.count >= this.limit) return false;
    bucket.count += 1;
    return true;
  }
}

const credentialFrom = (request: FastifyRequest): string => {
  const authorization = request.headers.authorization;
  if (typeof authorization !== "string" || !/^Bearer [A-Za-z0-9_-]{43}$/.test(authorization)) {
    throw new DeviceAuthenticationError();
  }
  return authorization.slice(7);
};

export function registerPushRoutes(app: FastifyInstance, service: RegistrationService,
  limiter = new RegistrationRateLimiter()): void {
  const limited = (request: FastifyRequest): boolean => limiter.allow(request.ip);
  const handleError = (error: unknown, reply: { code(status: number): unknown }): never => {
    if (error instanceof PayloadValidationError) {
      throw Object.assign(new Error("Invalid request"), { statusCode: 400 });
    }
    if (error instanceof DeviceAuthenticationError) {
      throw Object.assign(new Error("Installation authentication failed"), { statusCode: 401 });
    }
    throw Object.assign(new Error("Push operation failed"), { statusCode: 503 });
  };

  app.post("/v1/push/installations", async (request, reply) => {
    if (!limited(request)) return reply.code(429).send({ error: { code: "rate_limited", message: "Try later" } });
    try {
      const result = await service.register(parseRegistrationInput(request.body));
      return reply.code(result.installationCredential ? 201 : 200).send(result);
    } catch (error) { return handleError(error, reply); }
  });
  app.put<{ Params: { installationId: string } }>("/v1/push/installations/:installationId/token",
    async (request, reply) => {
      if (!limited(request)) return reply.code(429).send({ error: { code: "rate_limited", message: "Try later" } });
      try {
        const id = parseInstallationId(request.params.installationId);
        const input = parseTokenInput(request.body);
        await service.rotateToken(id, credentialFrom(request), input.token);
        return reply.code(204).send();
      } catch (error) { return handleError(error, reply); }
    });
  app.patch<{ Params: { installationId: string } }>("/v1/push/installations/:installationId",
    async (request, reply) => {
      if (!limited(request)) return reply.code(429).send({ error: { code: "rate_limited", message: "Try later" } });
      try {
        const id = parseInstallationId(request.params.installationId);
        const input = parseHeartbeatInput(request.body);
        await service.heartbeat(id, credentialFrom(request), input.locale);
        return reply.code(204).send();
      } catch (error) { return handleError(error, reply); }
    });
  app.delete<{ Params: { installationId: string } }>("/v1/push/installations/:installationId",
    async (request, reply) => {
      if (!limited(request)) return reply.code(429).send({ error: { code: "rate_limited", message: "Try later" } });
      try {
        await service.disable(parseInstallationId(request.params.installationId), credentialFrom(request));
        return reply.code(204).send();
      } catch (error) { return handleError(error, reply); }
    });
}

export type ConcreteRegistrationService = PostgresDeviceRegistrationService;
