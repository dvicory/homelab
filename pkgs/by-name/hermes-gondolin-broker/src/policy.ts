/**
 * Policy schema and pure evaluator (V3 §11).
 *
 * Nix is the authoring DSL; it renders inert, versioned JSON. The broker
 * validates strictly (unknown versions, fields, bundles, adapters, actions,
 * and grants fail closed) and composes layers by monotonic attenuation:
 *
 *   hard safety floor ∩ profile maximum ∩ worklane maximum
 *     ∩ sandbox template ∩ active runtime grants = effective policy
 *
 * - allowed sets intersect
 * - numeric ceilings take the minimum
 * - restrictive enum values win
 * - only capabilities declared `grantable` may be activated
 *
 * There is no rule priority, implicit override, negation, recursion, regex
 * policy language, or embedded code in policy data.
 */
import { createHash } from "node:crypto";
import { BrokerError, REASONS } from "./errors.js";

// ---------------------------------------------------------------------------
// Schema types (the rendered JSON contract; Nix emits exactly this shape)
// ---------------------------------------------------------------------------

export const POLICY_VERSION = 1 as const;

export type HostMatchKind = "exact" | "subdomains" | "host-and-subdomains";

export interface DestinationRule {
  kind: HostMatchKind;
  /** normalized lowercase hostname; IP literals forbidden unless kind is exact and typed via `ip` */
  host: string;
  /** allowed destination ports; defaults to [443] */
  ports?: number[];
}

export interface NetworkBundle {
  destinations: DestinationRule[];
  allowWebSockets?: boolean;
  allowConnect?: boolean;
  allowRawTcp?: boolean;
  allowSsh?: boolean;
}

export interface CredentialCapability {
  networkBundle: string;
  adapter: string;
  /** logical secret id; the value is never present in policy data */
  secretRef: string;
  targets: Array<{ owner: string; repositories?: string[] }>;
  actions: string[];
  activation: "automatic" | "approval" | "denied";
  maximumGrantScope: "once" | "task" | "session";
  /** placeholder prefix the guest must present; substitution is host-side */
  placeholderPrefix?: string;
}

export interface ResourceLimits {
  cpus?: number;
  memoryMiB?: number;
  diskMiB?: number;
  pidsMax?: number;
  /** per-stream output cap in bytes */
  maxOutputBytes?: number;
  /** maximum concurrently running guest processes per VM */
  maxExecsPerVm?: number;
  /** wall-clock deadline for one foreground command in ms */
  maxCommandMs?: number;
  /** background session ring buffer in bytes */
  ringBufferBytes?: number;
}

export type GrantScope = "once" | "task" | "session";

export interface SandboxTemplate {
  version: number;
  asset: string;
  network:
    | { mode: "deny-all" }
    | { mode: "bundles"; bundles: string[] }
    | { mode: "public-anonymous" };
  workspace:
    | { type: "private" }
    | { type: "project"; project: string }
    | { type: "durable"; durableId: string }
    | { type: "none" };
  /** declared read-only input ids (broker-owned paths; never guest-chosen) */
  readOnlyInputs?: string[];
  resources?: ResourceLimits;
  /** environment variable names the gateway may pass through */
  envAllow?: string[];
  grantScopes?: GrantScope[];
  /** credential capability ids this template may activate */
  credentials?: string[];
  /** bundle/capability ids activatable at runtime within profile maximum */
  grantable?: string[];
}

export interface AssetTemplatePair {
  asset: string;
  template: string;
}

export interface ProfileMaximum {
  networkBundles?: string[];
  credentialCapabilities?: string[];
  resources?: ResourceLimits;
  grantScopes?: GrantScope[];
}

export interface WorklanePolicy {
  /** default template for this worklane; must be one of its allowed pairs */
  defaultTemplate?: string;
  allowedPairs?: AssetTemplatePair[];
  maximum?: ProfileMaximum;
}

export interface ProfilePolicy {
  defaultTemplate: string;
  allowedPairs: AssetTemplatePair[];
  maximum: ProfileMaximum;
  worklanes?: Record<string, WorklanePolicy>;
}

export interface FloorPolicy {
  maxResources: Required<Omit<ResourceLimits, "maxCommandMs">> & { maxCommandMs: number };
  /** upper bound on concurrent VMs for the whole broker */
  maxVms: number;
  /** upper bound on VM starts per rolling minute */
  maxVmStartsPerMinute: number;
  /** protocol frame cap in bytes */
  maxFrameBytes: number;
  /** per-request stdin/env cap in bytes */
  maxInputBytes: number;
}

