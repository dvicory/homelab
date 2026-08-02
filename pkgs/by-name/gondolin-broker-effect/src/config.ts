import { Config, Context, Effect, Layer, Schema } from "effect";
import { createHash } from "node:crypto";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { Asset, decodeExact, GrantScope, LaneAuthority, NetworkPolicy, ProjectWorkspacePolicy, Worklane } from "./domain.js";
import { brokerError, type BrokerError } from "./errors.js";
import { validateNetworkPolicy } from "./network.js";
const canonicalize = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, entry]) => [key, canonicalize(entry)]),
    );
  }
  return value;
};


const GrantPolicy = Schema.Struct({
  allowedScopes: Schema.Array(GrantScope).pipe(Schema.minItems(1)),
  maxDurationSeconds: Schema.Int.pipe(Schema.greaterThan(0)),
  denialCooldownSeconds: Schema.Int.pipe(Schema.greaterThanOrEqualTo(0)),
  promptBudget: Schema.Struct({
    maxNewRequests: Schema.Int.pipe(Schema.greaterThan(0)),
    windowSeconds: Schema.Int.pipe(Schema.greaterThan(0)),
  }),
});

const ProcessRegistryPolicy = Schema.Struct({
  maxConcurrent: Schema.Int.pipe(Schema.greaterThan(0)),
  retainedOutputBytes: Schema.Int.pipe(Schema.greaterThan(0)),
  maxPollBytes: Schema.Int.pipe(
    Schema.greaterThanOrEqualTo(1024),
    Schema.lessThanOrEqualTo(1024 * 1024),
  ),
  terminalTtlMs: Schema.Int.pipe(Schema.greaterThan(0)),
});

const BrokerPolicyFileSchema = Schema.Struct({
  version: Schema.Literal(1),
  policyDigest: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/)),
  policy: Schema.Unknown,
  defaultExecutor: Schema.String.pipe(Schema.minLength(1)),
  defaultAuthorityClass: Schema.String.pipe(Schema.minLength(1)),
  maxEnvironments: Schema.Int.pipe(Schema.greaterThan(0)),
  environmentIdleTimeoutMs: Schema.Int.pipe(Schema.greaterThan(0)),
  processRegistry: ProcessRegistryPolicy,
  assets: Schema.Record({ key: Schema.String, value: Asset }),
  networkPolicies: Schema.Record({ key: Schema.String, value: NetworkPolicy }),
  worklanes: Schema.Record({ key: Schema.String, value: Worklane }),
  laneAuthorities: Schema.Record({ key: Schema.String, value: LaneAuthority }),
  grantPolicy: GrantPolicy,
  projectWorkspace: Schema.optional(ProjectWorkspacePolicy),
});

type BrokerPolicyFileInput = typeof BrokerPolicyFileSchema.Type;

export type BrokerPolicyFile = Omit<BrokerPolicyFileInput, "assets"> & {
  readonly assets: Readonly<Record<string, {
    readonly path: string;
    readonly buildId: string;
  }>>;
};

const resolveAssets = (policyFile: BrokerPolicyFileInput) =>
  Effect.forEach(
    Object.entries(policyFile.assets),
    ([name, asset]) =>
      Effect.tryPromise({
        try: async () => {
          const manifestPath = path.join(asset.path, "manifest.json");
          const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8")) as unknown;
          if (
            typeof manifest !== "object" ||
            manifest === null ||
            !("buildId" in manifest) ||
            typeof manifest.buildId !== "string" ||
            manifest.buildId.length === 0
          ) {
            throw new Error(`${manifestPath} has no buildId`);
          }
          if (asset.buildId !== undefined && asset.buildId !== manifest.buildId) {
            throw new Error(`configured buildId for asset '${name}' does not match its manifest`);
          }
          return [name, { path: asset.path, buildId: manifest.buildId }] as const;
        },
        catch: (error) =>
          brokerError("request.invalid", "cannot resolve immutable guest asset", {
            asset: name,
            cause: error instanceof Error ? error.message : String(error),
          }),
      }),
    { concurrency: "unbounded" },
  ).pipe(Effect.map((entries) => Object.fromEntries(entries)));

export interface BrokerConfigService {
  readonly policyPath: string;
  readonly stateDir: string;
  readonly workspaceRoot: string;
  readonly workspaceHandoffRoot: string;
  readonly workspaceHandoffExportTtlMs: number;
  readonly workspaceHandoffEnabled: boolean;
  readonly databasePath: string;
  readonly socketPath: string;
  readonly controlSocketPath: string;
  readonly profile: string;
  readonly policyFile: BrokerPolicyFile;
}

export class BrokerConfig extends Context.Tag("@agent-x/gondolin-broker-effect/BrokerConfig")<
  BrokerConfig,
  BrokerConfigService
>() {}

const environmentConfig = Config.all({
  policyPath: Config.string("GONDOLIN_EFFECT_POLICY"),
  stateDir: Config.string("GONDOLIN_EFFECT_STATE_DIR"),
  workspaceHandoffEnabled: Config.boolean("GONDOLIN_EFFECT_WORKSPACE_HANDOFF").pipe(Config.withDefault(false)),
  socketPath: Config.string("GONDOLIN_EFFECT_SOCKET").pipe(Config.option),
  controlSocketPath: Config.string("GONDOLIN_EFFECT_CONTROL_SOCKET").pipe(Config.option),
  profile: Config.string("GONDOLIN_EFFECT_PROFILE").pipe(Config.withDefault("default")),
});

