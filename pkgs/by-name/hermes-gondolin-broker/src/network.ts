/**
 * Mediated egress (V3 §6, §11.3, §12).
 *
 * DNS and supported HTTP(S) traffic are evaluated outside the guest through
 * Gondolin's hook surface. The hard floor is non-negotiable: synthetic DNS,
 * resolved-address (anti-rebinding) checks, internal/loopback/link-local/
 * metadata denial, and WebSocket/CONNECT/raw-TCP/SSH denial apply to every
 * mode. `allowedHosts` is always an explicit list — `undefined` (SDK
 * allow-all) is never passed. `public-anonymous` is a deliberate policy mode
 * enforced by this reviewed hook with Gondolin configured fail-closed.
 */
import { BrokerError, REASONS } from "./errors.js";
import type { DestinationRule, EffectivePolicy } from "./policy.js";
import { destinationToHostPatterns } from "./policy.js";

export interface NormalizedRequest {
  protocol: "http" | "https";
  hostname: string;
  port: number;
  method: string;
  /** path without query (query is never logged or matched) */
  path: string;
}

export interface NetworkDecision {
  allow: boolean;
  reason: string | null;
  /** audit-safe origin */
  origin: string;
}

export type RequestHook = (request: NormalizedRequest) => NetworkDecision;

export interface ResolvedAddressInfo {
  hostname: string;
  ip: string;
  family: 4 | 6;
  port: number;
  protocol: "http" | "https";
}

export type IpHook = (info: ResolvedAddressInfo) => boolean;

export interface NetworkEnforcement {
  /** Gondolin HttpHooks-shaped object (typed opaquely to avoid SDK import) */
  httpHooks: unknown;
  dns: unknown;
  allowWebSockets: boolean;
  /** direct access for tests and the credential pipeline */
  isRequestAllowed: (request: { url: string; method: string }) => Promise<boolean>;
  isIpAllowed: (info: ResolvedAddressInfo) => Promise<boolean>;
  allowedHosts: string[];
}

interface HttpHooksFactory {
  createHttpHooks(options: {
    allowedHosts: string[];
    blockInternalRanges: boolean;
    isRequestAllowed: (request: { url: string; method: string }) => Promise<boolean>;
    isIpAllowed: (info: ResolvedAddressInfo) => Promise<boolean>;
  }): { httpHooks: unknown };
}

// ---------------------------------------------------------------------------
// Address classification (floor; §11.3)
// ---------------------------------------------------------------------------

const IPV4_RANGES: Array<[number, number, string]> = [
  [0x00000000, 0x00ffffff, "this-network"],       // 0.0.0.0/8
  [0x0a000000, 0x0affffff, "rfc1918-10"],         // 10.0.0.0/8
  [0x7f000000, 0x7fffffff, "loopback"],           // 127.0.0.0/8
  [0xa9fe0000, 0xa9feffff, "link-local"],         // 169.254.0.0/16
  [0xac100000, 0xac1fffff, "rfc1918-172"],        // 172.16.0.0/12
  [0xc0a80000, 0xc0a8ffff, "rfc1918-192"],        // 192.168.0.0/16
  [0xc0000000, 0xc00000ff, "protocol-assign"],    // 192.0.0.0/24
  [0xc0000200, 0xc00002ff, "test-net-1"],         // 192.0.2.0/24
  [0xc6120000, 0xc613ffff, "benchmark-198"],      // 198.18.0.0/15
  [0xc6336400, 0xc63364ff, "cg-nat"],             // 198.51.100.0/24 is test-net-2; cg-nat is 100.64/10
  [0x64400000, 0x647fffff, "cg-nat"],             // 100.64.0.0/10
  [0xcb007100, 0xcb0071ff, "test-net-3"],         // 203.0.113.0/24
  [0xe0000000, 0xefffffff, "multicast"],          // 224.0.0.0/4
  [0xf0000000, 0xffffffff, "reserved"],           // 240.0.0.0/4
];

/** IPv4-mapped/transition forms are unwrapped before range checks. */
export function isInternalAddress(ip: string): boolean {
  const v4 = parseIpv4(ip);
  if (v4 !== null) return isInternalIpv4(v4);
  return isInternalIpv6(ip);
}

function parseIpv4(ip: string): number | null {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  let value = 0;
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const octet = Number(part);
    if (octet > 255) return null;
    value = (value << 8) | octet;
  }
  return value >>> 0;
}

function isInternalIpv4(value: number): boolean {
  for (const [base, mask, _name] of IPV4_RANGES) {
    if (value >= base && value <= mask) return true;
  }
  return false;
}

function isInternalIpv6(ip: string): boolean {
  const normalized = ip.toLowerCase();
  if (normalized === "::1" || normalized === "::") return true; // loopback / unspecified
  // IPv4-mapped / translated forms
  const mapped = normalized.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped?.[1] !== undefined) {
    const v4 = parseIpv4(mapped[1]);
    return v4 !== null && isInternalIpv4(v4);
  }
  const firstGroup = normalized.split(":")[0] ?? "";
  const first = parseInt(firstGroup || "0", 16);
  if (Number.isNaN(first)) return true; // fail closed on unparseable
  if ((first & 0xffc0) === 0xfe80) return true; // fe80::/10 link-local
  if ((first & 0xfe00) === 0xfc00) return true; // fc00::/7 ULA
  if ((first & 0xff00) === 0xff00) return true; // ff00::/8 multicast
  // 2001:db8::/32 documentation
  if (normalized.startsWith("2001:db8:") || normalized.startsWith("2001:0db8:")) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Request normalization and evaluation
// ---------------------------------------------------------------------------

const DEFAULT_PORTS: Record<string, number> = { "http:": 80, "https:": 443 };