export interface PolicyFile {
  version: typeof POLICY_VERSION;
  /** content-derived identifier of this rendered policy (set by Nix) */
  policyId: string;
  floor: FloorPolicy;
  /**
   * Immutable guest asset catalog. `buildId` is normally absent: the
   * content-derived identity lives in the asset's own manifest.json and the
   * broker reads it at startup (V3 §9.4). When a policy pins `buildId`
   * explicitly, the broker verifies it against the manifest and fails
   * closed on mismatch.
   */
  assets: Record<string, { path: string; buildId?: string }>;
  bundles: Record<string, NetworkBundle>;
  credentialCapabilities: Record<string, CredentialCapability>;
  templates: Record<string, SandboxTemplate>;
  profiles: Record<string, ProfilePolicy>;
}

// ---------------------------------------------------------------------------
// Effective policy (evaluator output; what enforcement layers consume)
// ---------------------------------------------------------------------------

export interface EffectivePolicy {
  profile: string;
  worklane: string | null;
  assetName: string;
  assetPath: string;
  buildId: string;
  templateName: string;
  templateVersion: number;
  network:
    | { mode: "deny-all" }
    | { mode: "bundles"; destinations: DestinationRule[] }
    | { mode: "public-anonymous" };
  workspace: SandboxTemplate["workspace"];
  readOnlyInputs: string[];
  resources: Required<ResourceLimits>;
  envAllow: string[];
  grantScopes: GrantScope[];
  credentials: string[];
  grantable: string[];
  floor: FloorPolicy;
  /** sha256 over the canonical identity inputs (V3 §8.2) */
  policyHash: string;
}

// ---------------------------------------------------------------------------
// Validation helpers — fail closed on anything unknown (§11.2)
// ---------------------------------------------------------------------------

const KNOWN_TOP_LEVEL: Record<string, true> = {
  version: true,
  policyId: true,
  floor: true,
  assets: true,
  bundles: true,
  credentialCapabilities: true,
  templates: true,
  profiles: true,
};

const DESTINATION_FIELDS: Record<string, true> = { kind: true, host: true, ports: true };
const BUNDLE_FIELDS: Record<string, true> = {
  destinations: true,
  allowWebSockets: true,
  allowConnect: true,
  allowRawTcp: true,
  allowSsh: true,
};
const CAPABILITY_FIELDS: Record<string, true> = {
  networkBundle: true,
  adapter: true,
  secretRef: true,
  targets: true,
  actions: true,
  activation: true,
  maximumGrantScope: true,
  placeholderPrefix: true,
};
const TARGET_FIELDS: Record<string, true> = { owner: true, repositories: true };
const TEMPLATE_FIELDS: Record<string, true> = {
  version: true,
  asset: true,
  network: true,
  workspace: true,
  readOnlyInputs: true,
  resources: true,
  envAllow: true,
  grantScopes: true,
  credentials: true,
  grantable: true,
};
const NETWORK_FIELDS: Record<string, true> = { mode: true, bundles: true };
const PAIR_FIELDS: Record<string, true> = { asset: true, template: true };
const MAXIMUM_FIELDS: Record<string, true> = {
  networkBundles: true,
  credentialCapabilities: true,
  resources: true,
  grantScopes: true,
};
const PROFILE_FIELDS: Record<string, true> = {
  defaultTemplate: true,
  allowedPairs: true,
  maximum: true,
  worklanes: true,
};
const WORKLANE_FIELDS: Record<string, true> = { defaultTemplate: true, allowedPairs: true, maximum: true };
const FLOOR_FIELDS: Record<string, true> = {
  maxResources: true,
  maxVms: true,
  maxVmStartsPerMinute: true,
  maxFrameBytes: true,
  maxInputBytes: true,
};
const ASSET_FIELDS: Record<string, true> = { path: true, buildId: true };

function failInvalid(message: string, details: Record<string, unknown> = {}): never {
  throw new BrokerError(REASONS.POLICY_INVALID, message, details);
}

function assertObject(value: unknown, path: string): asserts value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    failInvalid(`${path} must be an object`);
  }
}

function assertNoUnknownFields(obj: Record<string, unknown>, known: Record<string, true>, path: string): void {
  for (const key of Object.keys(obj)) {
    if (!known[key]) {
      throw new BrokerError(REASONS.POLICY_UNKNOWN_FIELD, `${path}: unknown field '${key}'`, {
        field: key,
        path,
      });
    }
  }
}

function assertString(value: unknown, path: string): asserts value is string {
  if (typeof value !== "string" || value.length === 0) failInvalid(`${path} must be a non-empty string`);
}

