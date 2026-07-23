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
import { TaskRunActivations } from "./task-run-activations.js";
import { Authorization } from "./auth.js";
import { resolveAuthorityPolicy } from "./authority.js";
import { BrokerConfig } from "./config.js";
import type { EnvironmentRef, EnsureRequest, WorklaneLimits } from "./domain.js";
import { brokerError, type BrokerError } from "./errors.js";
import { AccessGrants } from "./grants.js";
import { Registry } from "./registry.js";
import { Workspaces } from "./workspaces.js";
import { VmRuntime, type VmHandle } from "./runtime.js";

export interface LiveEnvironment {
  readonly environmentKey: string;
  readonly generation: number;
  readonly profile: string;
  readonly executor: string;
  readonly authorityClass: string;
  readonly policyDigest: string;
  readonly decisionDigest: string;
  readonly workspaceId: string;
  readonly workspaceLeaseId: string;
  readonly runActivationId: string | null;
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
  readonly policyDigest: string;
  readonly workspaceId: string;
  readonly workspaceLeaseId: string;
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
    readonly policyDigest: string;
    readonly workspaceId: string;
    readonly workspaceLeaseId: string;
  }, BrokerError>;
  readonly lease: (reference: EnvironmentRef) => Effect.Effect<LiveEnvironment, BrokerError, Scope.Scope>;
  readonly close: (reference: EnvironmentRef) => Effect.Effect<void, BrokerError>;
  readonly hardTerminateLeased: (reference: EnvironmentRef, reason: string) => Effect.Effect<void, never>;
  readonly closeForFence: (reference: EnvironmentRef) => Effect.Effect<void, BrokerError>;
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
  const grants = yield* AccessGrants;
  const workspaces = yield* Workspaces;
  const runActivations = yield* TaskRunActivations;
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
      const activation = yield* runActivations.validate(request.environmentKey, request.taskRun);
      const existingBinding = yield* registry.getAuthority(request.environmentKey);
      const binding = existingBinding ?? (yield* Effect.gen(function* () {
        const acquired = yield* workspaces.acquire(request.environmentKey);
        return yield* registry.bindAuthority({
          environmentKey: request.environmentKey,
          profile: config.profile,
          executor: config.policyFile.defaultExecutor,
          authorityClass: config.policyFile.defaultAuthorityClass,
          policyDigest: config.policyFile.policyDigest,
          workspaceId: acquired.workspace.workspaceId,
          workspaceLeaseId: acquired.lease.leaseId,
        });
      }));
      const workspace = yield* workspaces.resolve(
        request.environmentKey,
        binding.workspaceId,
        binding.workspaceLeaseId,
      );
      const { worklaneName, worklane, asset, decision, network } =
        yield* resolveAuthorityPolicy(config, authorization, binding);
      const existing = live.get(request.environmentKey);
      if (
        existing !== undefined &&
        existing.authorityClass === binding.authorityClass &&
        existing.policyDigest === decision.policyDigest &&
        existing.decisionDigest === decision.decisionDigest &&
        existing.workspaceId === binding.workspaceId &&
        existing.workspaceLeaseId === binding.workspaceLeaseId &&
        existing.runActivationId === (activation?.activationId ?? null)
      ) {
        return {
          environmentKey: existing.environmentKey,
          generation: existing.generation,
          state: "reused",
          profile: existing.profile,
          executor: existing.executor,
          authorityClass: existing.authorityClass,
          policyDigest: existing.policyDigest,
          decisionDigest: existing.decisionDigest,
          workspaceId: existing.workspaceId,
          workspaceLeaseId: existing.workspaceLeaseId,
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

      const record = yield* registry.reserve({
        environmentKey: request.environmentKey,
        policyDigest: decision.policyDigest,
        worklane: worklaneName,
        assetBuildId: asset.buildId,
        workspaceId: binding.workspaceId,
        runActivationId: activation?.activationId ?? null,
        workspaceLeaseId: binding.workspaceLeaseId,
      });
      const vm = yield* runtime.create({
        assetPath: asset.path,
        memoryMiB: Math.min(worklane.memoryMiB, decision.limits.memoryMiB ?? worklane.memoryMiB),
        cpus: Math.min(worklane.cpus, decision.limits.cpus ?? worklane.cpus),
        workspaceHostPath: workspace.workspacePath,
        workspaceGuestPath: worklane.workspaceGuestPath,
        sessionLabel: `${config.profile}:${request.environmentKey}:${record.generation}`,
        network,
        dynamicNetwork: {
          activeGrants: () =>
            grants.matching(binding, request.environmentKey),
          consumeOnce: (grantId) => Effect.runPromise(grants.consumeOnce(grantId)),
        },
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
        policyDigest: decision.policyDigest,
        decisionDigest: decision.decisionDigest,
        workspaceGuestPath: worklane.workspaceGuestPath,
        limits,
        workspaceId: binding.workspaceId,
        workspaceLeaseId: binding.workspaceLeaseId,
        runActivationId: activation?.activationId ?? null,
        vm,
        workspacePath: workspace.workspacePath,
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
        policyDigest: decision.policyDigest,
        decisionDigest: decision.decisionDigest,
        workspaceId: environment.workspaceId,
        workspaceLeaseId: environment.workspaceLeaseId,
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
        policyDigest: record.policyDigest,
        workspaceId: record.workspaceId,
        workspaceLeaseId: record.workspaceLeaseId,
      };
    });

  const lease = (reference: EnvironmentRef): Effect.Effect<LiveEnvironment, BrokerError, Scope.Scope> =>
    Effect.gen(function* () {
      const activation = yield* runActivations.validate(reference.environmentKey, reference.taskRun);
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
      if (environment.runActivationId !== (activation?.activationId ?? null)) {
        return yield* brokerError("run_activation.stale", "environment generation belongs to a different task run", {
          environmentKey: reference.environmentKey,
          generation: reference.generation,
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

  const closeForFence = (reference: EnvironmentRef): Effect.Effect<void, BrokerError> =>
    TSemaphore.withPermit(
      Effect.gen(function* () {
        const environment = live.get(reference.environmentKey);
        if (environment === undefined || environment.generation !== reference.generation) {
          const persisted = yield* registry.get(reference.environmentKey);
          if (
            persisted !== undefined &&
            persisted.generation === reference.generation &&
            persisted.state !== "closed" &&
            persisted.state !== "failed"
          ) {
            yield* registry.markClosed(reference.environmentKey, reference.generation);
          }
          return;
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

  return { ensure, status, lease, close, closeForFence, hardTerminateLeased } satisfies EnvironmentService;
});

export const EnvironmentsLive = Layer.scoped(Environments, make);
