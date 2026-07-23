import { Context, Effect, Layer } from "effect";
import { Authorization } from "./auth.js";
import { BrokerConfig } from "./config.js";
import type {
  ImportWorkspaceRevisionRequest,
  PublishWorkspaceRevisionRequest,
} from "./revision-domain.js";
import { BrokerError, brokerError } from "./errors.js";
import { Environments } from "./environments.js";
import { Registry } from "./registry.js";
import { RevisionStorage, type RevisionLimits } from "./revision-storage.js";
import { RevisionStore, type ImportRecord, type RevisionRecord } from "./revision-store.js";
import { TaskRunActivations } from "./task-run-activations.js";
import { Workspaces, type WorkspaceBinding, type WorkspaceRecord } from "./workspaces.js";

export interface PublishedRevision {
  readonly revisionId: string;
  readonly manifestDigest: string;
  readonly entryCount: number;
  readonly logicalBytes: number;
  readonly sourceTaskId: string;
  readonly sourceRunId: string;
}

export interface ImportedWorkspace {
  readonly preparationId: string;
  readonly sourceRevisionId: string;
  readonly workspace: {
    readonly workspaceId: string;
    readonly ownerEnvironmentKey: string;
    readonly kind: "private";
    readonly state: "active";
    readonly guestPath: "/workspace";
  };
  readonly lease: WorkspaceBinding["lease"];
}

export interface RevisionOperationsService {
  readonly publish: (
    request: PublishWorkspaceRevisionRequest,
  ) => Effect.Effect<PublishedRevision, BrokerError>;
  readonly importRevision: (
    request: ImportWorkspaceRevisionRequest,
  ) => Effect.Effect<ImportedWorkspace, BrokerError>;
}

export class RevisionOperations extends Context.Tag("@agent-x/gondolin-broker-effect/RevisionOperations")<
  RevisionOperations,
  RevisionOperationsService
>() {}

const requiredLimit = (limits: Readonly<Record<string, number>>, name: string): number => {
  const value = limits[name];
  if (!Number.isSafeInteger(value) || value === undefined || value <= 0) {
    throw brokerError("policy.indeterminate", `workspace publication policy requires ${name}`);
  }
  return value;
};

const revisionLimits = (limits: Readonly<Record<string, number>>): RevisionLimits => ({
  maxLogicalBytes: requiredLimit(limits, "maxLogicalBytes"),
  maxEntries: requiredLimit(limits, "maxEntries"),
  maxFileBytes: requiredLimit(limits, "maxFileBytes"),
  maxPathBytes: requiredLimit(limits, "maxPathBytes"),
});

const publishedRevision = (revision: RevisionRecord): PublishedRevision => {
  if (revision.state !== "ready" || revision.manifestDigest === null) {
    throw brokerError("revision.invalid_state", "published revision is not ready");
  }
  return {
    revisionId: revision.revisionId,
    manifestDigest: revision.manifestDigest,
    entryCount: revision.entryCount,
    logicalBytes: revision.logicalBytes,
    sourceTaskId: revision.sourceTaskId,
    sourceRunId: revision.sourceRunId,
  };
};