function assertStringArray(value: unknown, path: string): asserts value is string[] {
  if (!Array.isArray(value) || value.some((v) => typeof v !== "string" || v.length === 0)) {
    failInvalid(`${path} must be an array of non-empty strings`);
  }
}

function assertInt(value: unknown, path: string, min: number, max: number): asserts value is number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    failInvalid(`${path} must be an integer in [${min}, ${max}]`);
  }
}

const HOSTNAME_RE = /^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/;
/** Public-suffix-like single labels and bare TLDs may not be wildcarded (§12.2). */
const FORBIDDEN_WILDCARD_BASES: Record<string, true> = {
  com: true, org: true, net: true, io: true, dev: true, app: true, co: true,
  me: true, info: true, biz: true, ai: true, sh: true, uk: true, us: true,
  de: true, fr: true, jp: true, cn: true, au: true, ca: true, nl: true,
  se: true, no: true, fi: true, dk: true, "co.uk": true, "com.au": true,
  "or.jp": true, "github.io": true,
};

function validateHostname(host: string, path: string): string {
  const normalized = host.trim().toLowerCase();
  if (normalized.length === 0) failInvalid(`${path}: empty hostname`);
  // IP literals are not hostnames; internal destinations are floor-denied and
  // exact internal services arrive only as reviewed service bundles (§11.3).
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(normalized) || normalized.includes(":")) {
    failInvalid(`${path}: IP literals are not valid destinations`, { host });
  }
  if (!HOSTNAME_RE.test(normalized)) {
    failInvalid(`${path}: invalid hostname`, { host });
  }
  return normalized;
}

function validateDestination(raw: unknown, path: string): DestinationRule {
  assertObject(raw, path);
  assertNoUnknownFields(raw, DESTINATION_FIELDS, path);
  const kind = raw.kind;
  if (kind !== "exact" && kind !== "subdomains" && kind !== "host-and-subdomains") {
    failInvalid(`${path}.kind must be exact|subdomains|host-and-subdomains`);
  }
  assertString(raw.host, `${path}.host`);
  const host = validateHostname(raw.host, `${path}.host`);
  if (kind !== "exact") {
    const labels = host.split(".");
    if (labels.length < 2 || FORBIDDEN_WILDCARD_BASES[host]) {
      failInvalid(`${path}.host: refusing to wildcard a public suffix`, { host });
    }
  }
  let ports: number[] | undefined;
  if (raw.ports !== undefined) {
    if (!Array.isArray(raw.ports) || raw.ports.length === 0) failInvalid(`${path}.ports must be a non-empty array`);
    for (const [i, p] of (raw.ports as unknown[]).entries()) {
      assertInt(p, `${path}.ports[${i}]`, 1, 65535);
    }
    ports = [...new Set(raw.ports as number[])].sort((a, b) => a - b);
  }
  return ports === undefined ? { kind, host } : { kind, host, ports };
}

function validateBundle(raw: unknown, path: string): NetworkBundle {
  assertObject(raw, path);
  assertNoUnknownFields(
    raw,
    BUNDLE_FIELDS,
    path,
  );
  if (!Array.isArray(raw.destinations) || raw.destinations.length === 0) {
    failInvalid(`${path}.destinations must be a non-empty array`);
  }
  const destinations = raw.destinations.map((d, i) => validateDestination(d, `${path}.destinations[${i}]`));
  for (const flag of ["allowWebSockets", "allowConnect", "allowRawTcp", "allowSsh"] as const) {
    if (raw[flag] !== undefined && raw[flag] !== false) {
      // The hard floor denies these protocols; a bundle may never enable them (§11.3).
      throw new BrokerError(REASONS.POLICY_ATTENUATION, `${path}.${flag} cannot lift the hard floor`, {
        field: flag,
      });
    }
  }
  return { destinations };
}

