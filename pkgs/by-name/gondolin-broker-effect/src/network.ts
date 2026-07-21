import {
  createHttpHooks,
  type DnsOptions,
  type HttpHooks,
} from "@earendil-works/gondolin";
import type { NetworkDestination, NetworkPolicy } from "./domain.js";

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
  let url: URL;
  try {
    url = new URL(request.url);
  } catch {
    return false;
  }
  if (request.method.toUpperCase() === "CONNECT" || url.protocol !== "https:") return false;
  if (url.username !== "" || url.password !== "") return false;
  const hostname = url.hostname.toLowerCase();
  if (!HOSTNAME.test(hostname) || hostname.includes(":") || /^\d{1,3}(?:\.\d{1,3}){3}$/.test(hostname)) {
    return false;
  }
  const port = url.port === "" ? 443 : Number(url.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return false;

  switch (policy.mode) {
    case "deny-all":
      return false;
    case "public-anonymous":
      return port === 443;
    case "bundles":
      return policy.destinations.some((destination) => destinationMatches(destination, hostname, port));
  }
};

export const buildNetworkEnforcement = (policy: NetworkPolicy): NetworkEnforcement => {
  validateNetworkPolicy(policy);
  if (policy.mode === "deny-all") {
    return { netEnabled: false, allowWebSockets: false };
  }

  const allowedHosts = policy.mode === "public-anonymous"
    ? ["*"]
    : [...new Set(policy.destinations.flatMap(destinationPatterns))];
  const { httpHooks } = createHttpHooks({
    allowedHosts,
    blockInternalRanges: true,
    isRequestAllowed: (request) => isNetworkRequestAllowed(policy, request),
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
