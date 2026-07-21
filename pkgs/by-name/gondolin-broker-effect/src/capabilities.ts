import { Effect } from "effect";
import { lookup } from "node:dns/promises";
import { BlockList, isIP } from "node:net";
import { domainToASCII } from "node:url";
import {
  CapabilityBatch,
  decodeExact,
  NetworkOriginCapability,
  type NetworkOriginCapability as NetworkOriginCapabilityType,
} from "./domain.js";
import { brokerError, type BrokerError } from "./errors.js";

const HOSTNAME = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/;

type AddressFamily = 4 | 6;

export interface ResolvedAddress {
  readonly address: string;
  readonly family: AddressFamily;
}

export type AddressResolver = (host: string) => Promise<ReadonlyArray<ResolvedAddress>>;

export interface PreparedNetworkOrigin {
  readonly version: 1;
  readonly kind: "network-origin";
  readonly scheme: "http" | "https";
  readonly host: string;
  readonly ports: ReadonlyArray<number>;
  readonly addressMode: "public" | "pinned-private";
  readonly canonicalOrigin: string;
  readonly pinnedAddresses: ReadonlyArray<string>;
}

const publicBlockedIpv4 = new BlockList();
for (const [address, prefix] of [
  ["0.0.0.0", 8],
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["127.0.0.0", 8],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.0.0.0", 24],
  ["192.0.2.0", 24],
  ["192.88.99.0", 24],
  ["192.168.0.0", 16],
  ["198.18.0.0", 15],
  ["198.51.100.0", 24],
  ["203.0.113.0", 24],
  ["224.0.0.0", 4],
  ["240.0.0.0", 4],
] as const) {
  publicBlockedIpv4.addSubnet(address, prefix, "ipv4");
}
const publicBlockedIpv6 = new BlockList();
for (const [address, prefix] of [
  ["::", 128],
  ["::1", 128],
  ["::ffff:0:0", 96],
  ["100::", 64],
  ["2001:db8::", 32],
  ["fc00::", 7],
  ["fe80::", 10],
  ["ff00::", 8],
] as const) {
  publicBlockedIpv6.addSubnet(address, prefix, "ipv6");
}
const publicIpv6 = new BlockList();
publicIpv6.addSubnet("2000::", 3, "ipv6");

const privateAllowedIpv4 = new BlockList();
for (const [address, prefix] of [
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["172.16.0.0", 12],
  ["192.168.0.0", 16],
] as const) {
  privateAllowedIpv4.addSubnet(address, prefix, "ipv4");
}
const privateAllowedIpv6 = new BlockList();
privateAllowedIpv6.addSubnet("fc00::", 7, "ipv6");

const normalizeIp = (address: string): ResolvedAddress => {
  const family = isIP(address);
  if (family === 4) {
    return { address: address.split(".").map((part) => String(Number(part))).join("."), family: 4 };
  }
  if (family === 6) {
    const bracketed = new URL(`http://[${address}]/`).hostname;
    return { address: bracketed.slice(1, -1).toLowerCase(), family: 6 };
  }
  throw brokerError("capability.invalid", "network origin resolved to an invalid IP address");
};

const isPublicAddress = ({ address, family }: ResolvedAddress): boolean =>
  family === 4
    ? !publicBlockedIpv4.check(address, "ipv4")
    : publicIpv6.check(address, "ipv6") && !publicBlockedIpv6.check(address, "ipv6");

const isPrivateAddress = ({ address, family }: ResolvedAddress): boolean =>
  family === 4
    ? privateAllowedIpv4.check(address, "ipv4")
    : privateAllowedIpv6.check(address, "ipv6");