/** Normalize a request URL for policy evaluation. Fails closed on
 * unparseable or non-HTTP(S) input. */
export function normalizeRequestUrl(url: string, method: string): NormalizedRequest {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new BrokerError(REASONS.NET_PROTOCOL_DENIED, "unparseable request URL");
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new BrokerError(REASONS.NET_PROTOCOL_DENIED, "only http/https egress is supported", {
      protocol: parsed.protocol.replace(":", ""),
    });
  }
  const port = parsed.port === "" ? DEFAULT_PORTS[parsed.protocol]! : Number(parsed.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new BrokerError(REASONS.NET_PORT_DENIED, "invalid port", { port: parsed.port });
  }
  return {
    protocol: parsed.protocol === "https:" ? "https" : "http",
    hostname: parsed.hostname.toLowerCase(),
    port,
    method: method.toUpperCase(),
    path: parsed.pathname,
  };
}

function destinationMatches(rule: DestinationRule, hostname: string, port: number): boolean {
  const ports = rule.ports ?? [443];
  if (!ports.includes(port)) return false;
  switch (rule.kind) {
    case "exact":
      return hostname === rule.host;
    case "subdomains":
      return hostname.endsWith(`.${rule.host}`) && hostname !== rule.host;
    case "host-and-subdomains":
      return hostname === rule.host || (hostname.endsWith(`.${rule.host}`) && hostname !== rule.host);
  }
}

function hostnameLooksLikeIp(hostname: string): boolean {
  return parseIpv4(hostname) !== null || hostname.includes(":");
}

/**
 * Build the request allow/deny hook for an effective policy. The hook is
 * pure and synchronous; the credential pipeline (Phase 6) composes after it
 * in the mandatory authorization order (§12.5).
 */
export function buildRequestHook(policy: EffectivePolicy): RequestHook {
  return (request: NormalizedRequest): NetworkDecision => {
    const origin = `${request.protocol}://${request.hostname}${[443, 80].includes(request.port) ? "" : `:${request.port}`}`;

    // IP-literal destinations are never allowed (§12.2).
    if (hostnameLooksLikeIp(request.hostname)) {
      return { allow: false, reason: REASONS.NET_HOST_DENIED, origin };
    }

    if (policy.network.mode === "deny-all") {
      return { allow: false, reason: REASONS.NET_HOST_DENIED, origin };
    }

    if (policy.network.mode === "public-anonymous") {
      // Public HTTPS on standard ports only; internal-range and rebinding
      // checks still apply at the resolved-address layer.
      if (request.protocol !== "https" || (request.port !== 443)) {
        return { allow: false, reason: REASONS.NET_PROTOCOL_DENIED, origin };
      }
      return { allow: true, reason: null, origin };
    }

    // bundles mode: destination must match at least one rule.
    const matched = policy.network.destinations.some((rule) =>
      destinationMatches(rule, request.hostname, request.port),
    );
    if (!matched) {
      return { allow: false, reason: REASONS.NET_HOST_DENIED, origin };
    }
    if (request.protocol !== "https" && !policy.network.destinations.some(
      (rule) => destinationMatches(rule, request.hostname, request.port) && (rule.ports ?? [443]).includes(80),
    )) {
      // HTTP is only allowed when an explicit rule opens port 80 for this host.
      return { allow: false, reason: REASONS.NET_PROTOCOL_DENIED, origin };
    }
    return { allow: true, reason: null, origin };
  };
}

/** Build the resolved-address hook: anti-rebinding and internal-range
 * denial on every mode (§11.3). */
export function buildIpHook(): IpHook {
  return (info: ResolvedAddressInfo): boolean => !isInternalAddress(info.ip);
}

/** Gondolin host patterns for the effective policy. Explicit list always;
 * `public-anonymous` uses the SDK's proven `*` match-all with the decision
 * enforced by the reviewed hook (§12.2). */
export function allowedHostPatterns(policy: EffectivePolicy): string[] {
  if (policy.network.mode === "deny-all") return [];
  if (policy.network.mode === "public-anonymous") return ["*"];
  const patterns = policy.network.destinations.flatMap(destinationToHostPatterns);
  return [...new Set(patterns)];
}

/**
 * Assemble the Gondolin-facing enforcement object for one VM.
 *
 * Composition goes through the SDK's reviewed createHttpHooks factory: it
 * applies the explicit allowedHosts list and internal-range denial around
 * the policy hooks, and (Phase 6) performs placeholder substitution after
 * user hooks so no hook ever sees a post-substitution request (§12.5).
 *
 * The factory is loaded lazily through the same seam as the VM provider so
 * pure policy logic stays testable without native components.
 */
export function buildNetworkEnforcement(
  policy: EffectivePolicy,
  sdk: HttpHooksFactory,
): NetworkEnforcement {
  const requestHook = buildRequestHook(policy);
  const ipHook = buildIpHook();
  const allowedHosts = allowedHostPatterns(policy);

  const isRequestAllowed = async (request: { url: string; method: string }): Promise<boolean> => {
    const normalized = normalizeRequestUrl(request.url, request.method);
    return requestHook(normalized).allow;
  };
  const isIpAllowed = async (info: ResolvedAddressInfo): Promise<boolean> => ipHook(info);

  const { httpHooks } = sdk.createHttpHooks({
    allowedHosts,
    blockInternalRanges: true,
    isRequestAllowed,
    isIpAllowed,
  });

  return {
    httpHooks,
    dns: {
      mode: "synthetic",
      syntheticHostMapping: "per-host",
    },
    allowWebSockets: false,
    isRequestAllowed,
    isIpAllowed,
    allowedHosts,
  };
}
