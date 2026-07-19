/**
 * Broker runtime configuration (V3 §13, §15.1, §18).
 *
 * All deployment facts arrive via the environment or files placed by the
 * NixOS module: the immutable policy JSON, state/cache/runtime directories,
 * and the systemd-activated socket. Nothing guest- or gateway-supplied can
 * select images, host paths, QEMU flags, network modes, secrets, or
 * resource ceilings.
 */
import fs from "node:fs";
import { BrokerError, REASONS } from "./errors.js";
import { parsePolicy } from "./policy.js";
import type { PolicyFile } from "./policy.js";

export interface BrokerConfig {
  policy: PolicyFile;
  /** profile this broker instance serves (one broker per profile) */
  profile: string;
  stateDir: string;
  cacheDir: string;
  runtimeDir: string;
  /** path to registry.sqlite under stateDir */
  registryPath: string;
}

const ENV = {
  POLICY: "HERMES_BROKER_POLICY",
  PROFILE: "HERMES_BROKER_PROFILE",
  STATE_DIR: "HERMES_BROKER_STATE_DIR",
  CACHE_DIR: "HERMES_BROKER_CACHE_DIR",
  RUNTIME_DIR: "HERMES_BROKER_RUNTIME_DIR",
} as const;

function requireEnv(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (!value) {
    throw new BrokerError(REASONS.POLICY_MISSING, `missing required environment variable ${name}`);
  }
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BrokerConfig {
  const policyPath = env[ENV.POLICY];
  if (!policyPath) {
    throw new BrokerError(REASONS.POLICY_MISSING, `missing ${ENV.POLICY} (immutable policy.json path)`);
  }
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(policyPath, "utf8"));
  } catch (err) {
    throw new BrokerError(REASONS.POLICY_MISSING, `cannot read policy at ${policyPath}`, {
      error: err instanceof Error ? err.message : String(err),
    });
  }
  const policy = parsePolicy(raw);

  const profile = env[ENV.PROFILE] ?? Object.keys(policy.profiles)[0];
  if (!profile || !(profile in policy.profiles)) {
    throw new BrokerError(REASONS.POLICY_INVALID, `profile not present in policy`, { profile });
  }

  const stateDir = requireEnv(env, ENV.STATE_DIR);
  const cacheDir = env[ENV.CACHE_DIR] ?? `${stateDir}/../cache`;
  const runtimeDir = env[ENV.RUNTIME_DIR] ?? `/run/${profile}-sandbox`;

  return {
    policy,
    profile,
    stateDir,
    cacheDir,
    runtimeDir,
    registryPath: `${stateDir}/registry.sqlite`,
  };
}