function validateCapability(raw: unknown, path: string): CredentialCapability {
  assertObject(raw, path);
  assertNoUnknownFields(
    raw,
    CAPABILITY_FIELDS,
    path,
  );
  assertString(raw.networkBundle, `${path}.networkBundle`);
  assertString(raw.adapter, `${path}.adapter`);
  assertString(raw.secretRef, `${path}.secretRef`);
  if (!Array.isArray(raw.targets)) failInvalid(`${path}.targets must be an array`);
  const targets = (raw.targets as unknown[]).map((t, i) => {
    const tp = `${path}.targets[${i}]`;
    assertObject(t, tp);
    assertNoUnknownFields(t, TARGET_FIELDS, tp);
    assertString(t.owner, `${tp}.owner`);
    if (t.repositories !== undefined) assertStringArray(t.repositories, `${tp}.repositories`);
    return t.repositories === undefined
      ? { owner: t.owner as string }
      : { owner: t.owner as string, repositories: t.repositories as string[] };
  });
  assertStringArray(raw.actions, `${path}.actions`);
  if (!["automatic", "approval", "denied"].includes(raw.activation as string)) {
    failInvalid(`${path}.activation must be automatic|approval|denied`);
  }
  if (!["once", "task", "session"].includes(raw.maximumGrantScope as string)) {
    failInvalid(`${path}.maximumGrantScope must be once|task|session`);
  }
  if (raw.placeholderPrefix !== undefined) assertString(raw.placeholderPrefix, `${path}.placeholderPrefix`);
  return {
    networkBundle: raw.networkBundle,
    adapter: raw.adapter,
    secretRef: raw.secretRef,
    targets,
    actions: raw.actions as string[],
    activation: raw.activation as CredentialCapability["activation"],
    maximumGrantScope: raw.maximumGrantScope as CredentialCapability["maximumGrantScope"],
    ...(raw.placeholderPrefix !== undefined ? { placeholderPrefix: raw.placeholderPrefix as string } : {}),
  };
}

const RESOURCE_FIELDS: Record<string, true> = {
  cpus: true, memoryMiB: true, diskMiB: true, pidsMax: true,
  maxOutputBytes: true, maxExecsPerVm: true, maxCommandMs: true,
  ringBufferBytes: true,
};

function validateResources(raw: unknown, path: string): ResourceLimits {
  if (raw === undefined) return {};
  assertObject(raw, path);
  assertNoUnknownFields(raw, RESOURCE_FIELDS, path);
  const out: ResourceLimits = {};
  for (const key of Object.keys(raw) as (keyof ResourceLimits)[]) {
    assertInt(raw[key], `${path}.${key}`, 1, 2 ** 40);
    out[key] = raw[key];
  }
  return out;
}

function validateTemplate(raw: unknown, path: string): SandboxTemplate {
  assertObject(raw, path);
  assertNoUnknownFields(
    raw,
    TEMPLATE_FIELDS,
    path,
  );
  assertInt(raw.version, `${path}.version`, 1, 1 << 30);
  assertString(raw.asset, `${path}.asset`);
  assertObject(raw.network, `${path}.network`);
  const network = raw.network;
  assertNoUnknownFields(network, NETWORK_FIELDS, `${path}.network`);
  let parsedNetwork: SandboxTemplate["network"];
  if (network.mode === "deny-all" || network.mode === "public-anonymous") {
    parsedNetwork = { mode: network.mode };
  } else if (network.mode === "bundles") {
    assertStringArray(network.bundles, `${path}.network.bundles`);
    parsedNetwork = { mode: "bundles", bundles: network.bundles };
  } else {
    failInvalid(`${path}.network.mode must be deny-all|bundles|public-anonymous`);
  }
  assertObject(raw.workspace, `${path}.workspace`);
  const ws = raw.workspace;
  let workspace: SandboxTemplate["workspace"];
  if (ws.type === "private" || ws.type === "none") {
    workspace = { type: ws.type };
  } else if (ws.type === "project") {
    assertString(ws.project, `${path}.workspace.project`);
    workspace = { type: "project", project: ws.project };
  } else if (ws.type === "durable") {
    assertString(ws.durableId, `${path}.workspace.durableId`);
    workspace = { type: "durable", durableId: ws.durableId };
  } else {
    failInvalid(`${path}.workspace.type must be private|project|durable|none`);
  }
  if (raw.readOnlyInputs !== undefined) assertStringArray(raw.readOnlyInputs, `${path}.readOnlyInputs`);
  if (raw.envAllow !== undefined) assertStringArray(raw.envAllow, `${path}.envAllow`);
  if (raw.grantScopes !== undefined) {
    assertStringArray(raw.grantScopes, `${path}.grantScopes`);
    for (const s of raw.grantScopes as string[]) {
      if (!["once", "task", "session"].includes(s)) failInvalid(`${path}.grantScopes: bad scope`, { scope: s });
    }
  }
  if (raw.credentials !== undefined) assertStringArray(raw.credentials, `${path}.credentials`);
  if (raw.grantable !== undefined) assertStringArray(raw.grantable, `${path}.grantable`);
  return {
    version: raw.version,
    asset: raw.asset,
    network: parsedNetwork,
    workspace,
    ...(raw.readOnlyInputs !== undefined ? { readOnlyInputs: raw.readOnlyInputs as string[] } : {}),
    ...(raw.resources !== undefined ? { resources: validateResources(raw.resources, `${path}.resources`) } : {}),
    ...(raw.envAllow !== undefined ? { envAllow: raw.envAllow as string[] } : {}),
    ...(raw.grantScopes !== undefined ? { grantScopes: raw.grantScopes as GrantScope[] } : {}),
    ...(raw.credentials !== undefined ? { credentials: raw.credentials as string[] } : {}),
    ...(raw.grantable !== undefined ? { grantable: raw.grantable as string[] } : {}),
  };
}

