import { createHash } from "node:crypto";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { Context, Effect, Layer, STM, TSemaphore } from "effect";
import { BrokerConfig } from "../config.js";
import type { ActivateTaskRunRequest } from "../domain.js";
import { BrokerError, brokerError } from "../errors.js";
import {
  acquireGitSource,
  applyWorkPlanePermission,
  changedPaths,
  installGeneration,
  resolveUpstreamRevision,
} from "./git-adapter.js";
import type {
  MaterializationRecord,
  ProjectResultRecord,
  ResolveProjectSourceRequest,
  ResolveProjectSourceResponse,
  SourceGenerationRecord,
} from "./model.js";
import { ProjectWorkspaceStore } from "./store.js";

export interface ProjectWorkspacesService {
  readonly resolveSource: (
    request: ResolveProjectSourceRequest,
  ) => Effect.Effect<ResolveProjectSourceResponse, BrokerError>;
  readonly ensureMaterialized: (
    request: ActivateTaskRunRequest,
    workspacePath: string,
    leaseFencingToken: number,
  ) => Effect.Effect<MaterializationRecord, BrokerError>;
  readonly recordResult: (
    environmentKey: string,
    taskId: string,
    runId: string,
    workspacePath: string,
  ) => Effect.Effect<ProjectResultRecord | null, BrokerError>;
  readonly readResult: (
    taskId: string,
    runId: string,
  ) => Effect.Effect<ProjectResultRecord | null, BrokerError>;
}

export class ProjectWorkspaces extends Context.Tag("@agent-x/gondolin-broker-effect/ProjectWorkspaces")<
  ProjectWorkspaces,
  ProjectWorkspacesService
>() {}

const ADAPTER_REVISION = createHash("sha256").update("broker-project-git-adapter:1").digest("hex");
const MAX_RESULT_PATHS = 4096;

const canonical = (value: unknown): string => JSON.stringify(value, Object.keys(value as object).sort());
const generationIdFor = (facts: Readonly<Record<string, string>>): string =>
  createHash("sha256").update(canonical(facts)).digest("hex");

const serviceFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("project_materialization.failed", `project workspace ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const store = yield* ProjectWorkspaceStore;
  const mutation = yield* STM.commit(TSemaphore.make(1));

  const generationsRoot = path.join(config.stateDir, "project-generations");
  const secretsDir = process.env.CREDENTIALS_DIRECTORY ?? null;
  yield* Effect.tryPromise({
    try: () => fs.mkdir(generationsRoot, { recursive: true, mode: 0o700 }),
    catch: (error) => serviceFailure("open", error),
  });

  const requirePolicy = (): Effect.Effect<
    NonNullable<typeof config.policyFile.projectWorkspace>,
    BrokerError
  > =>
    config.policyFile.projectWorkspace === undefined
      ? Effect.fail(brokerError("policy.indeterminate", "broker-project provider is not configured"))
      : Effect.succeed(config.policyFile.projectWorkspace);

  const storageBytes = async (): Promise<number> => {
    let total = 0;
    const walk = async (directory: string): Promise<void> => {
      const entries = await fs.readdir(directory, { withFileTypes: true }).catch(() => []);
      for (const entry of entries) {
        const absolute = path.join(directory, entry.name);
        if (entry.isDirectory()) {
          await walk(absolute);
        } else if (entry.isFile()) {
          total += Number((await fs.lstat(absolute)).size);
        }
      }
    };
    await walk(generationsRoot);
    return total;
  };

  // Crash reconciliation (2.3): a broker restart abandons any in-flight
  // resolution or staging; partial storage is removed before it can reach
  // execution, and durable rows move to a terminal failed state.
  yield* Effect.tryPromise({
    try: async () => {
      for (const staged of store.listMaterializations(["staging", "installing"])) {
        store.failMaterialization(staged.materializationId, "broker restarted before reconciliation");
      }
    },
    catch: (error) => serviceFailure("materialization reconciliation", error),
  });
  yield* Effect.tryPromise({
    try: async () => {
      const entries = await fs.readdir(generationsRoot, { withFileTypes: true }).catch(() => []);
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        const generation = store.getGeneration(entry.name);
        if (generation === null || generation.state === "failed") {
          await fs.rm(path.join(generationsRoot, entry.name), { recursive: true, force: true });
          continue;
        }
        if (generation.state === "resolving") {
          store.failGeneration(entry.name, "broker restarted before reconciliation");
          await fs.rm(path.join(generationsRoot, entry.name), { recursive: true, force: true });
        }
      }
    },
    catch: (error) => serviceFailure("generation reconciliation", error),
  });
  // Retention and deletion (2.3, 5.4): recorded Project results expire after
  // the policy retention window; materializations whose workspace row is gone
  // can never be consumed again and are marked deleted.
  if (config.policyFile.projectWorkspace !== undefined) {
    yield* Effect.try({
      try: () => {
        const swept = store.sweepRetention(config.policyFile.projectWorkspace!.limits.retentionMs);
        if (swept.results > 0 || swept.materializations > 0) {
          process.stderr.write(
            `[project-workspace] retention sweep: ${swept.results} results, ${swept.materializations} materializations\n`,
          );
        }
      },
      catch: (error) => serviceFailure("retention sweep", error),
    });
  }

  const resolveSource = (
    request: ResolveProjectSourceRequest,
  ): Effect.Effect<ResolveProjectSourceResponse, BrokerError> =>
    TSemaphore.withPermit(
      Effect.gen(function* () {
        const policy = yield* requirePolicy();
        const source = policy.sources[request.repositoryId];
        if (source === undefined) {
          return yield* brokerError("project_source.not_found", "repository is not a trusted Project source", {
            repositoryId: request.repositoryId,
          });
        }
        if (policy.sourceRevisions[request.repositoryId] !== request.sourceRevision) {
          return yield* brokerError(
            "project_source.stale",
            "source revision does not match the immutable policy",
            { repositoryId: request.repositoryId },
          );
        }
        const providerRevision = policy.providerRevisions[policy.provider];
        if (providerRevision === undefined) {
          return yield* brokerError("policy.indeterminate", "broker-project provider revision is unavailable");
        }

        const resolution = yield* Effect.tryPromise({
          try: () =>
            resolveUpstreamRevision(
              source,
              secretsDir,
              path.join(config.stateDir, "project-staging", ".resolve-helpers"),
              policy.limits.deadlineMs,
            ),
          catch: (error) => serviceFailure("source resolution", error),
        });
        const sourceGenerationId = generationIdFor({
          adapterRevision: ADAPTER_REVISION,
          policyDigest: config.policyFile.policyDigest,
          project: request.project,
          projectRevision: request.projectRevision,
          repositoryId: request.repositoryId,
          resolvedRevision: resolution,
          sourceRevision: request.sourceRevision,
        });
        const existing = yield* Effect.try({
          try: () => store.getGeneration(sourceGenerationId),
          catch: (error) => serviceFailure("source generation lookup", error),
        });
        if (existing !== null && existing.state === "ready") {
          return {
            sourceGeneration: existing.sourceGenerationId,
            resolvedRevision: existing.resolvedRevision,
            adapterRevision: existing.adapterRevision,
          };
        }
        if (existing !== null && existing.state === "resolving") {
          return yield* brokerError(
            "project_source.conflict",
            "source generation resolution is already in progress",
          );
        }

        const activeMaterializations = yield* Effect.try({
          try: () => store.listMaterializations(["staging", "installing", "ready"]).length,
          catch: (error) => serviceFailure("materialization accounting", error),
        });
        if (activeMaterializations >= policy.limits.maxProjectWorkspaces) {
          return yield* brokerError("project_materialization.limit", "project workspace count limit reached", {
            maxProjectWorkspaces: policy.limits.maxProjectWorkspaces,
          });
        }
        const usedBytes = yield* Effect.tryPromise({
          try: () => storageBytes(),
          catch: (error) => serviceFailure("storage accounting", error),
        });
        if (usedBytes > policy.limits.maxStorageBytes) {
          return yield* brokerError("project_materialization.limit", "project storage quota exhausted", {
            maxStorageBytes: policy.limits.maxStorageBytes,
          });
        }

        yield* Effect.try({
          try: () =>
            store.stageGeneration({
              sourceGenerationId,
              repositoryId: request.repositoryId,
              project: request.project,
              projectRevision: request.projectRevision,
              sourceRevision: request.sourceRevision,
              providerRevision,
              policyDigest: config.policyFile.policyDigest,
            }),
          catch: (error) => serviceFailure("stage generation", error),
        });
        const acquired = yield* Effect.tryPromise({
          try: () =>
            acquireGitSource({
              source,
              destination: path.join(generationsRoot, sourceGenerationId),
              limits: policy.limits,
              secretsDir,
            }),
          catch: (error) => serviceFailure("source acquisition", error),
        }).pipe(
          Effect.tapError((error) =>
            Effect.try({
              try: () => store.failGeneration(sourceGenerationId, error.message),
              catch: () => undefined,
            }).pipe(Effect.ignore),
          ),
        );
        if (acquired.resolvedRevision !== resolution) {
          yield* Effect.try({
            try: () =>
              store.failGeneration(
                sourceGenerationId,
                "resolved revision changed during acquisition",
              ),
            catch: (error) => serviceFailure("fail generation", error),
          });
          return yield* brokerError(
            "project_source.conflict",
            "upstream moved while the source generation was acquired",
          );
        }
        const generation = yield* Effect.try({
          try: () =>
            store.completeGeneration(sourceGenerationId, {
              resolvedRevision: acquired.resolvedRevision,
              adapterRevision: ADAPTER_REVISION,
            }),
          catch: (error) => serviceFailure("complete generation", error),
        });
        return {
          sourceGeneration: generation.sourceGenerationId,
          resolvedRevision: generation.resolvedRevision,
          adapterRevision: generation.adapterRevision,
        };
      }),
      mutation,
    );

  const requireReadyGeneration = (
    request: ActivateTaskRunRequest,
  ): Effect.Effect<SourceGenerationRecord, BrokerError> =>
    Effect.gen(function* () {
      const policy = yield* requirePolicy();
      if (
        request.project === undefined ||
        request.projectRevision === undefined ||
        request.sourceGeneration === undefined
      ) {
        return yield* brokerError(
          "run_activation.conflict",
          "broker-project task run is missing Project source identity",
        );
      }
      const generation = yield* Effect.try({
        try: () => store.getGeneration(request.sourceGeneration as string),
        catch: (error) => serviceFailure("generation lookup", error),
      });
      if (generation === null || generation.state !== "ready") {
        return yield* brokerError("project_source.stale", "source generation is not ready", {
          sourceGeneration: request.sourceGeneration,
        });
      }
      if (
        generation.project !== request.project ||
        generation.projectRevision !== request.projectRevision ||
        generation.policyDigest !== config.policyFile.policyDigest ||
        generation.providerRevision !== policy.providerRevisions[policy.provider] ||
        policy.sourceRevisions[generation.repositoryId] !== generation.sourceRevision
      ) {
        return yield* brokerError(
          "project_source.stale",
          "source generation provenance no longer matches the active policy",
        );
      }
      return generation;
    });

  const ensureMaterialized = (
    request: ActivateTaskRunRequest,
    workspacePath: string,
    leaseFencingToken: number,
  ): Effect.Effect<MaterializationRecord, BrokerError> =>
    TSemaphore.withPermit(
      Effect.gen(function* () {
        const policy = yield* requirePolicy();
        const generation = yield* requireReadyGeneration(request);
        const staged = yield* Effect.try({
          try: () =>
            store.stageMaterialization({
              sourceGenerationId: generation.sourceGenerationId,
              repositoryId: generation.repositoryId,
              project: generation.project,
              projectRevision: generation.projectRevision,
              taskId: request.taskId,
              runId: request.runId,
              environmentKey: request.environmentKey,
              workspaceId: request.workspaceId,
              workspaceLeaseId: request.workspaceLeaseId,
              leaseFencingToken,
              permission: request.permission,
              authorityFacts: {
                catalogueRevision: request.catalogueRevision,
                lane: request.lane,
                laneRevision: request.laneRevision,
                project: request.project,
                projectRevision: request.projectRevision,
                sourceGeneration: request.sourceGeneration,
                permission: request.permission,
                workspaceProvider: request.workspaceProvider,
                authorityClass: request.authorityClass,
                policyRevision: request.policyRevision,
              },
              policyDigest: config.policyFile.policyDigest,
            }),
          catch: (error) => serviceFailure("stage materialization", error),
        });
        if (staged.state === "ready") {
          return staged;
        }
        if (staged.state !== "staging" && staged.state !== "installing") {
          return yield* brokerError(
            "project_materialization.invalid_state",
            "task run materialization is terminal",
            { state: staged.state },
          );
        }

        const generationPath = path.join(generationsRoot, generation.sourceGenerationId);
        const workPlane = path.join(workspacePath, "work");
        const install = yield* Effect.tryPromise({
          try: async () => {
            const summary = await installGeneration(generationPath, workPlane, policy.limits);
            // The staged tree was cloned under the broker umask (0077).
            // Apply the effective Project permission uniformly: gateway-side
            // workers share the tree through the broker group, so a read-only
            // run must face EACCES on work-plane writes while the output
            // plane stays group-writable.
            await applyWorkPlanePermission(workPlane, request.permission);
            return summary;
          },
          catch: (error) => serviceFailure("workspace installation", error),
        }).pipe(
          Effect.tapError((error) =>
            Effect.try({
              try: () => store.failMaterialization(staged.materializationId, error.message),
              catch: () => undefined,
            }).pipe(Effect.ignore),
          ),
        );
        yield* Effect.try({
          try: () => {
            store.recordPhase(staged.materializationId, "validated", JSON.stringify(install));
            store.recordPhase(staged.materializationId, "installed");
            store.markMaterializationReady(
              staged.materializationId,
              install.entryCount,
              install.totalBytes,
            );
          },
          catch: (error) => serviceFailure("commit materialization", error),
        });
        return yield* Effect.try({
          try: () => store.getMaterialization(staged.materializationId),
          catch: (error) => serviceFailure("materialization lookup", error),
        });
      }),
      mutation,
    );

  const recordResult = (
    environmentKey: string,
    taskId: string,
    runId: string,
    workspacePath: string,
  ): Effect.Effect<ProjectResultRecord | null, BrokerError> =>
    Effect.gen(function* () {
      const materialization = yield* Effect.try({
        try: () => store.findMaterializationByRun(runId),
        catch: (error) => serviceFailure("materialization lookup", error),
      });
      if (materialization === null) return null;
      if (materialization.taskId !== taskId || materialization.environmentKey !== environmentKey) {
        return yield* brokerError(
          "project_materialization.conflict",
          "result task identity does not match the materialization",
        );
      }
      const paths = yield* Effect.tryPromise({
        try: () => changedPaths(path.join(workspacePath, "work"), MAX_RESULT_PATHS),
        catch: (error) => serviceFailure("result inspection", error),
      });
      const resultGeneration = generationIdFor({
        changedPaths: JSON.stringify(paths),
        materializationId: materialization.materializationId,
        sourceGenerationId: materialization.sourceGenerationId,
      });
      const result = yield* Effect.try({
        try: () =>
          store.recordResult({
            materializationId: materialization.materializationId,
            resultGeneration,
            changed: paths.length > 0,
            changedPaths: paths,
          }),
        catch: (error) => serviceFailure("record result", error),
      });
      yield* Effect.try({
        try: () => {
          store.recordPhase(materialization.materializationId, "released");
          store.markMaterializationReleased(materialization.materializationId);
        },
        catch: (error) => serviceFailure("release materialization", error),
      });
      return result;
    });

  const readResult = (
    taskId: string,
    runId: string,
  ): Effect.Effect<ProjectResultRecord | null, BrokerError> =>
    Effect.gen(function* () {
      const result = yield* Effect.try({
        try: () => store.findResultByRun(runId),
        catch: (error) => serviceFailure("result lookup", error),
      });
      if (result === null || result.state === "deleted") return null;
      if (result.taskId !== taskId) {
        return yield* brokerError(
          "project_materialization.conflict",
          "result task identity does not match the run",
        );
      }
      return result;
    });

  return { resolveSource, ensureMaterialized, recordResult, readResult } satisfies ProjectWorkspacesService;
});

export const ProjectWorkspacesLive = Layer.effect(ProjectWorkspaces, make);