const visibleWorkspace = (workspace: WorkspaceRecord): ImportedWorkspace["workspace"] => {
  if (workspace.state !== "active") {
    throw brokerError("workspace.conflict", "imported workspace is not active");
  }
  return {
    workspaceId: workspace.workspaceId,
    ownerEnvironmentKey: workspace.ownerEnvironmentKey,
    kind: workspace.kind,
    state: workspace.state,
    guestPath: "/workspace",
  };
};

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const authorization = yield* Authorization;
  const environments = yield* Environments;
  const registry = yield* Registry;
  const storage = yield* RevisionStorage;
  const store = yield* RevisionStore;
  const activations = yield* TaskRunActivations;
  const workspaces = yield* Workspaces;

  const publish = (
    request: PublishWorkspaceRevisionRequest,
  ): Effect.Effect<PublishedRevision, BrokerError> =>
    Effect.gen(function* () {
      const authority = yield* authorization.authorize({
        action: "workspace.publish",
        resource: `task-run:${request.taskId}`,
      });
      const limits = yield* Effect.try({
        try: () => revisionLimits(authority.limits),
        catch: (error) => error instanceof BrokerError
          ? error
          : brokerError("policy.indeterminate", "workspace publication limits are invalid"),
      });
      const consumed = yield* activations.consumeAtomically({
        environmentKey: request.environmentKey,
        taskId: request.taskId,
        runId: request.runId,
      }, (activation) => {
        if (activation.policyDigest !== authority.policyDigest) {
          throw brokerError("run_activation.stale", "publication activation policy is no longer active");
        }
        return store.stagePublication({
          finalizationId: request.finalizationId,
          policyDecisionDigest: authority.decisionDigest,
          sourceActivationId: activation.activationId,
          selectedRoots: request.selectedRoots,
        });
      });
      if (consumed.generationToClose !== null) {
        yield* environments.closeForFence(consumed.generationToClose);
      }
      const source = yield* workspaces.resolve(
        consumed.activation.environmentKey,
        consumed.activation.workspaceId,
        consumed.activation.workspaceLeaseId,
      );
      const ready = yield* storage.stageRevision(
        consumed.result.revisionId,
        source.workspacePath,
        limits,
      );
      return publishedRevision(ready);
    });

  const cleanFailedDestination = (
    binding: WorkspaceBinding,
    preparationId: string,
    reason: string,
  ): Effect.Effect<void, never> =>
    Effect.gen(function* () {
      yield* workspaces.release(
        binding.workspace.ownerEnvironmentKey,
        binding.workspace.workspaceId,
        binding.lease.leaseId,
      ).pipe(Effect.ignore);
      yield* workspaces.close(
        binding.workspace.ownerEnvironmentKey,
        binding.workspace.workspaceId,
      ).pipe(Effect.ignore);
      yield* workspaces.delete(
        binding.workspace.ownerEnvironmentKey,
        binding.workspace.workspaceId,
      ).pipe(Effect.ignore);
      yield* Effect.sync(() => store.failImport(preparationId, reason)).pipe(Effect.ignore);
    });

  const importRevision = (
    request: ImportWorkspaceRevisionRequest,
  ): Effect.Effect<ImportedWorkspace, BrokerError> =>
    Effect.gen(function* () {
      const source = yield* Effect.try({
        try: () => store.getRevision(request.sourceRevisionId),
        catch: (error) => error instanceof BrokerError
          ? error
          : brokerError("revision.failed", "failed to resolve source revision"),
      });
      if (source.state !== "ready" || source.manifestDigest === null) {
        return yield* brokerError("revision.invalid_state", "only a ready revision can be imported");
      }
      if (source.sourceTaskId !== request.sourceTaskId) {
        return yield* brokerError("revision.conflict", "source task does not own the revision");
      }
      if (source.policyDigest !== config.policyFile.policyDigest) {
        return yield* brokerError("revision.conflict", "source revision policy is no longer active");
      }
      const authority = yield* authorization.authorize({
        action: "workspace.import",
        resource: `task-run:${request.destinationTaskId}`,
      });
      yield* storage.verifyRevision(source.revisionId);
      const staged = yield* Effect.try({
        try: () => store.stageImport({
          preparationId: request.preparationId,
          policyDecisionDigest: authority.decisionDigest,
          sourceRevisionId: source.revisionId,
          destinationTaskId: request.destinationTaskId,
          destinationRunId: request.destinationRunId,
          destinationEnvironmentKey: request.destinationEnvironmentKey,
          sourcePolicyDigest: source.policyDigest,
          destinationPolicyDigest: authority.policyDigest,
          relationDigest: request.relationDigest,
        }),
        catch: (error) => error instanceof BrokerError
          ? error
          : brokerError("revision.failed", "failed to stage workspace import"),
      });
      if (staged.state === "ready") {
        if (staged.destinationWorkspaceId === null || staged.destinationWorkspaceLeaseId === null) {
          return yield* brokerError("revision.failed", "ready import has no destination workspace");
        }
        const resolved = yield* workspaces.resolve(
          request.destinationEnvironmentKey,
          staged.destinationWorkspaceId,
          staged.destinationWorkspaceLeaseId,
        );
        yield* registry.bindAuthority({
          environmentKey: request.destinationEnvironmentKey,
          profile: config.profile,
          executor: config.policyFile.defaultExecutor,
          authorityClass: config.policyFile.defaultAuthorityClass,
          policyDigest: authority.policyDigest,
          workspaceId: resolved.workspace.workspaceId,
          workspaceLeaseId: resolved.lease.leaseId,
        });
        return {
          preparationId: staged.preparationId,
          sourceRevisionId: staged.sourceRevisionId,
          workspace: visibleWorkspace(resolved.workspace),
          lease: resolved.lease,
        };
      }
      const requestedWorkspaceId = staged.destinationWorkspaceId ?? undefined;
      const acquired = yield* workspaces.acquireAtomically(
        request.destinationEnvironmentKey,
        requestedWorkspaceId,
        ({ workspace, lease }) => store.reserveImportDestination({
          preparationId: request.preparationId,
          destinationWorkspaceId: workspace.workspaceId,
          destinationWorkspaceLeaseId: lease.leaseId,
        }),
      );
      const binding: WorkspaceBinding = { workspace: acquired.workspace, lease: acquired.lease };
      const resolved = yield* workspaces.resolve(
        request.destinationEnvironmentKey,
        acquired.workspace.workspaceId,
        acquired.lease.leaseId,
      );
      const imported = yield* storage.materializeRevision(source.revisionId, resolved.workspacePath).pipe(
        Effect.tapError((error) => cleanFailedDestination(binding, request.preparationId, error.message)),
      );
      if (imported.manifestDigest !== source.manifestDigest) {
        yield* cleanFailedDestination(binding, request.preparationId, "materialized revision digest mismatch");
        return yield* brokerError("revision.failed", "materialized revision digest mismatch");
      }
      const completed = yield* Effect.try({
        try: () => store.completeImport({
          preparationId: request.preparationId,
          destinationWorkspaceId: acquired.workspace.workspaceId,
          destinationWorkspaceLeaseId: acquired.lease.leaseId,
        }),
        catch: (error) => error instanceof BrokerError
          ? error
          : brokerError("revision.failed", "failed to complete workspace import"),
      });
      yield* registry.bindAuthority({
        environmentKey: request.destinationEnvironmentKey,
        profile: config.profile,
        executor: config.policyFile.defaultExecutor,
        authorityClass: config.policyFile.defaultAuthorityClass,
        policyDigest: authority.policyDigest,
        workspaceId: acquired.workspace.workspaceId,
        workspaceLeaseId: acquired.lease.leaseId,
      });
      return {
        preparationId: completed.preparationId,
        sourceRevisionId: completed.sourceRevisionId,
        workspace: visibleWorkspace(acquired.workspace),
        lease: acquired.lease,
      };
    });

  return { publish, importRevision } satisfies RevisionOperationsService;
});

export const RevisionOperationsLive = Layer.effect(RevisionOperations, make);
