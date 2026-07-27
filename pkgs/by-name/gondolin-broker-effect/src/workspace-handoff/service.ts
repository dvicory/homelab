import { Context, Effect, Layer, STM, TSemaphore } from "effect";
import { Authorization } from "../auth.js";
import { BrokerConfig } from "../config.js";
import type {
  CaptureWorkspaceHandoffRequest,
  CompleteWorkspaceImport,
  ImportWorkspaceHandoffRequest,
  PrepareWorkspaceExportRequest,
  ReadWorkspaceExportRequest,
  ReleaseWorkspaceExportRequest,
} from "./model.js";
import { BrokerError, brokerError } from "../errors.js";
import { Environments } from "../environments.js";
import { Registry } from "../registry.js";
import {
  HandoffStorage,
  isTerminalCaptureFailure,
  type HandoffLimits,
  type ExportFileStream,
} from "./frozen-tree.js";
import { HandoffStore, type HandoffRecord } from "./repository.js";
import { TaskRunActivations } from "../task-run-activations.js";
import { Workspaces, type WorkspaceBinding, type WorkspaceRecord } from "../workspaces.js";

export interface CapturedHandoff {
  readonly handoffId: string;
  readonly entryCount: number;
  readonly totalBytes: number;
}

export interface ImportedWorkspace {
  readonly preparationId: string;
  readonly sourceHandoffId: string;
  readonly workspace: {
    readonly workspaceId: string;
    readonly ownerEnvironmentKey: string;
    readonly kind: "private";
    readonly state: "active";
    readonly guestPath: "/workspace";
  };
  readonly lease: WorkspaceBinding["lease"];
}

export interface PreparedWorkspaceExport {
  readonly exportToken: string;
  readonly fileName: string;
  readonly size: number;
  readonly expiresAt: number;
}

export interface HandoffOperationsService {
  readonly capture: (
    request: CaptureWorkspaceHandoffRequest,
  ) => Effect.Effect<CapturedHandoff, BrokerError>;
  readonly importHandoff: (
    request: ImportWorkspaceHandoffRequest,
  ) => Effect.Effect<ImportedWorkspace, BrokerError>;
  readonly prepareExport: (
    request: PrepareWorkspaceExportRequest,
  ) => Effect.Effect<PreparedWorkspaceExport, BrokerError>;
  readonly readExport: (
    request: ReadWorkspaceExportRequest,
  ) => Effect.Effect<ExportFileStream, BrokerError>;
  readonly releaseExport: (
    request: ReleaseWorkspaceExportRequest,
  ) => Effect.Effect<{ readonly released: boolean }, BrokerError>;
}

export class HandoffOperations extends Context.Tag("@agent-x/gondolin-broker-effect/HandoffOperations")<
  HandoffOperations,
  HandoffOperationsService
>() {}


const requiredLimit = (limits: Readonly<Record<string, number>>, name: string): number => {
  const value = limits[name];
  if (!Number.isSafeInteger(value) || value === undefined || value <= 0) {
    throw brokerError("policy.indeterminate", `workspace handoff policy requires ${name}`);
  }
  return value;
};

const handoffLimits = (limits: Readonly<Record<string, number>>): HandoffLimits => ({
  maxLogicalBytes: requiredLimit(limits, "maxLogicalBytes"),
  maxEntries: requiredLimit(limits, "maxEntries"),
  maxFileBytes: requiredLimit(limits, "maxFileBytes"),
  maxPathBytes: requiredLimit(limits, "maxPathBytes"),
});

const captured = (handoff: HandoffRecord): CapturedHandoff => {
  if (handoff.state !== "ready") throw brokerError("handoff.invalid_state", "workspace handoff is not ready");
  return {
    handoffId: handoff.handoffId,
    entryCount: handoff.entryCount,
    totalBytes: handoff.totalBytes,
  };
};

const visibleWorkspace = (workspace: WorkspaceRecord): ImportedWorkspace["workspace"] => {
  if (workspace.state !== "active") throw brokerError("workspace.conflict", "imported workspace is not active");
  return {
    workspaceId: workspace.workspaceId,
    ownerEnvironmentKey: workspace.ownerEnvironmentKey,
    kind: workspace.kind,
    state: workspace.state,
    guestPath: "/workspace",
  };
};