function validatePairs(raw: unknown, path: string): AssetTemplatePair[] {
  if (!Array.isArray(raw) || raw.length === 0) failInvalid(`${path} must be a non-empty array`);
  return (raw as unknown[]).map((p, i) => {
    const pp = `${path}[${i}]`;
    assertObject(p, pp);
    assertNoUnknownFields(p, PAIR_FIELDS, pp);
    assertString(p.asset, `${pp}.asset`);
    assertString(p.template, `${pp}.template`);
    return { asset: p.asset, template: p.template };
  });
}

function validateMaximum(raw: unknown, path: string): ProfileMaximum {
  if (raw === undefined) return {};
  assertObject(raw, path);
  assertNoUnknownFields(raw, MAXIMUM_FIELDS, path);
  if (raw.networkBundles !== undefined) assertStringArray(raw.networkBundles, `${path}.networkBundles`);
  if (raw.credentialCapabilities !== undefined) {
    assertStringArray(raw.credentialCapabilities, `${path}.credentialCapabilities`);
  }
  if (raw.grantScopes !== undefined) {
    assertStringArray(raw.grantScopes, `${path}.grantScopes`);
    for (const s of raw.grantScopes as string[]) {
      if (!["once", "task", "session"].includes(s)) failInvalid(`${path}.grantScopes: bad scope`, { scope: s });
    }
  }
  return {
    ...(raw.networkBundles !== undefined ? { networkBundles: raw.networkBundles as string[] } : {}),
    ...(raw.credentialCapabilities !== undefined
      ? { credentialCapabilities: raw.credentialCapabilities as string[] }
      : {}),
    ...(raw.resources !== undefined ? { resources: validateResources(raw.resources, `${path}.resources`) } : {}),
    ...(raw.grantScopes !== undefined ? { grantScopes: raw.grantScopes as GrantScope[] } : {}),
  };
}

function validateProfile(raw: unknown, path: string): ProfilePolicy {
  assertObject(raw, path);
  assertNoUnknownFields(raw, PROFILE_FIELDS, path);
  assertString(raw.defaultTemplate, `${path}.defaultTemplate`);
  const allowedPairs = validatePairs(raw.allowedPairs, `${path}.allowedPairs`);
  const maximum = validateMaximum(raw.maximum, `${path}.maximum`);
  let worklanes: Record<string, WorklanePolicy> | undefined;
  if (raw.worklanes !== undefined) {
    assertObject(raw.worklanes, `${path}.worklanes`);
    worklanes = {};
    for (const [name, wl] of Object.entries(raw.worklanes)) {
      const wp = `${path}.worklanes.${name}`;
      assertObject(wl, wp);
      assertNoUnknownFields(wl, WORKLANE_FIELDS, wp);
      if (wl.defaultTemplate !== undefined) assertString(wl.defaultTemplate, `${wp}.defaultTemplate`);
      worklanes[name] = {
        ...(wl.defaultTemplate !== undefined
          ? { defaultTemplate: wl.defaultTemplate as string }
          : {}),
        ...(wl.allowedPairs !== undefined ? { allowedPairs: validatePairs(wl.allowedPairs, `${wp}.allowedPairs`) } : {}),
        ...(wl.maximum !== undefined ? { maximum: validateMaximum(wl.maximum, `${wp}.maximum`) } : {}),
      };
    }
  }
  return { defaultTemplate: raw.defaultTemplate, allowedPairs, maximum, ...(worklanes ? { worklanes } : {}) };
}