const normalizeHost = (raw: string): { readonly host: string; readonly literal?: ResolvedAddress } => {
  if (raw.trim() !== raw || raw.includes("*") || /[@/?#\\\[\]]/.test(raw)) {
    throw brokerError("capability.invalid", "network origin host is not an exact hostname or IP literal");
  }
  const family = isIP(raw);
  if (family !== 0) {
    const literal = normalizeIp(raw);
    return { host: literal.address, literal };
  }
  const withoutRootDot = raw.endsWith(".") ? raw.slice(0, -1) : raw;
  const host = domainToASCII(withoutRootDot).toLowerCase();
  if (host.length === 0 || host.length > 253 || !HOSTNAME.test(host)) {
    throw brokerError("capability.invalid", "network origin host is invalid");
  }
  return { host };
};

const decodeCapability = (input: unknown): Effect.Effect<NetworkOriginCapabilityType, BrokerError> => {
  if (typeof input !== "object" || input === null || !("kind" in input) || input.kind !== "network-origin") {
    return Effect.fail(brokerError("capability.unsupported", "capability kind is not installed"));
  }
  if (!("version" in input) || input.version !== 1) {
    return Effect.fail(brokerError("capability.unsupported", "capability version is not installed"));
  }
  return decodeExact(NetworkOriginCapability, input).pipe(
    Effect.mapError((error) =>
      brokerError("capability.invalid", "network-origin capability does not match its schema", {
        cause: String(error),
      })
    ),
  );
};

const defaultResolver: AddressResolver = async (host) => {
  const answers = await lookup(host, { all: true, verbatim: true });
  return answers.flatMap((answer) =>
    answer.family === 4 || answer.family === 6
      ? [{ address: answer.address, family: answer.family }]
      : []
  );
};

const resolveCanonical = (
  host: string,
  literal: ResolvedAddress | undefined,
  resolver: AddressResolver,
): Effect.Effect<ReadonlyArray<ResolvedAddress>, BrokerError> => {
  if (literal !== undefined) return Effect.succeed([literal]);
  return Effect.tryPromise({
    try: () => resolver(host),
    catch: (error) => brokerError("network.resolution_failed", "network origin could not be resolved", {
      host,
      cause: error instanceof Error ? error.message : String(error),
    }),
  }).pipe(
    Effect.flatMap((answers) =>
      Effect.try({
        try: () => {
          const canonical = answers.map((answer) => normalizeIp(answer.address));
          const deduplicated = [...new Map(canonical.map((answer) => [answer.address, answer])).values()]
            .sort((left, right) => left.address.localeCompare(right.address));
          if (deduplicated.length === 0) {
            throw brokerError("network.resolution_failed", "network origin returned no usable addresses", { host });
          }
          return deduplicated;
        },
        catch: (error) => error instanceof Error && "reason" in error
          ? error as BrokerError
          : brokerError("network.resolution_failed", "network origin returned invalid addresses", { host }),
      })
    ),
  );
};

export const canonicalCapabilityKey = (capability: PreparedNetworkOrigin): string => JSON.stringify({
  version: capability.version,
  kind: capability.kind,
  scheme: capability.scheme,
  host: capability.host,
  ports: capability.ports,
  addressMode: capability.addressMode,
  pinnedAddresses: capability.pinnedAddresses,
});

export const prepareNetworkOrigin = (
  input: unknown,
  resolver: AddressResolver = defaultResolver,
): Effect.Effect<PreparedNetworkOrigin, BrokerError> =>
  Effect.gen(function* () {
    const proposal = yield* decodeCapability(input);
    const normalized = yield* Effect.try({
      try: () => normalizeHost(proposal.host),
      catch: (error) => error instanceof Error && "reason" in error
        ? error as BrokerError
        : brokerError("capability.invalid", "network origin host is invalid"),
    });
    const addresses = yield* resolveCanonical(normalized.host, normalized.literal, resolver);
    const predicate = proposal.addressMode === "public" ? isPublicAddress : isPrivateAddress;
    if (!addresses.every(predicate)) {
      return yield* brokerError(
        "network.address_forbidden",
        proposal.addressMode === "public"
          ? "public network origin resolved outside public address space"
          : "private network origin resolved outside grantable private address space",
        { host: normalized.host, addressMode: proposal.addressMode },
      );
    }
    const ports = [...new Set(proposal.ports ?? [proposal.scheme === "https" ? 443 : 80])]
      .sort((left, right) => left - right);
    const displayHost = normalized.literal?.family === 6 ? `[${normalized.host}]` : normalized.host;
    return {
      version: 1,
      kind: "network-origin",
      scheme: proposal.scheme,
      host: normalized.host,
      ports,
      addressMode: proposal.addressMode,
      canonicalOrigin: `${proposal.scheme}://${displayHost}`,
      pinnedAddresses: proposal.addressMode === "pinned-private"
        ? addresses.map((address) => address.address)
        : [],
    };
  });

export const prepareCapabilityBatch = (
  input: unknown,
  resolver: AddressResolver = defaultResolver,
): Effect.Effect<ReadonlyArray<PreparedNetworkOrigin>, BrokerError> =>
  decodeExact(CapabilityBatch, input).pipe(
    Effect.mapError((error) => brokerError("capability.invalid", "capability batch is invalid", { cause: String(error) })),
    Effect.flatMap((batch) => Effect.forEach(batch, (capability) => prepareNetworkOrigin(capability, resolver))),
    Effect.map((prepared) => [...new Map(prepared.map((capability) => [canonicalCapabilityKey(capability), capability])).entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([, capability]) => capability)),
  );
