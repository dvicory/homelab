import { randomUUID } from "node:crypto";
import { Context, Effect, Layer } from "effect";
import { BrokerDatabase } from "../database.js";
import { BrokerError, brokerError } from "../errors.js";
import type {
  MaterializationPhase,
  MaterializationRecord,
  MaterializationState,
  ProjectResultRecord,
  SourceGenerationRecord,
  SourceGenerationState,
} from "./model.js";
import { initializeProjectWorkspaceSchema } from "./schema.js";

export interface StageGenerationInput {
  readonly sourceGenerationId: string;
  readonly repositoryId: string;
  readonly project: string;
  readonly projectRevision: string;
  readonly sourceRevision: string;
  readonly providerRevision: string;
  readonly policyDigest: string;
}

export interface CompleteGenerationInput {
  readonly resolvedRevision: string;
  readonly adapterRevision: string;
}

export interface StageMaterializationInput {
  readonly sourceGenerationId: string;
  readonly repositoryId: string;
  readonly project: string;
  readonly projectRevision: string;
  readonly taskId: string;
  readonly runId: string;
  readonly environmentKey: string;
  readonly workspaceId: string;
  readonly workspaceLeaseId: string;
  readonly leaseFencingToken: number;
  readonly permission: "read-only" | "workspace-write";
  readonly authorityFacts: Readonly<Record<string, unknown>>;
  readonly policyDigest: string;
}

export interface RecordResultInput {
  readonly materializationId: string;
  readonly resultGeneration: string;
  readonly changed: boolean;
  readonly changedPaths: ReadonlyArray<string>;
}

export interface ProjectWorkspaceStoreService {
  readonly stageGeneration: (input: StageGenerationInput) => SourceGenerationRecord;
  readonly getGeneration: (sourceGenerationId: string) => SourceGenerationRecord | null;
  readonly findReadyGeneration: (
    repositoryId: string,
    project: string,
    projectRevision: string,
    sourceRevision: string,
  ) => SourceGenerationRecord | null;
  readonly completeGeneration: (
    sourceGenerationId: string,
    input: CompleteGenerationInput,
  ) => SourceGenerationRecord;
  readonly failGeneration: (sourceGenerationId: string, reason: string) => SourceGenerationRecord;
  readonly stageMaterialization: (input: StageMaterializationInput) => MaterializationRecord;
  readonly getMaterialization: (materializationId: string) => MaterializationRecord;
  readonly findMaterializationByRun: (runId: string) => MaterializationRecord | null;
  readonly listMaterializations: (
    states?: ReadonlyArray<MaterializationState>,
  ) => ReadonlyArray<MaterializationRecord>;
  readonly markMaterializationInstalling: (materializationId: string) => MaterializationRecord;
  readonly markMaterializationReady: (
    materializationId: string,
    entryCount: number,
    totalBytes: number,
  ) => MaterializationRecord;
  readonly markMaterializationReleased: (materializationId: string) => MaterializationRecord;
  readonly failMaterialization: (materializationId: string, reason: string) => MaterializationRecord;
  readonly markMaterializationDeleted: (materializationId: string) => MaterializationRecord;
  readonly recordPhase: (
    materializationId: string,
    phase: MaterializationPhase,
    detail?: string,
  ) => void;
  readonly recordResult: (input: RecordResultInput) => ProjectResultRecord;
  readonly findResultByRun: (runId: string) => ProjectResultRecord | null;
  readonly listResults: (states?: ReadonlyArray<"recorded" | "deleted">) => ReadonlyArray<ProjectResultRecord>;
  readonly markResultDeleted: (resultId: string) => ProjectResultRecord;
  readonly sweepRetention: (retentionMs: number) => { readonly results: number; readonly materializations: number };
}

export class ProjectWorkspaceStore extends Context.Tag("@agent-x/gondolin-broker-effect/ProjectWorkspaceStore")<
  ProjectWorkspaceStore,
  ProjectWorkspaceStoreService
>() {}

