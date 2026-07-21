import {
  createHttpHooks,
  type DnsOptions,
  type HttpHooks,
  type HttpIpAllowInfo,
} from "@earendil-works/gondolin";
import {
  isPublicResolvedAddress,
  normalizeResolvedAddress,
} from "./capabilities.js";
import type {
  NetworkDestination,
  NetworkOriginCapability,
  NetworkPolicy,
} from "./domain.js";
import type { RuntimeGrant } from "./grants.js";

const HOSTNAME = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/;
const FORBIDDEN_WILDCARD_BASES = new Set([
  "com", "org", "net", "io", "dev", "app", "co", "me", "info", "biz", "ai", "sh",
  "uk", "us", "de", "fr", "jp", "cn", "au", "ca", "nl", "se", "no", "fi", "dk",
  "co.uk", "com.au", "or.jp", "github.io",
]);

export interface NetworkEnforcement {
  readonly netEnabled: boolean;
  readonly allowWebSockets: false;
  readonly httpHooks?: HttpHooks;
  readonly dns?: DnsOptions;
}

export interface DynamicNetworkAuthority {
  readonly activeGrants: () => ReadonlyArray<RuntimeGrant>;
  readonly consumeOnce: (grantId: string) => Promise<boolean>;
}

interface RequestOrigin {
  readonly scheme: "http" | "https";
  readonly host: string;
  readonly port: number;
}

export interface NetworkDecision {
  readonly allowed: boolean;
  readonly reason?: "network.capability_inactive" | "network.protocol_unsupported" | "network.rebinding_denied";
  readonly grantId?: string;
  readonly suggestedCapability?: NetworkOriginCapability;
}

const destinationPatterns = (destination: NetworkDestination): ReadonlyArray<string> => {
  switch (destination.kind) {
    case "exact":
      return [destination.host];
    case "subdomains":
      return [`*.${destination.host}`];
    case "host-and-subdomains":
      return [destination.host, `*.${destination.host}`];
  }
};

const destinationMatches = (
  destination: NetworkDestination,
  hostname: string,
  port: number,
): boolean => {
  if (!(destination.ports ?? [443]).includes(port)) return false;
  switch (destination.kind) {
    case "exact":
      return hostname === destination.host;
    case "subdomains":
      return hostname.endsWith(`.${destination.host}`) && hostname !== destination.host;
    case "host-and-subdomains":
      return hostname === destination.host || hostname.endsWith(`.${destination.host}`);
  }
};

