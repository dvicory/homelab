import { Context, Effect, Layer, STM, TSemaphore } from "effect";
import { Authorization } from "../auth.js";
import { Environments } from "../environments.js";
import { BrokerError, brokerError } from "../errors.js";
import { Registry } from "../registry.js";
import { TaskRunActivations } from "../task-run-activations.js";
import { Workspaces } from "../workspaces.js";
import type {
  CaptureWorkspaceHandoffRequest,
  ReadWorkspaceArtifactRequest,
} from "./model.js";
import type { OutputSnapshot } from "./capture.js";
import {
  HandoffStorage,
  type ArtifactFileStream,
  type HandoffLimits,
} from "./frozen-tree.js";
import { HandoffStore, type HandoffRecord } from "./repository.js";
import { InputPreparations } from "../task-run-inputs/service.js";
import { ProjectWorkspaces } from "../project-workspace/service.js";

export interface CapturedHandoff {
  readonly handoffId: string;
  readonly entryCount: number;
  readonly totalBytes: number;
  readonly selectedArtifacts: ReadonlyArray<string>;
}

export interface HandoffOperationsService {
  readonly capture: (
    request: CaptureWorkspaceHandoffRequest,
  ) => Effect.Effect<CapturedHandoff, BrokerError>;
  readonly readArtifact: (
    request: ReadWorkspaceArtifactRequest,
  ) => Effect.Effect<ArtifactFileStream, BrokerError>;
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
  if (handoff.state !== "ready") {
    throw brokerError("handoff.invalid_state", "workspace handoff is not ready");
  }
  return {
    handoffId: handoff.handoffId,
    entryCount: handoff.entryCount,
    totalBytes: handoff.totalBytes,
    selectedArtifacts: handoff.selectedArtifacts,
  };
};

const requestFactsMatch = (
  handoff: HandoffRecord,
  request: CaptureWorkspaceHandoffRequest,
): boolean =>
  handoff.finalizationId === request.finalizationId &&
  handoff.sourceTaskId === request.taskId &&
  handoff.sourceRunId === request.runId &&
  handoff.sourceEnvironmentKey === request.environmentKey &&
  JSON.stringify(handoff.selectedArtifacts) === JSON.stringify(request.selectedArtifacts);

