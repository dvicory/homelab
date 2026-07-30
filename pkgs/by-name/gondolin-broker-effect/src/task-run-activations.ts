import { randomUUID } from "node:crypto";
import { Context, Effect, Layer } from "effect";
import { BrokerConfig } from "./config.js";
import { BrokerDatabase } from "./database.js";
import type {
  ActivateTaskRunRequest,
  ConsumeTaskRunRequest,
  TaskRunAuthority,
  TaskRunIdentity,
} from "./domain.js";
import { Registry } from "./registry.js";
import { BrokerError, brokerError } from "./errors.js";
import { InputPreparations } from "./task-run-inputs/service.js";
export type TaskRunActivationState = "active" | "consumed" | "superseded";

export interface TaskRunActivationRecord {
  readonly activationId: string;
  readonly taskId: string;
  readonly runId: string;
  readonly environmentKey: string;
  readonly workspaceId: string;
  readonly workspaceLeaseId: string;
  readonly policyDigest: string;
  readonly authority: TaskRunAuthority;
  readonly state: TaskRunActivationState;
  readonly activatedAt: number;
  readonly consumedAt: number | null;
  readonly supersededAt: number | null;
}

export interface ActivationCloseReference {
  readonly environmentKey: string;
  readonly generation: number;
}

export interface TaskRunActivationResult {
  readonly activation: TaskRunActivationRecord;
  readonly generationsToClose: ReadonlyArray<ActivationCloseReference>;
}

export interface TaskRunConsumptionResult {
  readonly activation: TaskRunActivationRecord;
  readonly generationToClose: ActivationCloseReference | null;
}

export interface AtomicTaskRunConsumptionResult<A> extends TaskRunConsumptionResult {
  readonly result: A;
}

export interface TaskRunActivationsService {
  readonly activate: (
    request: ActivateTaskRunRequest,
  ) => Effect.Effect<TaskRunActivationResult, BrokerError>;
  readonly validate: (
    environmentKey: string,
    identity: TaskRunIdentity | undefined,
  ) => Effect.Effect<TaskRunActivationRecord | undefined, BrokerError>;
  readonly consumeAtomically: <A>(
    request: ConsumeTaskRunRequest,
    operation: (activation: TaskRunActivationRecord) => A,
  ) => Effect.Effect<AtomicTaskRunConsumptionResult<A>, BrokerError>;
  readonly consume: (
    request: ConsumeTaskRunRequest,
  ) => Effect.Effect<TaskRunConsumptionResult, BrokerError>;
}

export class TaskRunActivations extends Context.Tag("@agent-x/gondolin-broker-effect/TaskRunActivations")<
  TaskRunActivations,
  TaskRunActivationsService
>() {}

type ActivationRow = {
  activation_id: string;
  task_id: string;
  run_id: string;
  environment_key: string;
  workspace_id: string;
  workspace_lease_id: string;
  policy_digest: string;
  authority_facts: string | null;
  state: TaskRunActivationState;
  activated_at: number;
  consumed_at: number | null;
  superseded_at: number | null;
};

type EnvironmentRow = {
  environment_key: string;
  generation: number;
  run_activation_id: string | null;
  state: "creating" | "active" | "closing" | "closed" | "failed";
};

const authorityFromRequest = (
  request: ActivateTaskRunRequest,
  policyDigest: string,
): TaskRunAuthority => ({
  catalogueRevision: request.catalogueRevision,
  lane: request.lane,
  laneRevision: request.laneRevision,
  ...(request.project === undefined ? {} : { project: request.project }),
  ...(request.projectRevision === undefined ? {} : { projectRevision: request.projectRevision }),
  ...(request.sourceGeneration === undefined ? {} : { sourceGeneration: request.sourceGeneration }),
  permission: request.permission,
  workspaceProvider: request.workspaceProvider,
  authorityClass: request.authorityClass,
  policyRevision: request.policyRevision,
  policyDigest,
});

const authorityFromRow = (row: ActivationRow): TaskRunAuthority => {
  if (row.authority_facts === null) {
    throw brokerError("run_activation.stale", "task-run activation predates typed authority binding");
  }
  return JSON.parse(row.authority_facts) as TaskRunAuthority;
};