const parseRequestOrigin = (request: Request): RequestOrigin | undefined => {
  let url: URL;
  try {
    url = new URL(request.url);
  } catch {
    return undefined;
  }
  if (request.method.toUpperCase() === "CONNECT" || (url.protocol !== "http:" && url.protocol !== "https:")) {
    return undefined;
  }
  if (url.username !== "" || url.password !== "") return undefined;
  const scheme = url.protocol.slice(0, -1) as "http" | "https";
  const rawHostname = url.hostname.toLowerCase();
  const host = rawHostname.startsWith("[") && rawHostname.endsWith("]")
    ? normalizeResolvedAddress(rawHostname.slice(1, -1)).address
    : rawHostname;
  if (
    host.includes("*") ||
    (normalizeResolvedAddressSafe(host) === undefined && (!HOSTNAME.test(host) || host.includes(":")))
  ) {
    return undefined;
  }
  const port = url.port === "" ? (scheme === "https" ? 443 : 80) : Number(url.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return undefined;
  return { scheme, host, port };
};

const normalizeResolvedAddressSafe = (address: string): string | undefined => {
  try {
    return normalizeResolvedAddress(address).address;
  } catch {
    return undefined;
  }
};

const staticOriginAllowed = (policy: NetworkPolicy, origin: RequestOrigin): boolean => {
  if (origin.scheme !== "https") return false;
  switch (policy.mode) {
    case "deny-all":
      return false;
    case "public-anonymous":
      return origin.port === 443;
    case "bundles":
      return policy.destinations.some((destination) => destinationMatches(destination, origin.host, origin.port));
  }
};

const capabilityMatches = (
  capability: RuntimeGrant["capabilities"][number],
  origin: RequestOrigin,
): boolean =>
  capability.scheme === origin.scheme &&
  capability.host === origin.host &&
  capability.ports.includes(origin.port);

const matchingGrantCapabilities = (
  grants: ReadonlyArray<RuntimeGrant>,
  origin: RequestOrigin,
): ReadonlyArray<{
  readonly grant: RuntimeGrant;
  readonly capability: RuntimeGrant["capabilities"][number];
}> =>
  grants
    .flatMap((grant) => grant.capabilities
      .filter((capability) => capabilityMatches(capability, origin))
      .map((capability) => ({ grant, capability })))
    .sort((left, right) => Number(left.grant.scope === "once") - Number(right.grant.scope === "once"));

const suggestedPublicCapability = (origin: RequestOrigin): NetworkOriginCapability => ({
  version: 1,
  kind: "network-origin",
  scheme: origin.scheme,
  host: origin.host,
  ports: [origin.port],
  addressMode: "public",
});

export const evaluateNetworkRequest = (
  policy: NetworkPolicy,
  grants: ReadonlyArray<RuntimeGrant>,
  request: Request,
): NetworkDecision => {
  const origin = parseRequestOrigin(request);
  if (origin === undefined) {
    return { allowed: false, reason: "network.protocol_unsupported" };
  }
  if (staticOriginAllowed(policy, origin)) return { allowed: true };
  const match = matchingGrantCapabilities(grants, origin)[0];
  if (match !== undefined) return { allowed: true, grantId: match.grant.grantId };
  return {
    allowed: false,
    reason: "network.capability_inactive",
    suggestedCapability: suggestedPublicCapability(origin),
  };
};

export const evaluateNetworkAddress = (
  policy: NetworkPolicy,
  grants: ReadonlyArray<RuntimeGrant>,
  info: HttpIpAllowInfo,
): NetworkDecision => {
  const normalizedIp = normalizeResolvedAddressSafe(info.ip);
  if (normalizedIp === undefined) {
    return { allowed: false, reason: "network.rebinding_denied" };
  }
  const rawHostname = info.hostname.toLowerCase();
  const unbracketed = rawHostname.startsWith("[") && rawHostname.endsWith("]")
    ? rawHostname.slice(1, -1)
    : rawHostname;
  const origin: RequestOrigin = {
    scheme: info.protocol,
    host: normalizeResolvedAddressSafe(unbracketed) ?? unbracketed,
    port: info.port,
  };
  if (staticOriginAllowed(policy, origin)) {
    return isPublicResolvedAddress(normalizedIp)
      ? { allowed: true }
      : { allowed: false, reason: "network.rebinding_denied" };
  }
  const matches = matchingGrantCapabilities(grants, origin);
  for (const { grant, capability } of matches) {
    const addressAllowed = capability.addressMode === "public"
      ? isPublicResolvedAddress(normalizedIp)
      : capability.pinnedAddresses.includes(normalizedIp);
    if (addressAllowed) return { allowed: true, grantId: grant.grantId };
  }
  return {
    allowed: false,
    reason: matches.length === 0 ? "network.capability_inactive" : "network.rebinding_denied",
    ...(matches.length === 0 ? { suggestedCapability: suggestedPublicCapability(origin) } : {}),
  };
};

export const validateNetworkPolicy = (policy: NetworkPolicy): void => {
  if (policy.mode === "bundles" && policy.destinations.length === 0) {
    throw new Error("bundles network policy requires at least one destination");
  }
  if (policy.mode !== "bundles" && policy.destinations.length !== 0) {
    throw new Error(`${policy.mode} network policy cannot carry destinations`);
  }
  for (const destination of policy.destinations) {
    if (
      destination.host !== destination.host.toLowerCase() ||
      !HOSTNAME.test(destination.host) ||
      destination.host.includes(":") ||
      /^\d{1,3}(?:\.\d{1,3}){3}$/.test(destination.host)
    ) {
      throw new Error(`invalid network destination host: ${destination.host}`);
    }
    if (
      destination.kind !== "exact" &&
      (FORBIDDEN_WILDCARD_BASES.has(destination.host) || !destination.host.includes("."))
    ) {
      throw new Error(`refusing to wildcard a public suffix: ${destination.host}`);
    }
  }
};

export const isNetworkRequestAllowed = (policy: NetworkPolicy, request: Request): boolean => {
  const origin = parseRequestOrigin(request);
  return origin !== undefined && staticOriginAllowed(policy, origin);
};

export const buildNetworkEnforcement = (
  policy: NetworkPolicy,
  dynamic?: DynamicNetworkAuthority,
): NetworkEnforcement => {
  validateNetworkPolicy(policy);
  if (dynamic === undefined && policy.mode === "deny-all") {
    return { netEnabled: false, allowWebSockets: false };
  }

  const allowedHosts = dynamic === undefined
    ? policy.mode === "public-anonymous"
      ? ["*"]
      : [...new Set(policy.destinations.flatMap(destinationPatterns))]
    : ["*"];
  const oncePermits = new Map<string, {
    readonly grant: RuntimeGrant;
    readonly expiresAt: number;
  }>();
  const grantsForAddressCheck = (): ReadonlyArray<RuntimeGrant> => {
    const now = Date.now();
    for (const [grantId, permit] of oncePermits) {
      if (permit.expiresAt <= now) oncePermits.delete(grantId);
    }
    return [
      ...(dynamic?.activeGrants() ?? []),
      ...[...oncePermits.values()].map(({ grant }) => grant),
    ];
  };
  const { httpHooks } = createHttpHooks({
    allowedHosts,
    blockInternalRanges: dynamic === undefined,
    isRequestAllowed: dynamic === undefined
      ? (request) => isNetworkRequestAllowed(policy, request)
      : async (request) => {
          const active = dynamic.activeGrants();
          const decision = evaluateNetworkRequest(policy, active, request);
          if (!decision.allowed || decision.grantId === undefined) return decision.allowed;
          const selected = active.find((grant) => grant.grantId === decision.grantId);
          if (selected === undefined) return false;
          if (selected.scope !== "once") return true;
          if (!await dynamic.consumeOnce(selected.grantId)) return false;
          oncePermits.set(selected.grantId, {
            grant: selected,
            expiresAt: Date.now() + 60_000,
          });
          return true;
        },
    ...(dynamic === undefined ? {} : {
      onRequest: (request: Request) => {
        const decision = evaluateNetworkRequest(policy, dynamic.activeGrants(), request);
        if (decision.allowed) return request;
        return new Response(JSON.stringify({
          type: "about:blank",
          title: "Network capability required",
          status: 403,
          reason: decision.reason,
          ...(decision.suggestedCapability === undefined
            ? {}
            : { suggestedCapability: decision.suggestedCapability }),
        }), {
          status: 403,
          headers: {
            "content-type": "application/problem+json",
            "cache-control": "no-store",
          },
        });
      },
      isIpAllowed: async (info: HttpIpAllowInfo) =>
        evaluateNetworkAddress(policy, grantsForAddressCheck(), info).allowed,
    }),
  });

  return {
    netEnabled: true,
    allowWebSockets: false,
    httpHooks,
    dns: {
      mode: "synthetic",
      syntheticHostMapping: "per-host",
    },
  };
};