function validateFloor(raw: unknown, path: string): FloorPolicy {
  assertObject(raw, path);
  assertNoUnknownFields(
    raw,
    FLOOR_FIELDS,
    path,
  );
  assertObject(raw.maxResources, `${path}.maxResources`);
  const maxResources = validateResources(raw.maxResources, `${path}.maxResources`);
  for (const key of ["cpus", "memoryMiB", "diskMiB", "pidsMax", "maxOutputBytes", "maxExecsPerVm", "maxCommandMs", "ringBufferBytes"] as const) {
    if (maxResources[key] === undefined) failInvalid(`${path}.maxResources.${key} is required`);
  }
  assertInt(raw.maxVms, `${path}.maxVms`, 1, 1 << 16);
  assertInt(raw.maxVmStartsPerMinute, `${path}.maxVmStartsPerMinute`, 1, 1 << 16);
  assertInt(raw.maxFrameBytes, `${path}.maxFrameBytes`, 1024, 1 << 30);
  assertInt(raw.maxInputBytes, `${path}.maxInputBytes`, 1024, 1 << 30);
  return {
    maxResources: maxResources as FloorPolicy["maxResources"],
    maxVms: raw.maxVms,
    maxVmStartsPerMinute: raw.maxVmStartsPerMinute,
    maxFrameBytes: raw.maxFrameBytes,
    maxInputBytes: raw.maxInputBytes,
  };
}

/** Parse and strictly validate a rendered policy document. Fails closed. */
export function parsePolicy(raw: unknown): PolicyFile {
  assertObject(raw, "policy");
  assertNoUnknownFields(raw, KNOWN_TOP_LEVEL, "policy");
  if (raw.version !== POLICY_VERSION) {
    throw new BrokerError(REASONS.POLICY_VERSION, `unsupported policy version: ${String(raw.version)}`, {
      version: raw.version,
    });
  }
  assertString(raw.policyId, "policy.policyId");
  const floor = validateFloor(raw.floor, "policy.floor");
  assertObject(raw.assets, "policy.assets");
  const assets: PolicyFile["assets"] = {};
  for (const [name, asset] of Object.entries(raw.assets)) {
    const ap = `policy.assets.${name}`;
    assertObject(asset, ap);
    assertNoUnknownFields(asset, ASSET_FIELDS, ap);
    assertString(asset.path, `${ap}.path`);
    if (asset.buildId !== undefined) assertString(asset.buildId, `${ap}.buildId`);
    assets[name] = {
      path: asset.path,
      ...(asset.buildId !== undefined ? { buildId: asset.buildId as string } : {}),
    };
  }
  assertObject(raw.bundles, "policy.bundles");
  const bundles: PolicyFile["bundles"] = {};
  for (const [name, bundle] of Object.entries(raw.bundles)) {
    bundles[name] = validateBundle(bundle, `policy.bundles.${name}`);
  }
  assertObject(raw.credentialCapabilities, "policy.credentialCapabilities");
  const credentialCapabilities: PolicyFile["credentialCapabilities"] = {};
  for (const [name, cap] of Object.entries(raw.credentialCapabilities)) {
    credentialCapabilities[name] = validateCapability(cap, `policy.credentialCapabilities.${name}`);
  }
  assertObject(raw.templates, "policy.templates");
  const templates: PolicyFile["templates"] = {};
  for (const [name, tpl] of Object.entries(raw.templates)) {
    templates[name] = validateTemplate(tpl, `policy.templates.${name}`);
  }
  assertObject(raw.profiles, "policy.profiles");
  const profiles: PolicyFile["profiles"] = {};
  for (const [name, profile] of Object.entries(raw.profiles)) {
    profiles[name] = validateProfile(profile, `policy.profiles.${name}`);
  }
  const policy: PolicyFile = {
    version: POLICY_VERSION,
    policyId: raw.policyId,
    floor,
    assets,
    bundles,
    credentialCapabilities,
    templates,
    profiles,
  };
  validateCrossReferences(policy);
  return policy;
}