type GenerationRow = {
  source_generation_id: string;
  repository_id: string;
  project: string;
  project_revision: string;
  source_revision: string;
  provider_revision: string;
  resolved_revision: string;
  adapter_revision: string;
  policy_digest: string;
  state: SourceGenerationState;
  failure_reason: string | null;
  created_at: number;
  updated_at: number;
};

type MaterializationRow = {
  materialization_id: string;
  source_generation_id: string;
  repository_id: string;
  project: string;
  project_revision: string;
  task_id: string;
  run_id: string;
  environment_key: string;
  workspace_id: string;
  workspace_lease_id: string;
  lease_fencing_token: number;
  permission: "read-only" | "workspace-write";
  authority_facts_json: string;
  policy_digest: string;
  state: MaterializationState;
  entry_count: number;
  total_bytes: number;
  failure_reason: string | null;
  created_at: number;
  updated_at: number;
  ready_at: number | null;
};

type ResultRow = {
  result_id: string;
  materialization_id: string;
  task_id: string;
  run_id: string;
  environment_key: string;
  workspace_id: string;
  project: string;
  project_revision: string;
  source_generation_id: string;
  result_generation: string;
  changed: 0 | 1;
  changed_paths_json: string;
  state: "recorded" | "deleted";
  created_at: number;
  deleted_at: number | null;
};

const decodeFacts = (value: string): Readonly<Record<string, unknown>> => {
  const decoded: unknown = JSON.parse(value);
  if (decoded === null || typeof decoded !== "object" || Array.isArray(decoded)) {
    throw brokerError("project_materialization.failed", "materialization authority facts are invalid");
  }
  return decoded as Readonly<Record<string, unknown>>;
};

