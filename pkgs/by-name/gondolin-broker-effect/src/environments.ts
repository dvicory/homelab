import { createHash } from "node:crypto";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import {
  Context,
  Effect,
  Layer,
  Ref,
  STM,
  TReentrantLock,
  TSemaphore,
  type Scope,
} from "effect";
import { Authorization } from "./auth.js";
import { BrokerConfig } from "./config.js";
import type { EnvironmentRef, EnsureRequest, WorklaneLimits } from "./domain.js";
import { brokerError, type BrokerError } from "./errors.js";
import { Registry } from "./registry.js";
import { VmRuntime, type VmHandle } from "./runtime.js";

export interface LiveEnvironment {
  readonly environmentKey: string;
  readonly generation: number;
  readonly profile: string;
  readonly executor: string;
  readonly authorityClass: string;
  readonly policyGeneration: number;
  readonly decisionDigest: string;
  readonly workspacePath: string;
  readonly workspaceGuestPath: string;
  readonly limits: WorklaneLimits;
  readonly vm: VmHandle;
  readonly lifecycleLock: TReentrantLock.TReentrantLock;
  readonly execPermits: TSemaphore.TSemaphore;
  readonly closing: Ref.Ref<boolean>;
}

export interface EnsureResult {
  readonly environmentKey: string;
  readonly generation: number;
  readonly state: "created" | "reused";
  readonly profile: string;
  readonly executor: string;
  readonly authorityClass: string;
  readonly policyGeneration: number;
  readonly decisionDigest: string;
}

export interface EnvironmentService {
  readonly ensure: (request: EnsureRequest) => Effect.Effect<EnsureResult, BrokerError>;
  readonly status: (environmentKey: string) => Effect.Effect<{
    readonly environmentKey: string;
    readonly generation: number;
    readonly state: string;
    readonly live: boolean;
    readonly profile: string;
    readonly executor: string;
    readonly authorityClass: string;
    readonly policyGeneration: number;
  }, BrokerError>;
  readonly lease: (reference: EnvironmentRef) => Effect.Effect<LiveEnvironment, BrokerError, Scope.Scope>;
  readonly close: (reference: EnvironmentRef) => Effect.Effect<void, BrokerError>;
  readonly hardTerminateLeased: (reference: EnvironmentRef, reason: string) => Effect.Effect<void, never>;
}

export class Environments extends Context.Tag("@agent-x/gondolin-broker-effect/Environments")<
  Environments,
  EnvironmentService
>() {}