const requestFactsMatch = (
  handoff: HandoffRecord,
  request: CaptureWorkspaceHandoffRequest,
): boolean => handoff.finalizationId === request.finalizationId && handoff.sourceTaskId === request.taskId &&
  handoff.sourceRunId === request.runId && handoff.sourceEnvironmentKey === request.environmentKey &&
  JSON.stringify(handoff.selectedArtifacts) === JSON.stringify(request.selectedArtifacts);

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const authorization = yield* Authorization;
  const environments = yield* Environments;
  const registry = yield* Registry;
  const storage = yield* HandoffStorage;
  const store = yield* HandoffStore;
  const activations = yield* TaskRunActivations;
  const workspaces = yield* Workspaces;
  const mutation = yield* STM.commit(TSemaphore.make(1));
  const recoverStagedCapture = (
    prior: HandoffRecord,
    request: CaptureWorkspaceHandoffRequest,
    policyDigest: string,
    policyDecisionDigest: string,
    limits: HandoffLimits,
  ): Effect.Effect<CapturedHandoff, BrokerError> => Effect.gen(function* () {
    if (prior.policyDigest !== policyDigest || prior.policyDecisionDigest !== policyDecisionDigest) {
      return yield* brokerError("handoff.conflict", "journaled capture authority facts no longer match");
    }
    const source = yield* workspaces.resolveJournaled(
      prior.sourceEnvironmentKey,
      prior.sourceWorkspaceId,
      prior.sourceWorkspaceLeaseId,
      prior.sourceLeaseFencingToken,
    );
    const consumed = yield* activations.consumeAtomically({
      environmentKey: request.environmentKey,
      taskId: request.taskId,
      runId: request.runId,
    }, (current) => {
      if (
        current.activationId !== prior.sourceActivationId ||
        current.workspaceId !== prior.sourceWorkspaceId ||
        current.workspaceLeaseId !== prior.sourceWorkspaceLeaseId ||
        current.policyDigest !== policyDigest
      ) {
        throw brokerError("handoff.conflict", "journaled capture facts no longer match the source activation");
      }
    });
    if (source.lease.state === "active") {
      yield* workspaces.release(
        prior.sourceEnvironmentKey,
        prior.sourceWorkspaceId,
        prior.sourceWorkspaceLeaseId,
      ).pipe(
        Effect.map(() => undefined),
        Effect.catchAll((error) => Effect.gen(function* () {
          if (!(error instanceof BrokerError) || error.reason !== "workspace.stale_lease") {
            return yield* Effect.fail(error);
          }
          const released = yield* workspaces.resolveJournaled(
            prior.sourceEnvironmentKey,
            prior.sourceWorkspaceId,
            prior.sourceWorkspaceLeaseId,
            prior.sourceLeaseFencingToken,
          );
          if (released.lease.state !== "released") return yield* Effect.fail(error);
        })),
      );
    }
    const revoked = yield* workspaces.resolveJournaled(
      prior.sourceEnvironmentKey,
      prior.sourceWorkspaceId,
      prior.sourceWorkspaceLeaseId,
      prior.sourceLeaseFencingToken,
    );
    if (revoked.lease.state !== "released") {
      return yield* brokerError("handoff.conflict", "source workspace writer lease was not revoked");
    }
    if (consumed.generationToClose !== null) {
      yield* environments.closeForFence(consumed.generationToClose);
    } else {
      const environment = yield* registry.get(prior.sourceEnvironmentKey);
      if (environment !== undefined && environment.state === "failed") {
        return yield* brokerError("runtime.operation_failed", "source environment fencing previously failed");
      }
      if (environment !== undefined && environment.state !== "closed") {
        if (
          environment.workspaceId !== prior.sourceWorkspaceId ||
          environment.workspaceLeaseId !== prior.sourceWorkspaceLeaseId
        ) {
          return yield* brokerError("handoff.conflict", "source environment generation changed during recovery");
        }
        yield* environments.closeForFence({
          environmentKey: environment.environmentKey,
          generation: environment.generation,
        });
      }
    }
    const afterFence = yield* registry.get(prior.sourceEnvironmentKey);
    if (afterFence !== undefined && afterFence.state !== "closed") {
      return yield* brokerError(
        afterFence.state === "failed" ? "runtime.operation_failed" : "handoff.conflict",
        afterFence.state === "failed"
          ? "source environment fencing failed"
          : "source environment remains live after recovery fencing",
      );
    }
    yield* workspaces.resolveJournaled(
      prior.sourceEnvironmentKey,
      prior.sourceWorkspaceId,
      prior.sourceWorkspaceLeaseId,
      prior.sourceLeaseFencingToken,
    );
    const preflight = yield* storage.preflightOutput(source.workspacePath, limits, request.selectedArtifacts).pipe(
      Effect.catchAll((error) => Effect.gen(function* () {
        if (isTerminalCaptureFailure(error)) {
          yield* Effect.sync(() => store.failHandoff(
            prior.handoffId,
            "publication_failed",
            error.message.slice(0, 4096),
          )).pipe(Effect.ignore);
        }
        return yield* Effect.fail(error);
      })),
    );
    const finalized = yield* storage.captureHandoff(prior, source.workspacePath, limits, preflight);
    const committed = yield* Effect.try({
      try: () => store.markHandoffReady(prior.handoffId, finalized.entryCount, finalized.totalBytes),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to commit handoff state"),
    });
    return captured(committed);
  });

  const capture = (
    request: CaptureWorkspaceHandoffRequest,
  ): Effect.Effect<CapturedHandoff, BrokerError> => TSemaphore.withPermit(
    Effect.gen(function* () {
    const authority = yield* authorization.authorize({
      action: "workspace.capture",
      resource: `task-run:${request.taskId}`,
    });
    const limits = yield* Effect.try({
      try: () => handoffLimits(authority.limits),
      catch: (error) => error instanceof BrokerError ? error : brokerError("policy.indeterminate", "workspace handoff limits are invalid"),
    });

    const prior = yield* Effect.try({
      try: () => store.findByFinalization(request.finalizationId),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to resolve handoff replay"),
    });
    if (prior !== null) {
      if (!requestFactsMatch(prior, request)) return yield* brokerError("handoff.conflict", "finalization ID is bound to different capture facts");
      if (prior.policyDigest !== authority.policyDigest || prior.policyDecisionDigest !== authority.decisionDigest) {
        return yield* brokerError("handoff.conflict", "finalization ID is bound to different authority facts");
      }
      if (prior.state === "ready") return captured(prior);
      if (prior.state === "staging") {
        return yield* recoverStagedCapture(prior, request, authority.policyDigest, authority.decisionDigest, limits);
      }
      return yield* brokerError("handoff.invalid_state", "workspace handoff is terminal");
    }

    const activation = yield* activations.validate(request.environmentKey, {
      taskId: request.taskId,
      runId: request.runId,
    });
    if (activation === undefined) return yield* brokerError("run_activation.not_found", "capture source activation does not exist");
    if (activation.policyDigest !== authority.policyDigest) return yield* brokerError("run_activation.stale", "capture activation policy is no longer active");
    const source = yield* workspaces.resolve(request.environmentKey, activation.workspaceId, activation.workspaceLeaseId);
    const preflight = yield* storage.preflightOutput(source.workspacePath, limits, request.selectedArtifacts);

    const consumed = yield* activations.consumeAtomically({
      environmentKey: request.environmentKey,
      taskId: request.taskId,
      runId: request.runId,
    }, (current) => {
      if (current.activationId !== activation.activationId || current.policyDigest !== authority.policyDigest) {
        throw brokerError("run_activation.stale", "capture activation changed during preflight");
      }
      return store.stageCapture({
        finalizationId: request.finalizationId,
        policyDecisionDigest: authority.decisionDigest,
        sourceActivationId: current.activationId,
        selectedArtifacts: request.selectedArtifacts,
      });
    });
    const staged = consumed.result;

    const postFence = Effect.gen(function* () {
      yield* workspaces.release(
        consumed.activation.environmentKey,
        consumed.activation.workspaceId,
        consumed.activation.workspaceLeaseId,
      );
      if (consumed.generationToClose !== null) yield* environments.closeForFence(consumed.generationToClose);
      const finalized = yield* storage.captureHandoff(staged, source.workspacePath, limits, preflight);
      const committed = yield* Effect.try({
        try: () => store.markHandoffReady(staged.handoffId, finalized.entryCount, finalized.totalBytes),
        catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to commit handoff state"),
      });
      return captured(committed);
    });
    return yield* postFence.pipe(
      Effect.catchAll((error) => Effect.gen(function* () {
        if (consumed.generationToClose !== null) {
          yield* environments.closeForFence(consumed.generationToClose).pipe(Effect.ignore);
        }
        return yield* Effect.fail(error);
      })),
    );
    }),
    mutation,
  );

  const cleanFailedDestination = (
    binding: WorkspaceBinding,
    preparationId: string,
    reason: string,
  ): Effect.Effect<void, never> => Effect.gen(function* () {
    yield* workspaces.release(binding.workspace.ownerEnvironmentKey, binding.workspace.workspaceId, binding.lease.leaseId).pipe(Effect.ignore);
    yield* workspaces.close(binding.workspace.ownerEnvironmentKey, binding.workspace.workspaceId).pipe(Effect.ignore);
    yield* Effect.sync(() => store.failImport(preparationId, reason)).pipe(Effect.ignore);
  });

  const importHandoff = (
    request: ImportWorkspaceHandoffRequest,
  ): Effect.Effect<ImportedWorkspace, BrokerError> => TSemaphore.withPermit(
    Effect.gen(function* () {
    const source = yield* Effect.try({
      try: () => store.getHandoff(request.sourceHandoffId),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to resolve source handoff"),
    });
    if (source.state !== "ready") return yield* brokerError("handoff.invalid_state", "only a ready handoff can be imported");
    if (source.sourceTaskId !== request.sourceTaskId) return yield* brokerError("handoff.conflict", "source task does not own the handoff");
    if (source.policyDigest !== config.policyFile.policyDigest) return yield* brokerError("handoff.conflict", "source handoff policy is no longer active");
    const authority = yield* authorization.authorize({
      action: "workspace.import",
      resource: `task-run:${request.destinationTaskId}`,
    });
    const limits = yield* Effect.try({
      try: () => handoffLimits(authority.limits),
      catch: (error) => error instanceof BrokerError ? error : brokerError("policy.indeterminate", "workspace handoff limits are invalid"),
    });
    yield* storage.validateHandoff(source, limits);
    const staged = yield* Effect.try({
      try: () => store.stageImport({
        preparationId: request.preparationId,
        policyDecisionDigest: authority.decisionDigest,
        sourceHandoffId: source.handoffId,
        destinationTaskId: request.destinationTaskId,
        destinationRunId: request.destinationRunId,
        destinationEnvironmentKey: request.destinationEnvironmentKey,
        sourcePolicyDigest: source.policyDigest,
        destinationPolicyDigest: authority.policyDigest,
      }),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to stage workspace import"),
    });
    if (staged.state === "ready") {
      if (staged.destinationWorkspaceId === null || staged.destinationWorkspaceLeaseId === null) {
        return yield* brokerError("handoff.failed", "ready import has no destination workspace");
      }
      const resolved = yield* workspaces.resolve(request.destinationEnvironmentKey, staged.destinationWorkspaceId, staged.destinationWorkspaceLeaseId);
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
        sourceHandoffId: staged.sourceHandoffId,
        workspace: visibleWorkspace(resolved.workspace),
        lease: resolved.lease,
      };
    }

    const requestedWorkspaceId = staged.destinationWorkspaceId ?? undefined;
    const acquired = yield* workspaces.acquireAtomically(
      request.destinationEnvironmentKey,
      requestedWorkspaceId,
      ({ workspace, lease }, created) => {
        if (!created && requestedWorkspaceId === undefined) {
          throw brokerError("workspace.conflict", "destination environment already has an active workspace");
        }
        return store.reserveImportDestination({
          preparationId: request.preparationId,
          destinationWorkspaceId: workspace.workspaceId,
          destinationWorkspaceLeaseId: lease.leaseId,
        });
      },
    );
    const binding: WorkspaceBinding = { workspace: acquired.workspace, lease: acquired.lease };
    const resolved = yield* workspaces.resolve(request.destinationEnvironmentKey, acquired.workspace.workspaceId, acquired.lease.leaseId);
    yield* storage.materializeHandoff(source, resolved.workspacePath, limits).pipe(
      Effect.tapError((error) => cleanFailedDestination(binding, request.preparationId, error.message)),
    );
    const completed = yield* Effect.try({
      try: () => store.completeImport({
        preparationId: request.preparationId,
        destinationWorkspaceId: acquired.workspace.workspaceId,
        destinationWorkspaceLeaseId: acquired.lease.leaseId,
      } satisfies typeof CompleteWorkspaceImport.Type),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to complete workspace import"),
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
      sourceHandoffId: completed.sourceHandoffId,
      workspace: visibleWorkspace(acquired.workspace),
      lease: acquired.lease,
    };
    }),
    mutation,
  );

  const prepareExport = (
    request: PrepareWorkspaceExportRequest,
  ): Effect.Effect<PreparedWorkspaceExport, BrokerError> => Effect.gen(function* () {
    const authority = yield* authorization.authorize({ action: "workspace.export", resource: `handoff:${request.handoffId}` });
    const prior = yield* Effect.try({
      try: () => store.findExportByDelivery(request.deliveryId),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to resolve workspace export replay"),
    });
    if (prior !== null) {
      if (prior.handoffId !== request.handoffId || prior.relativePath !== request.relativePath) {
        return yield* brokerError("handoff.conflict", "delivery ID is bound to different export facts");
      }
      if (prior.state !== "active" || prior.expiresAt <= Date.now()) {
        return yield* brokerError(
          "handoff.invalid_state",
          prior.state === "expired" || prior.expiresAt <= Date.now()
            ? "workspace export token has expired"
            : "workspace export token is no longer active",
        );
      }
      return { exportToken: prior.exportToken, fileName: prior.fileName, size: prior.byteSize, expiresAt: prior.expiresAt };
    }
    const limits = yield* Effect.try({
      try: () => handoffLimits(authority.limits),
      catch: (error) => error instanceof BrokerError ? error : brokerError("policy.indeterminate", "workspace handoff limits are invalid"),
    });
    const handoff = yield* Effect.try({
      try: () => store.getHandoff(request.handoffId),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to resolve workspace handoff"),
    });
    yield* storage.validateHandoff(handoff, limits);
    const facts = yield* storage.inspectExportFile(request.handoffId, request.relativePath);
    const expiresAt = Date.now() + config.workspaceHandoffExportTtlMs;
    const record = yield* Effect.try({
      try: () => store.prepareExport({ ...request, ...facts, expiresAt }),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to prepare workspace export"),
    });
    return { exportToken: record.exportToken, fileName: record.fileName, size: record.byteSize, expiresAt: record.expiresAt };
  });

  const readExport = (
    request: ReadWorkspaceExportRequest,
  ): Effect.Effect<ExportFileStream, BrokerError> => Effect.gen(function* () {
    const record = yield* Effect.try({
      try: () => store.getExport(request.exportToken),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to resolve workspace export"),
    });
    if (record.state !== "active") {
      return yield* brokerError(
        "handoff.invalid_state",
        record.state === "expired" ? "workspace export token has expired" : "workspace export token is not active",
      );
    }
    const authority = yield* authorization.authorize({ action: "workspace.export", resource: `handoff:${record.handoffId}` });
    const limits = yield* Effect.try({
      try: () => handoffLimits(authority.limits),
      catch: (error) => error instanceof BrokerError ? error : brokerError("policy.indeterminate", "workspace handoff limits are invalid"),
    });
    const handoff = yield* Effect.try({
      try: () => store.getHandoff(record.handoffId),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to resolve workspace handoff"),
    });
    yield* storage.validateHandoff(handoff, limits);
    return yield* storage.openExport(record);
  });

  const releaseExport = (
    request: ReleaseWorkspaceExportRequest,
  ): Effect.Effect<{ readonly released: boolean }, BrokerError> => Effect.gen(function* () {
    const prior = yield* Effect.try({
      try: () => store.getExport(request.exportToken),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to resolve workspace export"),
    });
    yield* authorization.authorize({ action: "workspace.export", resource: `handoff:${prior.handoffId}` });
    const released = yield* Effect.try({
      try: () => store.releaseExport(request),
      catch: (error) => error instanceof BrokerError ? error : brokerError("handoff.failed", "failed to release workspace export"),
    });
    return { released: released.state === "released" };
  });

  return { capture, importHandoff, prepareExport, readExport, releaseExport } satisfies HandoffOperationsService;
});

export const HandoffOperationsLive = Layer.effect(HandoffOperations, make);