const fromGeneration = (row: GenerationRow): SourceGenerationRecord => ({
  sourceGenerationId: row.source_generation_id,
  repositoryId: row.repository_id,
  project: row.project,
  projectRevision: row.project_revision,
  sourceRevision: row.source_revision,
  providerRevision: row.provider_revision,
  resolvedRevision: row.resolved_revision,
  adapterRevision: row.adapter_revision,
  policyDigest: row.policy_digest,
  state: row.state,
  failureReason: row.failure_reason,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

const fromMaterialization = (row: MaterializationRow): MaterializationRecord => ({
  materializationId: row.materialization_id,
  sourceGenerationId: row.source_generation_id,
  repositoryId: row.repository_id,
  project: row.project,
  projectRevision: row.project_revision,
  taskId: row.task_id,
  runId: row.run_id,
  environmentKey: row.environment_key,
  workspaceId: row.workspace_id,
  workspaceLeaseId: row.workspace_lease_id,
  leaseFencingToken: row.lease_fencing_token,
  permission: row.permission,
  authorityFacts: decodeFacts(row.authority_facts_json),
  policyDigest: row.policy_digest,
  state: row.state,
  entryCount: row.entry_count,
  totalBytes: row.total_bytes,
  failureReason: row.failure_reason,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
  readyAt: row.ready_at,
});

const fromResult = (row: ResultRow): ProjectResultRecord => ({
  resultId: row.result_id,
  materializationId: row.materialization_id,
  taskId: row.task_id,
  runId: row.run_id,
  environmentKey: row.environment_key,
  workspaceId: row.workspace_id,
  project: row.project,
  projectRevision: row.project_revision,
  sourceGenerationId: row.source_generation_id,
  resultGeneration: row.result_generation,
  changed: row.changed === 1,
  changedPaths: JSON.parse(row.changed_paths_json) as ReadonlyArray<string>,
  state: row.state,
  createdAt: row.created_at,
  deletedAt: row.deleted_at,
});

const storeFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("project_materialization.failed", `project workspace store ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const make = Effect.gen(function* () {
  const database = yield* BrokerDatabase;
  const db = database.connection;
  yield* Effect.try({
    try: () => initializeProjectWorkspaceSchema(database),
    catch: (error) => storeFailure("schema initialization", error),
  });

  const generationById = db.prepare(
    "SELECT * FROM project_source_generations WHERE source_generation_id = ?",
  );
  const requireGeneration = (id: string): GenerationRow => {
    const row = generationById.get(id) as GenerationRow | undefined;
    if (row === undefined) {
      throw brokerError("project_source.not_found", "project source generation does not exist", {
        sourceGenerationId: id,
      });
    }
    return row;
  };
  const materializationById = db.prepare(
    "SELECT * FROM project_materializations WHERE materialization_id = ?",
  );
  const requireMaterialization = (id: string): MaterializationRow => {
    const row = materializationById.get(id) as MaterializationRow | undefined;
    if (row === undefined) {
      throw brokerError("project_materialization.not_found", "project materialization does not exist", {
        materializationId: id,
      });
    }
    return row;
  };

  const stageGeneration = (input: StageGenerationInput): SourceGenerationRecord => {
    try {
      return database.transaction(() => {
        const prior = generationById.get(input.sourceGenerationId) as GenerationRow | undefined;
        if (prior !== undefined) {
          if (
            prior.repository_id !== input.repositoryId ||
            prior.project !== input.project ||
            prior.project_revision !== input.projectRevision ||
            prior.source_revision !== input.sourceRevision ||
            prior.provider_revision !== input.providerRevision ||
            prior.policy_digest !== input.policyDigest
          ) {
            throw brokerError(
              "project_source.conflict",
              "source generation ID is bound to different resolution facts",
            );
          }
          return fromGeneration(prior);
        }
        const now = Date.now();
        db.prepare(`
          INSERT INTO project_source_generations (
            source_generation_id, repository_id, project, project_revision, source_revision,
            provider_revision, resolved_revision, adapter_revision, policy_digest, state,
            failure_reason, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, '', '', ?, 'resolving', NULL, ?, ?)
        `).run(
          input.sourceGenerationId,
          input.repositoryId,
          input.project,
          input.projectRevision,
          input.sourceRevision,
          input.providerRevision,
          input.policyDigest,
          now,
          now,
        );
        return fromGeneration(requireGeneration(input.sourceGenerationId));
      });
    } catch (error) {
      throw storeFailure("stage generation", error);
    }
  };

  const completeGeneration = (
    sourceGenerationId: string,
    input: CompleteGenerationInput,
  ): SourceGenerationRecord => {
    try {
      return database.transaction(() => {
        const row = requireGeneration(sourceGenerationId);
        if (row.state === "ready") {
          if (row.resolved_revision !== input.resolvedRevision) {
            throw brokerError(
              "project_source.conflict",
              "ready source generation changed its resolved revision",
            );
          }
          return fromGeneration(row);
        }
        if (row.state !== "resolving") {
          throw brokerError("project_materialization.invalid_state", "source generation is terminal", {
            state: row.state,
          });
        }
        db.prepare(`
          UPDATE project_source_generations
          SET resolved_revision=?, adapter_revision=?, state='ready', updated_at=?
          WHERE source_generation_id=? AND state='resolving'
        `).run(input.resolvedRevision, input.adapterRevision, Date.now(), sourceGenerationId);
        return fromGeneration(requireGeneration(sourceGenerationId));
      });
    } catch (error) {
      throw storeFailure("complete generation", error);
    }
  };

  const failGeneration = (sourceGenerationId: string, reason: string): SourceGenerationRecord => {
    try {
      return database.transaction(() => {
        const row = requireGeneration(sourceGenerationId);
        if (row.state === "ready") return fromGeneration(row);
        db.prepare(`
          UPDATE project_source_generations
          SET state='failed', failure_reason=?, updated_at=?
          WHERE source_generation_id=? AND state='resolving'
        `).run(reason.slice(0, 1024), Date.now(), sourceGenerationId);
        return fromGeneration(requireGeneration(sourceGenerationId));
      });
    } catch (error) {
      throw storeFailure("fail generation", error);
    }
  };

  const stageMaterialization = (input: StageMaterializationInput): MaterializationRecord => {
    try {
      return database.transaction(() => {
        const prior = db.prepare(
          "SELECT * FROM project_materializations WHERE run_id = ? AND state NOT IN ('failed','deleted')",
        ).get(input.runId) as MaterializationRow | undefined;
        if (prior !== undefined) {
          if (
            prior.source_generation_id !== input.sourceGenerationId ||
            prior.task_id !== input.taskId ||
            prior.environment_key !== input.environmentKey ||
            prior.workspace_id !== input.workspaceId ||
            prior.workspace_lease_id !== input.workspaceLeaseId ||
            prior.lease_fencing_token !== input.leaseFencingToken ||
            prior.permission !== input.permission ||
            prior.policy_digest !== input.policyDigest ||
            JSON.stringify(decodeFacts(prior.authority_facts_json)) !==
              JSON.stringify(input.authorityFacts)
          ) {
            throw brokerError(
              "project_materialization.conflict",
              "task run is already bound to different materialization facts",
            );
          }
          return fromMaterialization(prior);
        }
        const generation = generationById.get(input.sourceGenerationId) as GenerationRow | undefined;
        if (generation === undefined || generation.state !== "ready") {
          throw brokerError("project_source.stale", "source generation is not ready", {
            sourceGenerationId: input.sourceGenerationId,
          });
        }
        const now = Date.now();
        const materializationId = randomUUID();
        db.prepare(`
          INSERT INTO project_materializations (
            materialization_id, source_generation_id, repository_id, project, project_revision,
            task_id, run_id, environment_key, workspace_id, workspace_lease_id,
            lease_fencing_token, permission, authority_facts_json, policy_digest, state,
            entry_count, total_bytes, failure_reason, created_at, updated_at, ready_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'staging', 0, 0, NULL, ?, ?, NULL)
        `).run(
          materializationId,
          input.sourceGenerationId,
          input.repositoryId,
          input.project,
          input.projectRevision,
          input.taskId,
          input.runId,
          input.environmentKey,
          input.workspaceId,
          input.workspaceLeaseId,
          input.leaseFencingToken,
          input.permission,
          JSON.stringify(input.authorityFacts),
          input.policyDigest,
          now,
          now,
        );
        db.prepare(`
          INSERT INTO project_materialization_journal (materialization_id, phase, detail, created_at)
          VALUES (?, 'staged', NULL, ?)
        `).run(materializationId, now);
        return fromMaterialization(requireMaterialization(materializationId));
      });
    } catch (error) {
      throw storeFailure("stage materialization", error);
    }
  };

  const transitionMaterialization = (
    materializationId: string,
    from: ReadonlyArray<MaterializationState>,
    to: MaterializationState,
    reason?: string,
    summary?: { readonly entryCount: number; readonly totalBytes: number },
  ): MaterializationRecord => {
    try {
      return database.transaction(() => {
        const row = requireMaterialization(materializationId);
        if (row.state === to && to !== "failed") {
          return fromMaterialization(row);
        }
        if (!from.includes(row.state)) {
          throw brokerError("project_materialization.invalid_state", "materialization transition is not allowed", {
            materializationId,
            state: row.state,
            transition: to,
          });
        }
        const now = Date.now();
        if (to === "ready") {
          db.prepare(`
            UPDATE project_materializations
            SET state='ready', entry_count=?, total_bytes=?, ready_at=?, updated_at=?
            WHERE materialization_id=?
          `).run(summary?.entryCount ?? row.entry_count, summary?.totalBytes ?? row.total_bytes, now, now, materializationId);
        } else if (to === "failed") {
          db.prepare(`
            UPDATE project_materializations
            SET state='failed', failure_reason=?, updated_at=?
            WHERE materialization_id=?
          `).run((reason ?? "materialization failed").slice(0, 1024), now, materializationId);
        } else {
          db.prepare(`
            UPDATE project_materializations SET state=?, updated_at=? WHERE materialization_id=?
          `).run(to, now, materializationId);
        }
        return fromMaterialization(requireMaterialization(materializationId));
      });
    } catch (error) {
      throw storeFailure(`transition materialization to ${to}`, error);
    }
  };

  const recordPhase = (
    materializationId: string,
    phase: MaterializationPhase,
    detail?: string,
  ): void => {
    try {
      database.transaction(() => {
        requireMaterialization(materializationId);
        if (detail !== undefined && detail.length > 4096) {
          throw brokerError("request.invalid", "materialization journal detail is too long");
        }
        db.prepare(`
          INSERT INTO project_materialization_journal (materialization_id, phase, detail, created_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(materialization_id, phase) DO NOTHING
        `).run(materializationId, phase, detail ?? null, Date.now());
      });
    } catch (error) {
      throw storeFailure("record materialization phase", error);
    }
  };

  const recordResult = (input: RecordResultInput): ProjectResultRecord => {
    try {
      return database.transaction(() => {
        const materialization = requireMaterialization(input.materializationId);
        const prior = db.prepare(
          "SELECT * FROM project_workspace_results WHERE materialization_id = ?",
        ).get(input.materializationId) as ResultRow | undefined;
        if (prior !== undefined) {
          if (prior.result_generation !== input.resultGeneration) {
            throw brokerError(
              "project_materialization.conflict",
              "materialization already has a different result generation",
            );
          }
          return fromResult(prior);
        }
        if (materialization.state !== "ready" && materialization.state !== "released") {
          throw brokerError(
            "project_materialization.invalid_state",
            "result requires a ready materialization",
            { state: materialization.state },
          );
        }
        if (input.changedPaths.length > 4096) {
          throw brokerError("request.invalid", "project result changed-path list is too large");
        }
        const now = Date.now();
        const resultId = randomUUID();
        db.prepare(`
          INSERT INTO project_workspace_results (
            result_id, materialization_id, task_id, run_id, environment_key, workspace_id,
            project, project_revision, source_generation_id, result_generation, changed,
            changed_paths_json, state, created_at, deleted_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'recorded', ?, NULL)
        `).run(
          resultId,
          input.materializationId,
          materialization.task_id,
          materialization.run_id,
          materialization.environment_key,
          materialization.workspace_id,
          materialization.project,
          materialization.project_revision,
          materialization.source_generation_id,
          input.resultGeneration,
          input.changed ? 1 : 0,
          JSON.stringify(input.changedPaths),
          now,
        );
        db.prepare(`
          INSERT INTO project_materialization_journal (materialization_id, phase, detail, created_at)
          VALUES (?, 'result_recorded', NULL, ?)
          ON CONFLICT(materialization_id, phase) DO NOTHING
        `).run(input.materializationId, now);
        return fromResult(
          db.prepare("SELECT * FROM project_workspace_results WHERE result_id = ?").get(resultId) as ResultRow,
        );
      });
    } catch (error) {
      throw storeFailure("record result", error);
    }
  };

  return {
    stageGeneration,
    getGeneration: (sourceGenerationId) => {
      try {
        const row = generationById.get(sourceGenerationId) as GenerationRow | undefined;
        return row === undefined ? null : fromGeneration(row);
      } catch (error) {
        throw storeFailure("get generation", error);
      }
    },
    findReadyGeneration: (repositoryId, project, projectRevision, sourceRevision) => {
      try {
        const row = db.prepare(`
          SELECT * FROM project_source_generations
          WHERE repository_id = ? AND project = ? AND project_revision = ? AND source_revision = ?
            AND state = 'ready'
          ORDER BY created_at DESC, rowid DESC LIMIT 1
        `).get(repositoryId, project, projectRevision, sourceRevision) as GenerationRow | undefined;
        return row === undefined ? null : fromGeneration(row);
      } catch (error) {
        throw storeFailure("find ready generation", error);
      }
    },
    completeGeneration,
    failGeneration,
    stageMaterialization,
    getMaterialization: (materializationId) => {
      try {
        return fromMaterialization(requireMaterialization(materializationId));
      } catch (error) {
        throw storeFailure("get materialization", error);
      }
    },
    findMaterializationByRun: (runId) => {
      try {
        const row = db.prepare(
          "SELECT * FROM project_materializations WHERE run_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        ).get(runId) as MaterializationRow | undefined;
        return row === undefined ? null : fromMaterialization(row);
      } catch (error) {
        throw storeFailure("find materialization", error);
      }
    },
    listMaterializations: (states) => {
      try {
        const rows = states === undefined || states.length === 0
          ? db.prepare("SELECT * FROM project_materializations ORDER BY created_at").all() as unknown as MaterializationRow[]
          : db.prepare(
            `SELECT * FROM project_materializations WHERE state IN (${states.map(() => "?").join(",")}) ORDER BY created_at`,
          ).all(...states) as unknown as MaterializationRow[];
        return rows.map(fromMaterialization);
      } catch (error) {
        throw storeFailure("list materializations", error);
      }
    },
    markMaterializationInstalling: (materializationId) =>
      transitionMaterialization(materializationId, ["staging"], "installing"),
    markMaterializationReady: (materializationId, entryCount, totalBytes) =>
      transitionMaterialization(materializationId, ["staging", "installing"], "ready", undefined, {
        entryCount,
        totalBytes,
      }),
    markMaterializationReleased: (materializationId) =>
      transitionMaterialization(materializationId, ["ready"], "released"),
    failMaterialization: (materializationId, reason) =>
      transitionMaterialization(materializationId, ["staging", "installing", "ready", "released"], "failed", reason),
    markMaterializationDeleted: (materializationId) =>
      transitionMaterialization(materializationId, ["ready", "released", "failed"], "deleted"),
    recordPhase,
    recordResult,
    findResultByRun: (runId) => {
      try {
        const row = db.prepare(
          "SELECT * FROM project_workspace_results WHERE run_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        ).get(runId) as ResultRow | undefined;
        return row === undefined ? null : fromResult(row);
      } catch (error) {
        throw storeFailure("find result", error);
      }
    },
    listResults: (states) => {
      try {
        const rows = states === undefined || states.length === 0
          ? db.prepare("SELECT * FROM project_workspace_results ORDER BY created_at").all() as unknown as ResultRow[]
          : db.prepare(
            `SELECT * FROM project_workspace_results WHERE state IN (${states.map(() => "?").join(",")}) ORDER BY created_at`,
          ).all(...states) as unknown as ResultRow[];
        return rows.map(fromResult);
      } catch (error) {
        throw storeFailure("list results", error);
      }
    },
    markResultDeleted: (resultId) => {
      try {
        return database.transaction(() => {
          db.prepare(`
            UPDATE project_workspace_results SET state='deleted', deleted_at=? WHERE result_id=?
          `).run(Date.now(), resultId);
          return fromResult(
            db.prepare("SELECT * FROM project_workspace_results WHERE result_id = ?").get(resultId) as ResultRow,
          );
        });
      } catch (error) {
        throw storeFailure("delete result", error);
      }
    },
    sweepRetention: (retentionMs) => {
      try {
        const cutoff = Date.now() - Math.max(0, retentionMs);
        const results = db.prepare(`
          UPDATE project_workspace_results SET state='deleted', deleted_at=?
          WHERE state='recorded' AND created_at < ?
        `).run(Date.now(), cutoff);
        // Materializations whose workspace row is gone (deleted or never
        // persisted) can no longer be consumed or released; mark them
        // deleted so generation/result bookkeeping stays accurate.
        const materializations = db.prepare(`
          UPDATE project_materializations SET state='deleted', updated_at=?
          WHERE state IN ('ready', 'released', 'failed')
          AND workspace_id NOT IN (SELECT workspace_id FROM workspaces WHERE state != 'deleted')
        `).run(Date.now());
        return { results: Number(results.changes), materializations: Number(materializations.changes) };
      } catch (error) {
        throw storeFailure("sweep retention", error);
      }
    },
  } satisfies ProjectWorkspaceStoreService;
});

export const ProjectWorkspaceStoreLive = Layer.effect(ProjectWorkspaceStore, make);