const fromRow = (row: ActivationRow): TaskRunActivationRecord => ({
  activationId: row.activation_id,
  taskId: row.task_id,
  runId: row.run_id,
  environmentKey: row.environment_key,
  workspaceId: row.workspace_id,
  workspaceLeaseId: row.workspace_lease_id,
  policyDigest: row.policy_digest,
  authority: authorityFromRow(row),
  state: row.state,
  activatedAt: row.activated_at,
  consumedAt: row.consumed_at,
  supersededAt: row.superseded_at,
});

const activationFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("registry.failed", `task-run activation ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  if (!config.workspaceHandoffEnabled) {
    const unavailable = <A>() =>
      Effect.fail<BrokerError>(brokerError("policy.denied", "workspace handoff is disabled")) as Effect.Effect<A, BrokerError>;
    return {
      activate: unavailable,
      validate: () => Effect.succeed(undefined),
      consumeAtomically: unavailable,
      consume: unavailable,
    } satisfies TaskRunActivationsService;
  }
  const database = yield* BrokerDatabase;
  yield* Registry;
  const inputPreparations = yield* InputPreparations;
  const db = database.connection;


  yield* Effect.try({
    try: () => database.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS task_run_activations (
          activation_id TEXT PRIMARY KEY CHECK (length(activation_id) = 36),
          task_id TEXT NOT NULL,
          run_id TEXT NOT NULL UNIQUE,
          environment_key TEXT NOT NULL,
          workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
          workspace_lease_id TEXT NOT NULL REFERENCES workspace_leases(lease_id),
          policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
          authority_facts TEXT,
          state TEXT NOT NULL CHECK (state IN ('active','consumed','superseded')),
          activated_at INTEGER NOT NULL,
          consumed_at INTEGER,
          superseded_at INTEGER
        ) STRICT;
        CREATE UNIQUE INDEX IF NOT EXISTS task_run_activations_one_active_task
          ON task_run_activations(task_id) WHERE state = 'active';
        CREATE UNIQUE INDEX IF NOT EXISTS task_run_activations_one_active_environment
          ON task_run_activations(environment_key) WHERE state = 'active';
        CREATE UNIQUE INDEX IF NOT EXISTS task_run_activations_one_active_workspace
          ON task_run_activations(workspace_id) WHERE state = 'active';
        CREATE INDEX IF NOT EXISTS task_run_activations_environment_time
          ON task_run_activations(environment_key, activated_at DESC);
      `);
      const columns = db.prepare(
        "SELECT name FROM pragma_table_info('task_run_activations')",
      ).all() as ReadonlyArray<{ readonly name: string }>;
      if (!columns.some(({ name }) => name === "authority_facts")) {
        db.exec("ALTER TABLE task_run_activations ADD COLUMN authority_facts TEXT");
      }
      db.prepare(`
        UPDATE task_run_activations
        SET state='superseded', superseded_at=COALESCE(superseded_at, ?)
        WHERE state='active' AND authority_facts IS NULL
      `).run(Date.now());
      db.prepare(`
        UPDATE task_run_activations
        SET state='superseded', superseded_at=COALESCE(superseded_at, ?)
        WHERE state='active' AND policy_digest<>?
      `).run(Date.now(), config.policyFile.policyDigest);
    }),
    catch: (error) => activationFailure("schema initialization", error),
  });

  const byRun = db.prepare("SELECT * FROM task_run_activations WHERE run_id = ?");
  const latestForEnvironment = db.prepare(
    "SELECT * FROM task_run_activations WHERE environment_key = ? ORDER BY activated_at DESC, rowid DESC LIMIT 1",
  );
  const environmentForActivation = db.prepare(`
    SELECT environment_key, generation, state, run_activation_id FROM environments
    WHERE environment_key = ? AND workspace_id = ? AND workspace_lease_id = ?
  `);

  const closeReference = (
    environmentKey: string,
    workspaceId: string,
    workspaceLeaseId: string,
    preserveActivationId?: string,
  ): ActivationCloseReference | null => {
    const environment = environmentForActivation.get(
      environmentKey,
      workspaceId,
      workspaceLeaseId,
    ) as EnvironmentRow | undefined;
    if (environment === undefined || environment.state === "closed" || environment.state === "failed") return null;
    if (environment.run_activation_id === preserveActivationId) return null;
    if (environment.state !== "closing") {
      db.prepare(`
        UPDATE environments SET state='closing', updated_at=?
        WHERE environment_key=? AND generation=?
      `).run(Date.now(), environment.environment_key, environment.generation);
    }
    return { environmentKey: environment.environment_key, generation: environment.generation };
  };

  const activate = (
    request: ActivateTaskRunRequest,
  ): Effect.Effect<TaskRunActivationResult, BrokerError> =>
    inputPreparations.validateActivation(request).pipe(
      Effect.andThen(Effect.try({
        try: () => database.transaction(() => {
        if (!(request.authorityClass in config.policyFile.worklanes)) {
          throw brokerError("run_activation.conflict", "task-run authority class is not configured", {
            authorityClass: request.authorityClass,
          });
        }
        const laneAuthority = config.policyFile.laneAuthorities[request.lane];
        if (laneAuthority === undefined) {
          throw brokerError("run_activation.conflict", "task-run lane is not configured", {
            lane: request.lane,
          });
        }
        if (
          laneAuthority.authorityClass !== request.authorityClass ||
          laneAuthority.workspaceProvider !== request.workspaceProvider ||
          (
            request.permission === "workspace-write" &&
            laneAuthority.maximumPermission !== "workspace-write"
          )
        ) {
          throw brokerError(
            "run_activation.conflict",
            "task-run authority exceeds the immutable lane policy",
          );
        }
        const hasProject = request.project !== undefined;
        const hasProjectSource =
          request.projectRevision !== undefined && request.sourceGeneration !== undefined;
        if (hasProject !== hasProjectSource) {
          throw brokerError(
            "run_activation.conflict",
            "task-run Project source identity is incomplete",
          );
        }
        if (request.workspaceProvider === "broker-project") {
          if (!hasProject) {
            throw brokerError(
              "run_activation.conflict",
              "broker-project task run is missing Project source identity",
            );
          }
          if (config.policyFile.projectWorkspace === undefined) {
            throw brokerError(
              "policy.indeterminate",
              "broker-project provider is not configured",
            );
          }
          // Execution begins only after the Project materialization for this
          // run is durably ready and bound to the same workspace lease.
          const materialization = db.prepare(
            "SELECT workspace_id, workspace_lease_id, source_generation_id, project, project_revision, permission, state FROM project_materializations WHERE run_id = ? ORDER BY created_at DESC LIMIT 1",
          ).get(request.runId) as {
            workspace_id: string;
            workspace_lease_id: string;
            source_generation_id: string;
            project: string;
            project_revision: string;
            permission: string;
            state: string;
          } | undefined;
          if (
            materialization === undefined ||
            materialization.state !== "ready" ||
            materialization.workspace_id !== request.workspaceId ||
            materialization.workspace_lease_id !== request.workspaceLeaseId ||
            materialization.source_generation_id !== request.sourceGeneration ||
            materialization.project !== request.project ||
            materialization.project_revision !== request.projectRevision ||
            materialization.permission !== request.permission
          ) {
            throw brokerError(
              "run_activation.conflict",
              "task run has no ready Project materialization bound to this workspace lease",
            );
          }
        } else if (hasProject) {
          throw brokerError(
            "run_activation.conflict",
            "Project authority requires the broker-project provider",
          );
        }
        const workspace = db.prepare(`
          SELECT
            wl.workspace_id,
            wl.environment_key,
            wl.state AS lease_state,
            w.owner_environment_key,
            w.state AS workspace_state
          FROM workspace_leases wl
          JOIN workspaces w ON w.workspace_id = wl.workspace_id
          WHERE wl.lease_id = ?
        `).get(request.workspaceLeaseId) as {
          workspace_id: string;
          environment_key: string;
          lease_state: "active" | "released";
          owner_environment_key: string;
          workspace_state: "active" | "closed" | "deleted";
        } | undefined;
        if (
          workspace === undefined ||
          workspace.workspace_id !== request.workspaceId ||
          workspace.environment_key !== request.environmentKey ||
          workspace.owner_environment_key !== request.environmentKey ||
          workspace.lease_state !== "active" ||
          workspace.workspace_state !== "active"
        ) {
          throw brokerError(
            "run_activation.conflict",
            "task run does not hold the active private workspace lease",
          );
        }

        const existingAuthority = db.prepare(
          "SELECT * FROM authority_bindings WHERE environment_key = ?",
        ).get(request.environmentKey) as {
          profile: string;
          executor: string;
          authority_class: string;
          policy_digest: string;
          workspace_id: string;
          workspace_lease_id: string;
        } | undefined;
        if (
          existingAuthority !== undefined &&
          (
            existingAuthority.profile !== config.profile ||
            existingAuthority.executor !== config.policyFile.defaultExecutor ||
            existingAuthority.authority_class !== request.authorityClass ||
            existingAuthority.workspace_id !== request.workspaceId ||
            existingAuthority.workspace_lease_id !== request.workspaceLeaseId
          )
        ) {
          throw brokerError(
            "run_activation.conflict",
            "environment authority is already bound to different task-run facts",
          );
        }
        const now = Date.now();
        if (existingAuthority === undefined) {
          db.prepare(`
            INSERT INTO authority_bindings (
              environment_key, profile, executor, authority_class, policy_digest,
              workspace_id, workspace_lease_id, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          `).run(
            request.environmentKey,
            config.profile,
            config.policyFile.defaultExecutor,
            request.authorityClass,
            config.policyFile.policyDigest,
            request.workspaceId,
            request.workspaceLeaseId,
            now,
            now,
          );
        } else if (existingAuthority.policy_digest !== config.policyFile.policyDigest) {
          db.prepare(`
            UPDATE authority_bindings SET policy_digest=?, updated_at=?
            WHERE environment_key=?
          `).run(config.policyFile.policyDigest, now, request.environmentKey);
        }

        const priorRun = byRun.get(request.runId) as ActivationRow | undefined;
        if (priorRun !== undefined) {
          if (
            priorRun.task_id !== request.taskId ||
            priorRun.environment_key !== request.environmentKey ||
            priorRun.workspace_id !== request.workspaceId ||
            priorRun.workspace_lease_id !== request.workspaceLeaseId ||
            priorRun.policy_digest !== config.policyFile.policyDigest ||
            JSON.stringify(authorityFromRow(priorRun)) !==
              JSON.stringify(authorityFromRequest(request, config.policyFile.policyDigest))
          ) {
            throw brokerError("run_activation.conflict", "Kanban run is already bound to different activation facts");
          }
          if (priorRun.state !== "active") {
            throw brokerError("run_activation.stale", "task-run activation is no longer active", {
              taskId: request.taskId,
              runId: request.runId,
              state: priorRun.state,
            });
          }
          const generationToClose = closeReference(
            priorRun.environment_key,
            priorRun.workspace_id,
            priorRun.workspace_lease_id,
            priorRun.activation_id,
          );
          return {
            activation: fromRow(priorRun),
            generationsToClose: generationToClose === null ? [] : [generationToClose],
          };
        }

        const taskWorkspace = db.prepare(`
          SELECT workspace_id FROM task_run_activations WHERE task_id = ? ORDER BY activated_at DESC, rowid DESC LIMIT 1
        `).get(request.taskId) as { workspace_id: string } | undefined;
        if (taskWorkspace !== undefined && taskWorkspace.workspace_id !== request.workspaceId) {
          throw brokerError("run_activation.conflict", "task is already bound to a different private workspace");
        }
        const workspaceTask = db.prepare(`
          SELECT task_id FROM task_run_activations WHERE workspace_id = ? ORDER BY activated_at DESC LIMIT 1
        `).get(request.workspaceId) as { task_id: string } | undefined;
        if (workspaceTask !== undefined && workspaceTask.task_id !== request.taskId) {
          throw brokerError("run_activation.conflict", "private workspace is already bound to a different task");
        }

        const activeRows = db.prepare(`
          SELECT * FROM task_run_activations
          WHERE state='active' AND (task_id=? OR environment_key=? OR workspace_id=?)
        `).all(request.taskId, request.environmentKey, request.workspaceId) as unknown as ActivationRow[];
        db.prepare(`
          UPDATE task_run_activations SET state='superseded', superseded_at=?
          WHERE state='active' AND (task_id=? OR environment_key=? OR workspace_id=?)
        `).run(now, request.taskId, request.environmentKey, request.workspaceId);

        const closeReferences = new Map<string, ActivationCloseReference>();
        for (const active of activeRows) {
          const reference = closeReference(active.environment_key, active.workspace_id, active.workspace_lease_id);
          if (reference !== null) closeReferences.set(`${reference.environmentKey}:${reference.generation}`, reference);
        }
        const currentReference = closeReference(
          request.environmentKey,
          request.workspaceId,
          request.workspaceLeaseId,
        );
        if (currentReference !== null) {
          closeReferences.set(`${currentReference.environmentKey}:${currentReference.generation}`, currentReference);
        }

        const activationId = randomUUID();
        db.prepare(`
          INSERT INTO task_run_activations (
            activation_id, task_id, run_id, environment_key, workspace_id, workspace_lease_id,
            policy_digest, authority_facts, state, activated_at, consumed_at, superseded_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, NULL, NULL)
        `).run(
          activationId,
          request.taskId,
          request.runId,
          request.environmentKey,
          request.workspaceId,
          request.workspaceLeaseId,
          config.policyFile.policyDigest,
          JSON.stringify(authorityFromRequest(request, config.policyFile.policyDigest)),
          now,
        );
        return {
          activation: fromRow(byRun.get(request.runId) as ActivationRow),
          generationsToClose: [...closeReferences.values()],
        };
        }),
        catch: (error) => activationFailure("activation", error),
      })),
    );

  const validate = (
    environmentKey: string,
    identity: TaskRunIdentity | undefined,
  ): Effect.Effect<TaskRunActivationRecord | undefined, BrokerError> =>
    Effect.try({
      try: () => {
        const row = latestForEnvironment.get(environmentKey) as ActivationRow | undefined;
        if (row === undefined) {
          if (identity === undefined) return undefined;
          throw brokerError("run_activation.not_found", "workspace environment has no activated task run", {
            environmentKey,
          });
        }
        if (identity === undefined || row.task_id !== identity.taskId || row.run_id !== identity.runId) {
          throw brokerError("run_activation.stale", "request does not carry the active task-run identity", {
            environmentKey,
          });
        }
        if (row.state !== "active") {
          throw brokerError("run_activation.stale", "task-run activation is no longer active", {
            environmentKey,
            state: row.state,
          });
        }
        if (row.policy_digest !== config.policyFile.policyDigest) {
          throw brokerError("run_activation.stale", "task-run activation policy is no longer active", {
            environmentKey,
          });
        }
        const binding = db.prepare(`
          SELECT ab.workspace_id, ab.workspace_lease_id, ab.policy_digest, wl.state AS lease_state
          FROM authority_bindings ab
          JOIN workspace_leases wl ON wl.lease_id = ab.workspace_lease_id
          WHERE ab.environment_key = ?
        `).get(environmentKey) as {
          workspace_id: string;
          workspace_lease_id: string;
          policy_digest: string;
          lease_state: "active" | "released";
        } | undefined;
        if (
          binding === undefined ||
          binding.workspace_id !== row.workspace_id ||
          binding.workspace_lease_id !== row.workspace_lease_id ||
          binding.policy_digest !== row.policy_digest ||
          binding.lease_state !== "active"
        ) {
          throw brokerError("run_activation.stale", "task run no longer matches active workspace authority", {
            environmentKey,
          });
        }
        return fromRow(row);
      },
      catch: (error) => activationFailure("validation", error),
    });

  const consumeAtomically = <A>(
    request: ConsumeTaskRunRequest,
    operation: (activation: TaskRunActivationRecord) => A,
  ): Effect.Effect<AtomicTaskRunConsumptionResult<A>, BrokerError> =>
    Effect.try({
      try: () => database.transaction(() => {
        const row = byRun.get(request.runId) as ActivationRow | undefined;
        if (row === undefined) {
          throw brokerError("run_activation.not_found", "task-run activation does not exist", {
            taskId: request.taskId,
            runId: request.runId,
          });
        }
        if (row.task_id !== request.taskId || row.environment_key !== request.environmentKey) {
          throw brokerError("run_activation.conflict", "task-run identity does not match the activated run");
        }
        if (row.state === "superseded") {
          throw brokerError("run_activation.stale", "task run was superseded by a newer activation");
        }
        const result = operation(fromRow(row));
        if (row.state === "active") {
          const now = Date.now();
          db.prepare(`
            UPDATE task_run_activations SET state='consumed', consumed_at=?
            WHERE activation_id=? AND state='active'
          `).run(now, row.activation_id);
        }
        const generationToClose = closeReference(row.environment_key, row.workspace_id, row.workspace_lease_id);
        return {
          activation: fromRow(byRun.get(request.runId) as ActivationRow),
          generationToClose,
          result,
        };
      }),
      catch: (error) => activationFailure("consumption", error),
    });

  const consume = (
    request: ConsumeTaskRunRequest,
  ): Effect.Effect<TaskRunConsumptionResult, BrokerError> =>
    consumeAtomically(request, () => undefined).pipe(
      Effect.map(({ activation, generationToClose }) => ({ activation, generationToClose })),
    );

  return { activate, validate, consumeAtomically, consume } satisfies TaskRunActivationsService;
});

export const TaskRunActivationsLive = Layer.effect(TaskRunActivations, make);