const make = Effect.gen(function* () {
  const authorization = yield* Authorization;
  const environments = yield* Environments;
  const registry = yield* Registry;
  const storage = yield* HandoffStorage;
  const store = yield* HandoffStore;
  const activations = yield* TaskRunActivations;
  const inputPreparations = yield* InputPreparations;
  const workspaces = yield* Workspaces;
  const projectWorkspaces = yield* ProjectWorkspaces;
  const mutation = yield* STM.commit(TSemaphore.make(1));

  const fenceAndCapture = (
    staged: HandoffRecord,
    limits: HandoffLimits,
    firstPreflight?: OutputSnapshot,
  ): Effect.Effect<CapturedHandoff, BrokerError> => Effect.gen(function* () {
    const source = yield* workspaces.resolveJournaled(
      staged.sourceEnvironmentKey,
      staged.sourceWorkspaceId,
      staged.sourceWorkspaceLeaseId,
      staged.sourceLeaseFencingToken,
    );
    const consumed = yield* activations.consumeAtomically({
      environmentKey: staged.sourceEnvironmentKey,
      taskId: staged.sourceTaskId,
      runId: staged.sourceRunId,
    }, (current) => {
      if (
        current.activationId !== staged.sourceActivationId ||
        current.workspaceId !== staged.sourceWorkspaceId ||
        current.workspaceLeaseId !== staged.sourceWorkspaceLeaseId ||
        current.policyDigest !== staged.policyDigest
      ) {
        throw brokerError("handoff.conflict", "journaled capture facts no longer match the source activation");
      }
    });

    if (source.lease.state === "active") {
      yield* workspaces.release(
        staged.sourceEnvironmentKey,
        staged.sourceWorkspaceId,
        staged.sourceWorkspaceLeaseId,
      ).pipe(
        Effect.catchAll((error) => Effect.gen(function* () {
          if (!(error instanceof BrokerError) || error.reason !== "workspace.stale_lease") {
            return yield* Effect.fail(error);
          }
          const released = yield* workspaces.resolveJournaled(
            staged.sourceEnvironmentKey,
            staged.sourceWorkspaceId,
            staged.sourceWorkspaceLeaseId,
            staged.sourceLeaseFencingToken,
          );
          if (released.lease.state !== "released") return yield* Effect.fail(error);
        })),
      );
    }
    store.recordPhase(staged.handoffId, "fenced");

    if (consumed.generationToClose !== null) {
      yield* environments.closeForFence(consumed.generationToClose);
    } else {
      const environment = yield* registry.get(staged.sourceEnvironmentKey);
      if (environment !== undefined && environment.state === "failed") {
        return yield* brokerError("runtime.operation_failed", "source environment fencing previously failed");
      }
      if (environment !== undefined && environment.state !== "closed") {
        if (
          environment.workspaceId !== staged.sourceWorkspaceId ||
          environment.workspaceLeaseId !== staged.sourceWorkspaceLeaseId
        ) {
          return yield* brokerError("handoff.conflict", "source environment generation changed during recovery");
        }
        yield* environments.closeForFence({
          environmentKey: environment.environmentKey,
          generation: environment.generation,
        });
      }
    }
    const afterFence = yield* registry.get(staged.sourceEnvironmentKey);
    if (afterFence !== undefined && afterFence.state !== "closed") {
      return yield* brokerError(
        afterFence.state === "failed" ? "runtime.operation_failed" : "handoff.conflict",
        afterFence.state === "failed"
          ? "source environment fencing failed"
          : "source environment remains live after fencing",
      );
    }
    store.recordPhase(staged.handoffId, "vm_closed");

    const preflight = firstPreflight ?? (yield* storage.preflightOutput(
      source.workspacePath,
      limits,
      staged.selectedArtifacts,
    ));
    const finalized = yield* storage.captureHandoff(
      staged,
      source.workspacePath,
      limits,
      preflight,
    );
    // A broker-project run additionally records its bounded result descriptor
    // before the handoff commits; a retry replays both steps idempotently.
    if (consumed.activation.authority.project !== undefined) {
      yield* projectWorkspaces.recordResult(
        staged.sourceEnvironmentKey,
        staged.sourceTaskId,
        staged.sourceRunId,
        source.workspacePath,
      );
    }
    const committed = yield* Effect.try({
      try: () => store.markHandoffReady(staged.handoffId, finalized.entryCount, finalized.totalBytes),
      catch: (error) => error instanceof BrokerError
        ? error
        : brokerError("handoff.failed", "failed to commit handoff state"),
    });
    yield* inputPreparations.releaseRun(
      staged.sourceEnvironmentKey,
      staged.sourceTaskId,
      staged.sourceRunId,
    );
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
        catch: (error) => error instanceof BrokerError
          ? error
          : brokerError("policy.indeterminate", "workspace handoff limits are invalid"),
      });

      const prior = yield* Effect.try({
        try: () => store.findByFinalization(request.finalizationId),
        catch: (error) => error instanceof BrokerError
          ? error
          : brokerError("handoff.failed", "failed to resolve handoff replay"),
      });
      if (prior !== null) {
        if (!requestFactsMatch(prior, request)) {
          return yield* brokerError(
            "handoff.conflict",
            "finalization ID is bound to different capture facts",
          );
        }
        if (
          prior.policyDigest !== authority.policyDigest ||
          prior.policyDecisionDigest !== authority.decisionDigest
        ) {
          return yield* brokerError(
            "handoff.conflict",
            "finalization ID is bound to different authority facts",
          );
        }
        if (prior.state === "ready") {
          yield* inputPreparations.releaseRun(prior.sourceEnvironmentKey, prior.sourceTaskId, prior.sourceRunId);
          return captured(prior);
        }
        if (prior.state === "staging") return yield* fenceAndCapture(prior, limits);
        return yield* brokerError("handoff.invalid_state", "workspace handoff is terminal");
      }

      const activation = yield* activations.validate(request.environmentKey, {
        taskId: request.taskId,
        runId: request.runId,
      });
      if (activation === undefined) {
        return yield* brokerError(
          "run_activation.not_found",
          "capture source activation does not exist",
        );
      }
      if (activation.policyDigest !== authority.policyDigest) {
        return yield* brokerError(
          "run_activation.stale",
          "capture activation policy is no longer active",
        );
      }
      const source = yield* workspaces.resolve(
        request.environmentKey,
        activation.workspaceId,
        activation.workspaceLeaseId,
      );
      const preflight = yield* storage.preflightOutput(
        source.workspacePath,
        limits,
        request.selectedArtifacts,
      );

      const consumed = yield* activations.consumeAtomically({
        environmentKey: request.environmentKey,
        taskId: request.taskId,
        runId: request.runId,
      }, (current) => {
        if (
          current.activationId !== activation.activationId ||
          current.policyDigest !== authority.policyDigest
        ) {
          throw brokerError("run_activation.stale", "capture activation changed during preflight");
        }
        return store.stageCapture({
          finalizationId: request.finalizationId,
          policyDecisionDigest: authority.decisionDigest,
          sourceActivationId: current.activationId,
          selectedArtifacts: request.selectedArtifacts,
        });
      });
      return yield* fenceAndCapture(consumed.result, limits, preflight);
    }),
    mutation,
  );

  const readArtifact = (
    request: ReadWorkspaceArtifactRequest,
  ): Effect.Effect<ArtifactFileStream, BrokerError> => Effect.gen(function* () {
    const authority = yield* authorization.authorize({
      action: "workspace.artifact.read",
      resource: `handoff:${request.handoffId}`,
    });
    const limits = yield* Effect.try({
      try: () => handoffLimits(authority.limits),
      catch: (error) => error instanceof BrokerError
        ? error
        : brokerError("policy.indeterminate", "workspace handoff limits are invalid"),
    });
    const handoff = yield* Effect.try({
      try: () => store.getHandoff(request.handoffId),
      catch: (error) => error instanceof BrokerError
        ? error
        : brokerError("handoff.failed", "failed to resolve workspace handoff"),
    });
    if (handoff.state !== "ready") {
      return yield* brokerError("handoff.invalid_state", "only a ready handoff can be read");
    }
    if (handoff.policyDigest !== authority.policyDigest) {
      return yield* brokerError("handoff.conflict", "handoff read policy changed");
    }
    return yield* storage.readArtifact(handoff, request.relativePath, limits);
  });

  return { capture, readArtifact } satisfies HandoffOperationsService;
});

export const HandoffOperationsLive = Layer.effect(HandoffOperations, make);