const load = Effect.gen(function* () {
  const raw = yield* environmentConfig;
  const text = yield* Effect.tryPromise({
    try: () => fs.readFile(raw.policyPath, "utf8"),
    catch: (error) =>
      brokerError("request.invalid", "cannot read broker policy file", {
        path: raw.policyPath,
        cause: error instanceof Error ? error.message : String(error),
      }),
  });
  const json = yield* Effect.try({
    try: () => JSON.parse(text) as unknown,
    catch: (error) =>
      brokerError("request.invalid", "broker policy is not valid JSON", {
        path: raw.policyPath,
        cause: error instanceof Error ? error.message : String(error),
      }),
  });
  const decoded = yield* decodeExact(BrokerPolicyFileSchema, json).pipe(
    Effect.mapError((error) =>
      brokerError("request.invalid", "broker policy does not match its schema", {
        path: raw.policyPath,
        cause: String(error),
      }),
    ),
  );
  const { policyDigest, ...policyMaterial } = decoded;
  const computedPolicyDigest = createHash("sha256")
    .update(JSON.stringify(canonicalize(policyMaterial)))
    .digest("hex");
  if (policyDigest !== computedPolicyDigest) {
    return yield* brokerError("request.invalid", "broker policy digest does not match its immutable content", {
      configuredPolicyDigest: policyDigest,
      computedPolicyDigest,
    });
  }
  yield* Effect.try({
    try: () => {
      for (const [name, networkPolicy] of Object.entries(decoded.networkPolicies)) {
        try {
          validateNetworkPolicy(networkPolicy);
        } catch (error) {
          throw new Error(`${name}: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
    },
    catch: (error) =>
      brokerError("request.invalid", "broker network policy is invalid", {
        cause: error instanceof Error ? error.message : String(error),
      }),
  });
  const assets = yield* resolveAssets(decoded);
  const policyFile: BrokerPolicyFile = { ...decoded, assets };

  if (!(policyFile.defaultAuthorityClass in policyFile.worklanes)) {
    return yield* brokerError("request.invalid", "default authority class is not defined", {
      authorityClass: policyFile.defaultAuthorityClass,
    });
  }
  for (const [name, worklane] of Object.entries(policyFile.worklanes)) {
    if (!(worklane.asset in policyFile.assets)) {
      return yield* brokerError("request.invalid", "worklane references an unknown asset", {
        worklane: name,
        asset: worklane.asset,
      });
    }
  }
  if (policyFile.projectWorkspace !== undefined) {
    for (const [repositoryId, source] of Object.entries(policyFile.projectWorkspace.sources)) {
      const authority = source.upstream.slice("https://".length).split("/")[0] ?? "";
      if (
        !source.upstream.startsWith("https://") ||
        source.upstream.startsWith("/nix/store") ||
        authority.includes("@")
      ) {
        return yield* brokerError("request.invalid", "Project source upstream must be a credential-free https URL", {
          repositoryId,
        });
      }
      if (
        policyFile.projectWorkspace.sourceRevisions[repositoryId] === undefined
      ) {
        return yield* brokerError("request.invalid", "Project source is missing its immutable source revision digest", {
          repositoryId,
        });
      }
    }
    if (policyFile.projectWorkspace.providerRevisions[policyFile.projectWorkspace.provider] === undefined) {
      return yield* brokerError("request.invalid", "broker-project provider is missing its revision digest");
    }
    for (const [lane, authority] of Object.entries(policyFile.laneAuthorities)) {
      if (
        authority.workspaceProvider === "broker-project" &&
        Object.keys(policyFile.projectWorkspace.sources).length === 0
      ) {
        return yield* brokerError("request.invalid", "broker-project lane has no configured Project sources", {
          lane,
        });
      }
    }
  } else {
    for (const [lane, authority] of Object.entries(policyFile.laneAuthorities)) {
      if (authority.workspaceProvider === "broker-project") {
        return yield* brokerError("request.invalid", "broker-project lane requires the projectWorkspace policy", {
          lane,
        });
      }
    }
  }

  const stateDir = path.resolve(raw.stateDir);
  return {
    policyPath: path.resolve(raw.policyPath),
    stateDir,
    workspaceRoot: path.join(stateDir, "workspaces"),
    workspaceHandoffRoot: path.join(stateDir, "workspace-handoffs"),
    workspaceHandoffExportTtlMs: 5 * 60 * 1000,
    workspaceHandoffEnabled: raw.workspaceHandoffEnabled,
    databasePath: path.join(stateDir, "broker.sqlite"),
    socketPath: raw.socketPath._tag === "Some" ? path.resolve(raw.socketPath.value) : path.join(stateDir, "broker.sock"),
    controlSocketPath: raw.controlSocketPath._tag === "Some"
      ? path.resolve(raw.controlSocketPath.value)
      : path.join(stateDir, "control.sock"),
    profile: raw.profile,
    policyFile,
  } satisfies BrokerConfigService;
}).pipe(Effect.mapError((error): BrokerError => error instanceof Error && "reason" in error ? error as BrokerError : brokerError("request.invalid", "invalid broker configuration", { cause: String(error) })));

export const BrokerConfigLive = Layer.effect(BrokerConfig, load);