function validateCrossReferences(policy: PolicyFile): void {
  for (const [name, cap] of Object.entries(policy.credentialCapabilities)) {
    if (!(cap.networkBundle in policy.bundles)) {
      throw new BrokerError(REASONS.POLICY_UNKNOWN_BUNDLE, `capability '${name}' references unknown bundle`, {
        bundle: cap.networkBundle,
      });
    }
  }
  for (const [name, tpl] of Object.entries(policy.templates)) {
    if (!(tpl.asset in policy.assets)) {
      throw new BrokerError(REASONS.POLICY_UNKNOWN_ASSET, `template '${name}' references unknown asset`, {
        asset: tpl.asset,
      });
    }
    if (tpl.network.mode === "bundles") {
      for (const b of tpl.network.bundles) {
        if (!(b in policy.bundles)) {
          throw new BrokerError(REASONS.POLICY_UNKNOWN_BUNDLE, `template '${name}' references unknown bundle`, {
            bundle: b,
          });
        }
      }
    }
    for (const c of tpl.credentials ?? []) {
      if (!(c in policy.credentialCapabilities)) {
        throw new BrokerError(REASONS.POLICY_INVALID, `template '${name}' references unknown capability`, {
          capability: c,
        });
      }
    }
  }
  for (const [name, profile] of Object.entries(policy.profiles)) {
    // The profile default must be selectable at profile scope; worklane pairs
    // do not satisfy it (they attenuate, they do not widen profile choice).
    if (!profile.allowedPairs.some((p) => p.template === profile.defaultTemplate)) {
      throw new BrokerError(REASONS.POLICY_PAIR_FORBIDDEN, `profile '${name}' defaultTemplate is not an allowed pair`, {
        template: profile.defaultTemplate,
      });
    }
    for (const [wlName, wl] of Object.entries(profile.worklanes ?? {})) {
      const wlPairs = wl.allowedPairs ?? profile.allowedPairs;
      const wlDefault = wl.defaultTemplate ?? profile.defaultTemplate;
      if (!wlPairs.some((p) => p.template === wlDefault)) {
        throw new BrokerError(
          REASONS.POLICY_PAIR_FORBIDDEN,
          `worklane '${wlName}' defaultTemplate is not an allowed pair`,
          { worklane: wlName, template: wlDefault },
        );
      }
    }
    const pairs = [
      ...profile.allowedPairs,
      ...Object.values(profile.worklanes ?? {}).flatMap((wl) => wl.allowedPairs ?? []),
    ];
    for (const pair of pairs) {
      const tpl = policy.templates[pair.template];
      if (!tpl) {
        throw new BrokerError(REASONS.POLICY_UNKNOWN_TEMPLATE, `profile '${name}' references unknown template`, {
          template: pair.template,
        });
      }
      if (!(pair.asset in policy.assets)) {
        throw new BrokerError(REASONS.POLICY_UNKNOWN_ASSET, `pair references unknown asset`, {
          asset: pair.asset,
          template: pair.template,
        });
      }
    }
    for (const b of profile.maximum.networkBundles ?? []) {
      if (!(b in policy.bundles)) {
        throw new BrokerError(REASONS.POLICY_UNKNOWN_BUNDLE, `profile '${name}' references unknown bundle`, {
          bundle: b,
        });
      }
    }
    for (const c of profile.maximum.credentialCapabilities ?? []) {
      if (!(c in policy.credentialCapabilities)) {
        throw new BrokerError(REASONS.POLICY_INVALID, `profile '${name}' references unknown capability`, {
          capability: c,
        });
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Composition — monotonic attenuation (§11.2)
// ---------------------------------------------------------------------------

function intersectSets<T>(a: readonly T[] | undefined, b: readonly T[] | undefined): T[] {
  // undefined means "no constraint at this layer"; intersection otherwise.
  if (a === undefined) return [...(b ?? [])];
  if (b === undefined) return [...a];
  const bset = new Set(b);
  return a.filter((x) => bset.has(x));
}

function minResources(...layers: (ResourceLimits | undefined)[]): ResourceLimits {
  const out: ResourceLimits = {};
  for (const layer of layers) {
    if (!layer) continue;
    for (const [key, value] of Object.entries(layer) as [keyof ResourceLimits, number][]) {
      const prev = out[key];
      if (prev === undefined || value < prev) out[key] = value;
    }
  }
  return out;
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object" && value !== null) {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`);
    return `{${entries.join(",")}}`;
  }
  return JSON.stringify(value);
}

export function sha256Hex(input: string): string {
  return createHash("sha256").update(input, "utf8").digest("hex");
}

export interface ComposeRequest {
  profile: string;
  worklane?: string | null;
  template?: string;
  asset?: string;
}

/**
 * Compose the effective policy for one environment request.
 *
 * Only capabilities declared `grantable` may be activated; runtime grants
 * widen nothing here — they are evaluated separately at enforcement time
 * against the precomputed `grantable`/`grantScopes` surface.
 */
export function composePolicy(policy: PolicyFile, request: ComposeRequest): EffectivePolicy {
  const profile = policy.profiles[request.profile];
  if (!profile) {
    throw new BrokerError(REASONS.POLICY_INVALID, `unknown profile`, { profile: request.profile });
  }
  const worklaneName = request.worklane ?? null;
  let worklane: WorklanePolicy | null = null;
  if (worklaneName !== null) {
    worklane = profile.worklanes?.[worklaneName] ?? null;
    if (!worklane) {
      throw new BrokerError(REASONS.POLICY_INVALID, `unknown worklane`, {
        profile: request.profile,
        worklane: worklaneName,
      });
    }
  }

  const templateName = request.template ?? worklane?.defaultTemplate ?? profile.defaultTemplate;
  const template = policy.templates[templateName];
  if (!template) {
    throw new BrokerError(REASONS.POLICY_UNKNOWN_TEMPLATE, `unknown template`, { template: templateName });
  }
  // The (asset, template) pair selects the asset; template.asset is only
  // the default when the request does not name one (V3 §11.5).
  const assetName = request.asset ?? template.asset;
  const pairs = worklane?.allowedPairs ?? profile.allowedPairs;
  const pairAllowed = pairs.some((p) => p.template === templateName && p.asset === assetName);
  if (!pairAllowed) {
    throw new BrokerError(REASONS.POLICY_PAIR_FORBIDDEN, `asset/template pair not permitted`, {
      profile: request.profile,
      worklane: worklaneName,
      asset: assetName,
      template: templateName,
    });
  }
  const asset = policy.assets[assetName];
  if (!asset || asset.buildId === undefined) {
    throw new BrokerError(REASONS.POLICY_UNKNOWN_ASSET, `unknown or unresolved asset`, {
      asset: assetName,
    });
  }

  // Network: template selection ∩ profile maximum ∩ worklane maximum.
  const maxBundles = intersectSets(
    profile.maximum.networkBundles,
    worklane?.maximum?.networkBundles,
  );
  let network: EffectivePolicy["network"];
  if (template.network.mode === "deny-all") {
    network = { mode: "deny-all" };
  } else if (template.network.mode === "public-anonymous") {
    network = { mode: "public-anonymous" };
  } else {
    const allowed = intersectSets(template.network.bundles, maxBundles);
    const destinations = allowed.flatMap((name) => {
      const bundle = policy.bundles[name];
      if (!bundle) {
        throw new BrokerError(REASONS.POLICY_UNKNOWN_BUNDLE, `unknown bundle`, { bundle: name });
      }
      return bundle.destinations;
    });
    network = { mode: "bundles", destinations };
  }

  const resources = minResources(
    policy.floor.maxResources,
    profile.maximum.resources,
    worklane?.maximum?.resources,
    template.resources,
  ) as Required<ResourceLimits>;
  // The floor is an absolute ceiling, not a participant in attenuation.
  for (const [key, floorValue] of Object.entries(policy.floor.maxResources) as [keyof ResourceLimits, number][]) {
    const value = resources[key];
    if (value === undefined || value > floorValue) resources[key] = floorValue;
  }

  const grantScopes = intersectSets(
    intersectSets(profile.maximum.grantScopes, worklane?.maximum?.grantScopes),
    template.grantScopes,
  ) as GrantScope[];

  const credentials = intersectSets(
    intersectSets(profile.maximum.credentialCapabilities, worklane?.maximum?.credentialCapabilities),
    template.credentials,
  );

  const grantable = (template.grantable ?? []).filter((g) => {
    const inBundles = policy.bundles[g] !== undefined && (maxBundles.length === 0 || maxBundles.includes(g));
    const inCredentials = credentials.includes(g);
    return inBundles || inCredentials;
  });

  const policyHash = sha256Hex(
    canonicalJson({
      policyId: policy.policyId,
      profile: request.profile,
      worklane: worklaneName,
      template: templateName,
      templateVersion: template.version,
      asset: assetName,
      buildId: asset.buildId,
      network,
      resources,
      grantScopes,
      credentials,
      grantable,
    }),
  );

  return {
    profile: request.profile,
    worklane: worklaneName,
    assetName,
    assetPath: asset.path,
    buildId: asset.buildId,
    templateName,
    templateVersion: template.version,
    network,
    workspace: template.workspace,
    readOnlyInputs: template.readOnlyInputs ?? [],
    resources,
    envAllow: template.envAllow ?? [],
    grantScopes,
    credentials,
    grantable,
    floor: policy.floor,
    policyHash,
  };
}

/** Expand a destination rule into Gondolin host patterns (§12.2).
 *  exact → "host"; subdomains → "*.host"; host-and-subdomains → both. */
export function destinationToHostPatterns(rule: DestinationRule): string[] {
  switch (rule.kind) {
    case "exact":
      return [rule.host];
    case "subdomains":
      return [`*.${rule.host}`];
    case "host-and-subdomains":
      return [rule.host, `*.${rule.host}`];
  }
}
