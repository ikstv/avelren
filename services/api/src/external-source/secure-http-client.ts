import { lookup as dnsLookup } from "node:dns/promises";
import { request as httpsRequest } from "node:https";
import type { IncomingHttpHeaders } from "node:http";
import * as ipaddr from "ipaddr.js";
import type { ExternalSourceCacheMetadata, ExternalSourceClient, ExternalSourceResponse } from "./external-source-adapter.js";

const V4_BLOCKED = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4"] as const;
const V6_BLOCKED = ["::/128", "::1/128", "64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "2001::/23", "2002::/16", "fc00::/7", "fe80::/10", "ff00::/8"] as const;

export interface ResolvedAddress { address: string; family: 4 | 6 }
export interface AddressResolver { resolve(hostname: string): Promise<readonly ResolvedAddress[]> }
export interface PinnedHttpsRequest {
  url: URL; pinnedAddress: string; pinnedFamily: 4 | 6; headers: Readonly<Record<string, string>>;
  timeoutMs: number; maxResponseBytes: number; maxHeaderBytes: number; signal: AbortSignal;
}
export interface RawHttpsResponse { statusCode: number; headers: IncomingHttpHeaders; body: Uint8Array }
export interface ExternalHttpTransport { request(options: PinnedHttpsRequest): Promise<RawHttpsResponse> }
export interface SecureExternalSourceClientOptions {
  url: URL; allowedHost: string; timeoutMs: number; maxResponseBytes: number; maxHeaderBytes: number;
  maxRetryAfterMs: number; resolver?: AddressResolver; transport?: ExternalHttpTransport; clock?: () => Date;
}
export type ExternalHttpErrorCode = "network" | "redirect" | "rate-limited" | "forbidden" | "server" | "status" | "content-type" | "content-encoding" | "response-too-large" | "metadata";

export class ExternalSourceHttpError extends Error {
  public constructor(public readonly code: ExternalHttpErrorCode, public readonly retryAfterMs?: number) {
    super("External source request failed");
    this.name = "ExternalSourceHttpError";
  }
}

export class SecureExternalSourceClient implements ExternalSourceClient {
  private readonly resolver: AddressResolver;
  private readonly transport: ExternalHttpTransport;
  private readonly clock: () => Date;
  public constructor(private readonly options: SecureExternalSourceClientOptions) {
    this.resolver = options.resolver ?? new NodeAddressResolver();
    this.transport = options.transport ?? new NodeHttpsTransport();
    this.clock = options.clock ?? (() => new Date());
  }

  public async fetch(cache: ExternalSourceCacheMetadata, signal: AbortSignal): Promise<ExternalSourceResponse> {
    if (this.options.url.hostname.toLowerCase() !== this.options.allowedHost.toLowerCase()) throw httpError("network");
    let addresses: readonly ResolvedAddress[];
    try {
      addresses = await resolveWithDeadline(
        this.resolver,
        this.options.allowedHost,
        signal,
        this.options.timeoutMs,
      );
    }
    catch { throw httpError("network"); }
    if (addresses.length === 0 || addresses.some((entry) => !isPublicAddress(entry.address))) throw httpError("network");
    const selected = [...addresses].sort((a, b) => a.family - b.family || a.address.localeCompare(b.address))[0];
    if (selected === undefined) throw httpError("network");
    const headers: Record<string, string> = { accept: "text/html", "accept-encoding": "identity", "user-agent": "Avelren-collector/1" };
    if (cache.etag !== undefined) headers["if-none-match"] = etagHeader(cache.etag);
    if (cache.lastModified !== undefined) headers["if-modified-since"] = lastModifiedHeader(cache.lastModified);
    let response: RawHttpsResponse;
    try {
      response = await this.transport.request({
        url: this.options.url, pinnedAddress: selected.address, pinnedFamily: selected.family, headers,
        timeoutMs: this.options.timeoutMs, maxResponseBytes: this.options.maxResponseBytes,
        maxHeaderBytes: this.options.maxHeaderBytes, signal,
      });
    } catch (error) {
      if (error instanceof ExternalSourceHttpError) throw error;
      throw httpError("network");
    }
    if (response.body.byteLength > this.options.maxResponseBytes) throw httpError("response-too-large");
    const metadata = readMetadata(response.headers);
    if (response.statusCode === 304) return {
      status: "not-modified",
      receivedAt: this.clock(),
      metadata: {
        ...(metadata.etag ?? cache.etag) === undefined ? {} : { etag: metadata.etag ?? cache.etag },
        ...(metadata.lastModified ?? cache.lastModified) === undefined
          ? {}
          : { lastModified: metadata.lastModified ?? cache.lastModified },
      },
    };
    if (response.statusCode >= 300 && response.statusCode < 400) throw httpError("redirect");
    if (response.statusCode === 403) throw httpError("forbidden");
    if (response.statusCode === 429) throw new ExternalSourceHttpError("rate-limited", retryAfter(response.headers["retry-after"], this.options.maxRetryAfterMs));
    if (response.statusCode >= 500) throw httpError("server");
    if (response.statusCode !== 200) throw httpError("status");
    contentType(response.headers["content-type"]);
    contentEncoding(response.headers["content-encoding"]);
    return { status: "ok", body: response.body, receivedAt: this.clock(), metadata };
  }
}

export class NodeAddressResolver implements AddressResolver {
  public async resolve(hostname: string): Promise<readonly ResolvedAddress[]> {
    const rows = await dnsLookup(hostname, { all: true, verbatim: true });
    return rows.map((row) => ({ address: row.address, family: row.family === 6 ? 6 : 4 }));
  }
}

export class NodeHttpsTransport implements ExternalHttpTransport {
  public request(options: PinnedHttpsRequest): Promise<RawHttpsResponse> {
    return new Promise((resolve, reject) => {
      const request = httpsRequest(options.url, {
        method: "GET", agent: false, headers: options.headers, maxHeaderSize: options.maxHeaderBytes,
        servername: options.url.hostname, minVersion: "TLSv1.2", signal: options.signal,
        lookup: (_hostname, lookupOptions, callback) => {
          if (lookupOptions.all) callback(null, [{ address: options.pinnedAddress, family: options.pinnedFamily }]);
          else callback(null, options.pinnedAddress, options.pinnedFamily);
        },
      }, (response) => {
        const chunks: Buffer[] = [];
        let size = 0;
        const contentLength = response.headers["content-length"];
        if (typeof contentLength === "string" && /^\d+$/u.test(contentLength) && Number(contentLength) > options.maxResponseBytes) {
          response.destroy(httpError("response-too-large")); return;
        }
        response.on("data", (chunk: Buffer) => {
          size += chunk.byteLength;
          if (size > options.maxResponseBytes) response.destroy(httpError("response-too-large"));
          else chunks.push(chunk);
        });
        response.once("end", () => resolve({ statusCode: response.statusCode ?? 0, headers: response.headers, body: Buffer.concat(chunks, size) }));
        response.once("error", reject);
      });
      request.setTimeout(options.timeoutMs, () => request.destroy(httpError("network")));
      request.once("error", reject);
      request.end();
    });
  }
}

export function isPublicAddress(address: string): boolean {
  let parsed: ipaddr.IPv4 | ipaddr.IPv6;
  try { parsed = ipaddr.parse(address); } catch { return false; }
  if (parsed.kind() === "ipv6") {
    const ipv6 = parsed as ipaddr.IPv6;
    if (ipv6.isIPv4MappedAddress()) return isPublicAddress(ipv6.toIPv4Address().toString());
  }
  if (parsed.range() !== "unicast") return false;
  const ranges = parsed.kind() === "ipv4" ? V4_BLOCKED : V6_BLOCKED;
  return !ranges.some((range) => {
    const [network, prefix] = ipaddr.parseCIDR(range);
    return parsed.kind() === network.kind() && parsed.match(network, prefix);
  });
}

function httpError(code: ExternalHttpErrorCode): ExternalSourceHttpError { return new ExternalSourceHttpError(code); }
function boundedHeader(value: string): string {
  if (Buffer.byteLength(value) > 512 || !/^[\x20-\x7e]+$/u.test(value)) throw httpError("metadata");
  return value;
}
function etagHeader(value: string): string {
  const bounded = boundedHeader(value);
  if (!/^(?:W\/)?"[\x21\x23-\x7e]*"$/u.test(bounded)) throw httpError("metadata");
  return bounded;
}
function lastModifiedHeader(value: string): string {
  const bounded = boundedHeader(value);
  const milliseconds = Date.parse(bounded);
  if (!Number.isFinite(milliseconds) || new Date(milliseconds).toUTCString() !== bounded) throw httpError("metadata");
  return bounded;
}
function single(value: string | string[] | undefined): string | undefined {
  if (value === undefined) return undefined;
  if (Array.isArray(value) || value.length === 0) throw httpError("metadata");
  return value;
}
function readMetadata(headers: IncomingHttpHeaders): ExternalSourceCacheMetadata {
  const etag = single(headers.etag); const lastModified = single(headers["last-modified"]);
  return { ...(etag === undefined ? {} : { etag: etagHeader(etag) }), ...(lastModified === undefined ? {} : { lastModified: lastModifiedHeader(lastModified) }) };
}
function contentType(value: string | string[] | undefined): void {
  const header = single(value);
  if (header === undefined || !/^text\/html(?:\s*;\s*charset=(?:utf-8|us-ascii))?\s*$/iu.test(header)) throw httpError("content-type");
}
function contentEncoding(value: string | string[] | undefined): void {
  const header = single(value);
  if (header !== undefined && header.toLowerCase() !== "identity") throw httpError("content-encoding");
}
function retryAfter(value: string | string[] | undefined, maximumMs: number): number | undefined {
  const header = single(value);
  if (header === undefined || !/^(0|[1-9][0-9]{0,8})$/u.test(header)) return undefined;
  const milliseconds = Number(header) * 1_000;
  return Number.isSafeInteger(milliseconds) ? Math.min(milliseconds, maximumMs) : undefined;
}

function resolveWithDeadline(
  resolver: AddressResolver,
  hostname: string,
  signal: AbortSignal,
  timeoutMs: number,
): Promise<readonly ResolvedAddress[]> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (action: () => void): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      action();
    };
    const onAbort = (): void => finish(() => reject(httpError("network")));
    const timer = setTimeout(() => finish(() => reject(httpError("network"))), timeoutMs);
    timer.unref();
    signal.addEventListener("abort", onAbort, { once: true });
    if (signal.aborted) {
      onAbort();
      return;
    }
    resolver.resolve(hostname).then(
      (addresses) => finish(() => resolve(addresses)),
      () => finish(() => reject(httpError("network"))),
    );
  });
}