const clampLimits = (
  configured: WorklaneLimits,
  authorized: Readonly<Record<string, number>>,
): WorklaneLimits => {
  const limit = (name: keyof WorklaneLimits): number => {
    const policy = authorized[name];
    return policy === undefined ? configured[name] : Math.min(configured[name], policy);
  };
  return {
    maxCommandMs: limit("maxCommandMs"),
    maxOutputBytes: limit("maxOutputBytes"),
    maxInputBytes: limit("maxInputBytes"),
    maxFileBytes: limit("maxFileBytes"),
    maxListEntries: limit("maxListEntries"),
    maxConcurrentExecs: limit("maxConcurrentExecs"),
  };
};

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const authorization = yield* Authorization;
  const registry = yield* Registry;
  const runtime = yield* VmRuntime;
  const live = new Map<string, LiveEnvironment>();
  const mutation = yield* STM.commit(TSemaphore.make(1));

  const closeLive = (
    environment: LiveEnvironment,
    terminalState: "closed" | "failed",
    failureReason = "broker shutdown",
  ) =>
    TReentrantLock.withWriteLock(
      Effect.gen(function* () {
        yield* Ref.set(environment.closing, true);
        yield* registry.markClosing(environment.environmentKey, environment.generation).pipe(Effect.ignore);
        yield* Effect.tryPromise({
          try: () => environment.vm.close(),
          catch: (error) =>
            brokerError("runtime.operation_failed", "failed to close Gondolin VM", {
              environmentKey: environment.environmentKey,
              generation: environment.generation,
              cause: error instanceof Error ? error.message : String(error),
            }),
        }).pipe(
          Effect.tapError((error) =>
            registry.markFailed(environment.environmentKey, environment.generation, error.message).pipe(Effect.ignore),
          ),
        );
        if (terminalState === "closed") {
          yield* registry.markClosed(environment.environmentKey, environment.generation);
        } else {
          yield* registry.markFailed(environment.environmentKey, environment.generation, failureReason);
        }
      }),
      environment.lifecycleLock,
    );

  yield* Effect.addFinalizer(() =>
    Effect.forEach([...live.values()], (environment) => closeLive(environment, "closed").pipe(Effect.ignore), {
      concurrency: "unbounded",
      discard: true,
    }),
  );

  const ensureUnlocked = (request: EnsureRequest): Effect.Effect<EnsureResult, BrokerError> =>
    Effect.gen(function* () {
      const binding = yield* registry.bindAuthority({
        environmentKey: request.environmentKey,
        profile: config.profile,
        executor: config.policyFile.defaultExecutor,
        authorityClass: config.policyFile.defaultAuthorityClass,
        policyGeneration: config.policyFile.policyGeneration,
      });
      const worklaneName = binding.authorityClass;
      const worklane = config.policyFile.worklanes[worklaneName];
      if (worklane === undefined) {
        return yield* brokerError("policy.indeterminate", "bound authority class is unavailable", {
          authorityClass: binding.authorityClass,
        });
      }
      const asset = config.policyFile.assets[worklane.asset];
      if (asset === undefined) {
        return yield* brokerError("request.invalid", "worklane asset is unavailable", {
          worklane: worklaneName,
          asset: worklane.asset,
        });
      }
      const decision = yield* authorization.authorize({
        action: "environment.ensure",
        resource: `worklane:${worklaneName}:environment:${request.environmentKey}`,
        requestedLimits: {
          memoryMiB: worklane.memoryMiB,
          cpus: worklane.cpus,
          ...worklane.limits,
        },
      });
      if (decision.policyGeneration !== binding.policyGeneration) {
        return yield* brokerError("policy.indeterminate", "bound policy generation is unavailable", {
          authorityClass: binding.authorityClass,
          boundPolicyGeneration: binding.policyGeneration,
          activePolicyGeneration: decision.policyGeneration,
        });
      }
      const networkObligations = decision.obligations.filter(
        (obligation) => typeof obligation === "object" && obligation.kind === "network",
      );
      if (networkObligations.length !== 1) {
        return yield* brokerError(
          "policy.indeterminate",
          "environment authorization must produce exactly one network obligation",
          { worklane: worklaneName, count: networkObligations.length },
        );
      }
      const networkPolicyId = networkObligations[0]!.bundleId;
      const network = config.policyFile.networkPolicies[networkPolicyId];
      if (network === undefined) {
        return yield* brokerError(
          "policy.indeterminate",
          "network obligation references an unknown policy",
          { worklane: worklaneName, networkPolicyId },
        );
      }
      const existing = live.get(request.environmentKey);
      if (
        existing !== undefined &&
        existing.authorityClass === binding.authorityClass &&
        existing.policyGeneration === decision.policyGeneration &&
        existing.decisionDigest === decision.decisionDigest
      ) {
        return {
          environmentKey: existing.environmentKey,
          generation: existing.generation,
          state: "reused",
          profile: existing.profile,
          executor: existing.executor,
          authorityClass: existing.authorityClass,
          policyGeneration: existing.policyGeneration,
          decisionDigest: existing.decisionDigest,
        };
      }
      if (existing !== undefined) {
        yield* closeLive(existing, "closed");
        live.delete(request.environmentKey);
      }
      if (live.size >= config.policyFile.maxEnvironments) {
        return yield* brokerError("environment.capacity", "environment capacity reached", {
          maxEnvironments: config.policyFile.maxEnvironments,
        });
      }

      const workspaceId = createHash("sha256").update(request.environmentKey).digest("hex");
      const workspacePath = path.join(config.workspaceRoot, workspaceId);
      yield* Effect.tryPromise({
        try: () => fs.mkdir(workspacePath, { recursive: true, mode: 0o700 }),
        catch: (error) =>
          brokerError("runtime.start_failed", "cannot create environment workspace", {
            cause: error instanceof Error ? error.message : String(error),
          }),
      });
      const record = yield* registry.reserve({
        environmentKey: request.environmentKey,
        policyGeneration: decision.policyGeneration,
        worklane: worklaneName,
        assetBuildId: asset.buildId,
        workspacePath,
      });
      const vm = yield* runtime.create({
        assetPath: asset.path,
        memoryMiB: Math.min(worklane.memoryMiB, decision.limits.memoryMiB ?? worklane.memoryMiB),
        cpus: Math.min(worklane.cpus, decision.limits.cpus ?? worklane.cpus),
        workspaceHostPath: workspacePath,
        workspaceGuestPath: worklane.workspaceGuestPath,
        sessionLabel: `${config.profile}:${request.environmentKey}:${record.generation}`,
        network,
      }).pipe(
        Effect.tapError((error) =>
          registry.markFailed(request.environmentKey, record.generation, error.message).pipe(Effect.ignore),
        ),
      );
      const lifecycleLock = yield* STM.commit(TReentrantLock.make);
      const limits = clampLimits(worklane.limits, decision.limits);
      const execPermits = yield* STM.commit(TSemaphore.make(limits.maxConcurrentExecs));
      const closing = yield* Ref.make(false);
      const environment: LiveEnvironment = {
        environmentKey: request.environmentKey,
        generation: record.generation,
        profile: binding.profile,
        executor: binding.executor,
        authorityClass: binding.authorityClass,
        policyGeneration: decision.policyGeneration,
        decisionDigest: decision.decisionDigest,
        workspacePath,
        workspaceGuestPath: worklane.workspaceGuestPath,
        limits,
        vm,
        lifecycleLock,
        execPermits,
        closing,
      };
      yield* registry.markActive(request.environmentKey, record.generation, vm.id, vm.hostPid()).pipe(
        Effect.tapError(() => Effect.tryPromise(() => vm.close()).pipe(Effect.ignore)),
      );
      live.set(request.environmentKey, environment);
      return {
        environmentKey: request.environmentKey,
        generation: record.generation,
        state: "created",
        profile: binding.profile,
        executor: binding.executor,
        authorityClass: binding.authorityClass,
        policyGeneration: decision.policyGeneration,
        decisionDigest: decision.decisionDigest,
      };
    });

  const ensure = (request: EnsureRequest) =>
    TSemaphore.withPermit(ensureUnlocked(request), mutation);

  const status = (environmentKey: string) =>
    Effect.gen(function* () {
      yield* authorization.authorize({
        action: "environment.status",
        resource: `environment:${environmentKey}`,
      });
      const record = yield* registry.get(environmentKey);
      if (record === undefined) {
        return yield* brokerError("environment.not_found", "environment does not exist", { environmentKey });
      }
      const binding = yield* registry.getAuthority(environmentKey);
      if (binding === undefined) {
        return yield* brokerError("policy.indeterminate", "environment authority binding is missing", {
          environmentKey,
        });
      }
      return {
        environmentKey,
        generation: record.generation,
        state: record.state,
        live: live.has(environmentKey),
        profile: binding.profile,
        executor: binding.executor,
        authorityClass: binding.authorityClass,
        policyGeneration: record.policyGeneration,
      };
    });

  const lease = (reference: EnvironmentRef): Effect.Effect<LiveEnvironment, BrokerError, Scope.Scope> =>
    Effect.gen(function* () {
      const environment = live.get(reference.environmentKey);
      if (environment === undefined) {
        const persisted = yield* registry.get(reference.environmentKey);
        if (persisted !== undefined && persisted.generation !== reference.generation) {
          return yield* brokerError("environment.stale_generation", "environment generation is stale", {
            expected: persisted.generation,
            received: reference.generation,
          });
        }
        return yield* brokerError("environment.not_found", "environment is not live", {
          environmentKey: reference.environmentKey,
        });
      }
      if (environment.generation !== reference.generation) {
        return yield* brokerError("environment.stale_generation", "environment generation is stale", {
          expected: environment.generation,
          received: reference.generation,
        });
      }
      yield* TReentrantLock.readLock(environment.lifecycleLock);
      if (yield* Ref.get(environment.closing)) {
        return yield* brokerError("environment.tombstoned", "environment is closing", {
          environmentKey: reference.environmentKey,
          generation: reference.generation,
        });
      }
      return environment;
    });

  const close = (reference: EnvironmentRef) =>
    TSemaphore.withPermit(
      Effect.gen(function* () {
        yield* authorization.authorize({
          action: "environment.close",
          resource: `environment:${reference.environmentKey}`,
        });
        const environment = live.get(reference.environmentKey);
        if (environment === undefined) {
          return yield* brokerError("environment.not_found", "environment is not live", {
            environmentKey: reference.environmentKey,
          });
        }
        if (environment.generation !== reference.generation) {
          return yield* brokerError("environment.stale_generation", "environment generation is stale", {
            expected: environment.generation,
            received: reference.generation,
          });
        }
        yield* closeLive(environment, "closed");
        live.delete(reference.environmentKey);
      }),
      mutation,
    );

  const hardTerminateLeased = (reference: EnvironmentRef, reason: string): Effect.Effect<void, never> =>
    TSemaphore.withPermit(
      Effect.gen(function* () {
        const environment = live.get(reference.environmentKey);
        if (environment === undefined || environment.generation !== reference.generation) return;
        yield* Ref.set(environment.closing, true);
        yield* registry.markClosing(environment.environmentKey, environment.generation).pipe(Effect.ignore);
        yield* Effect.tryPromise({ try: () => environment.vm.close(), catch: () => undefined }).pipe(Effect.ignore);
        yield* registry.markFailed(environment.environmentKey, environment.generation, reason).pipe(Effect.ignore);
        live.delete(reference.environmentKey);
      }),
      mutation,
    );

  return { ensure, status, lease, close, hardTerminateLeased } satisfies EnvironmentService;
});

export const EnvironmentsLive = Layer.scoped(Environments, make);
