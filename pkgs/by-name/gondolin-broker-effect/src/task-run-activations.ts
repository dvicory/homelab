import { randomUUID } from "node:crypto";
import { Context, Effect, Layer } from "effect";
import { BrokerConfig } from "./config.js";
import { BrokerDatabase } from "./database.js";
import type {
  ActivateTaskRunRequest,
  ConsumeTaskRunRequest,
  TaskRunIdentity,
} from "./domain.js";
import { BrokerError, brokerError } from "./errors.js";
import { Registry } from "./registry.js";

export type TaskRunActivationState = "active" | "consumed" | "superseded";

export interface TaskRunActivationRecord {
  readonly activationId: string;
  readonly taskId: string;
  readonly runId: string;
  readonly environmentKey: string;
  readonly workspaceId: string;
  readonly workspaceLeaseId: string;
  readonly policyDigest: string;
  readonly epoch: number;
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

export interface TaskRunActivationsService {
  readonly activate: (
    request: ActivateTaskRunRequest,
  ) => Effect.Effect<TaskRunActivationResult, BrokerError>;
  readonly validate: (
    environmentKey: string,
    identity: TaskRunIdentity | undefined,
  ) => Effect.Effect<TaskRunActivationRecord | undefined, BrokerError>;
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
  epoch: number;
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

const fromRow = (row: ActivationRow): TaskRunActivationRecord => ({
  activationId: row.activation_id,
  taskId: row.task_id,
  runId: row.run_id,
  environmentKey: row.environment_key,
  workspaceId: row.workspace_id,
  workspaceLeaseId: row.workspace_lease_id,
  policyDigest: row.policy_digest,
  epoch: row.epoch,
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
  const database = yield* BrokerDatabase;
  yield* Registry;
  const db = database.connection;


  yield* Effect.try({
    try: () => database.transaction(() => db.exec(`
      CREATE TABLE IF NOT EXISTS task_run_activations (
        activation_id TEXT PRIMARY KEY CHECK (length(activation_id) = 36),
        task_id TEXT NOT NULL,
        run_id TEXT NOT NULL UNIQUE,
        environment_key TEXT NOT NULL,
        workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
        workspace_lease_id TEXT NOT NULL REFERENCES workspace_leases(lease_id),
        policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
        epoch INTEGER NOT NULL CHECK (epoch > 0),
        state TEXT NOT NULL CHECK (state IN ('active','consumed','superseded')),
        activated_at INTEGER NOT NULL,
        consumed_at INTEGER,
        superseded_at INTEGER,
        UNIQUE(task_id, epoch)
      ) STRICT;
      CREATE UNIQUE INDEX IF NOT EXISTS task_run_activations_one_active_task
        ON task_run_activations(task_id) WHERE state = 'active';
      CREATE UNIQUE INDEX IF NOT EXISTS task_run_activations_one_active_environment
        ON task_run_activations(environment_key) WHERE state = 'active';
      CREATE UNIQUE INDEX IF NOT EXISTS task_run_activations_one_active_workspace
        ON task_run_activations(workspace_id) WHERE state = 'active';
      CREATE INDEX IF NOT EXISTS task_run_activations_environment_epoch
        ON task_run_activations(environment_key, epoch DESC);
    `)),
    catch: (error) => activationFailure("schema initialization", error),
  });

  const byRun = db.prepare("SELECT * FROM task_run_activations WHERE run_id = ?");
  const latestForEnvironment = db.prepare(
    "SELECT * FROM task_run_activations WHERE environment_key = ? ORDER BY epoch DESC, activated_at DESC LIMIT 1",
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
    Effect.try({
      try: () => database.transaction(() => {
        if (request.policyDigest !== config.policyFile.policyDigest) {
          throw brokerError("run_activation.conflict", "task-run activation policy digest is not active", {
            activePolicyDigest: config.policyFile.policyDigest,
            requestedPolicyDigest: request.policyDigest,
          });
        }

        const binding = db.prepare(`
          SELECT ab.workspace_id, ab.workspace_lease_id, ab.policy_digest, wl.state AS lease_state
          FROM authority_bindings ab
          JOIN workspace_leases wl ON wl.lease_id = ab.workspace_lease_id
          WHERE ab.environment_key = ?
        `).get(request.environmentKey) as {
          workspace_id: string;
          workspace_lease_id: string;
          policy_digest: string;
          lease_state: "active" | "released";
        } | undefined;
        if (binding === undefined) {
          throw brokerError("run_activation.conflict", "task run has no broker authority binding", {
            environmentKey: request.environmentKey,
          });
        }
        if (
          binding.workspace_id !== request.workspaceId ||
          binding.workspace_lease_id !== request.workspaceLeaseId ||
          binding.policy_digest !== request.policyDigest ||
          binding.lease_state !== "active"
        ) {
          throw brokerError("run_activation.conflict", "task run does not match the active workspace authority");
        }

        const priorRun = byRun.get(request.runId) as ActivationRow | undefined;
        if (priorRun !== undefined) {
          if (
            priorRun.task_id !== request.taskId ||
            priorRun.environment_key !== request.environmentKey ||
            priorRun.workspace_id !== request.workspaceId ||
            priorRun.workspace_lease_id !== request.workspaceLeaseId ||
            priorRun.policy_digest !== request.policyDigest ||
            priorRun.epoch !== request.epoch
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
          SELECT workspace_id FROM task_run_activations WHERE task_id = ? ORDER BY epoch DESC LIMIT 1
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
        const maximum = db.prepare(`
          SELECT COALESCE(MAX(epoch), 0) AS epoch FROM task_run_activations WHERE task_id = ?
        `).get(request.taskId) as { epoch: number };
        if (request.epoch <= maximum.epoch) {
          throw brokerError("run_activation.stale", "activation epoch is not newer than the retained task epoch", {
            retainedEpoch: maximum.epoch,
            requestedEpoch: request.epoch,
          });
        }

        const activeRows = db.prepare(`
          SELECT * FROM task_run_activations
          WHERE state='active' AND (task_id=? OR environment_key=? OR workspace_id=?)
        `).all(request.taskId, request.environmentKey, request.workspaceId) as unknown as ActivationRow[];
        const now = Date.now();
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
            policy_digest, epoch, state, activated_at, consumed_at, superseded_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, NULL, NULL)
        `).run(
          activationId,
          request.taskId,
          request.runId,
          request.environmentKey,
          request.workspaceId,
          request.workspaceLeaseId,
          request.policyDigest,
          request.epoch,
          now,
        );
        return {
          activation: fromRow(byRun.get(request.runId) as ActivationRow),
          generationsToClose: [...closeReferences.values()],
        };
      }),
      catch: (error) => activationFailure("activation", error),
    });

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

  const consume = (
    request: ConsumeTaskRunRequest,
  ): Effect.Effect<TaskRunConsumptionResult, BrokerError> =>
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
        };
      }),
      catch: (error) => activationFailure("consumption", error),
    });

  return { activate, validate, consume } satisfies TaskRunActivationsService;
});

export const TaskRunActivationsLive = Layer.effect(TaskRunActivations, make);
