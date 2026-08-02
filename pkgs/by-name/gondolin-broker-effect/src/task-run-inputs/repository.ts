import * as fs from "node:fs";
import * as path from "node:path";
import { randomUUID } from "node:crypto";
import { Context, Effect, Layer } from "effect";
import { BrokerConfig } from "../config.js";
import { BrokerDatabase } from "../database.js";
import { BrokerError, brokerError } from "../errors.js";
import type {
  InputPreparationLimits,
  PrepareTaskRunInputsRequest,
  TaskRunInput,
} from "./model.js";

export type InputPreparationState = "prepared" | "released";
export type HandoffReferenceState = "acquired" | "released";

export interface InputPreparationRecord {
  readonly preparationId: string;
  readonly environmentKey: string;
  readonly board: string;
  readonly taskId: string;
  readonly runId: string | number;
  readonly generation: number;
  readonly digest: string;
  readonly lane: string;
  readonly laneRevision: string;
  readonly policyRevision: string;
  readonly limits: InputPreparationLimits;
  readonly inputs: ReadonlyArray<TaskRunInput>;
  readonly state: InputPreparationState;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export type HandoffReclaimRecord = {
  readonly handoffId: string;
  readonly state: "staging" | "ready" | "quarantined" | "failed";
  readonly reclaimable: number;
};

export interface InputPreparationRepositoryService {
  readonly getById: (preparationId: string) => InputPreparationRecord | null;
  readonly getByRun: (taskId: string, runId: string | number) => InputPreparationRecord | null;
  readonly listByDestination: (environmentKey: string, taskId: string) => ReadonlyArray<InputPreparationRecord>;
  readonly create: (request: PrepareTaskRunInputsRequest, handoffIds?: ReadonlyArray<string>) => InputPreparationRecord;
  readonly acquireReferences: (preparationId: string, handoffIds: ReadonlyArray<string>) => void;
  readonly releaseReferences: (preparationId: string) => number;
  readonly hasAcquiredReference: (handoffId: string) => boolean;
  readonly deleteHandoff: (handoffId: string) => void;
  readonly markReclaimable: (handoffId: string) => HandoffReclaimRecord | null;
  readonly deleteReclaimableHandoff: (handoffId: string) => boolean;
};

export class InputPreparationRepository extends Context.Tag(
  "@agent-x/gondolin-broker-effect/InputPreparationRepository",
)<InputPreparationRepository, InputPreparationRepositoryService>() {}

type InputPreparationRow = {
  preparation_id: string;
  environment_key: string;
  board: string;
  task_id: string;
  run_id: string;
  generation: number;
  digest: string;
  lane: string;
  lane_revision: string;
  policy_revision: string;
  limits_json: string;
  inputs_json: string;
  state: InputPreparationState;
  created_at: number;
  updated_at: number;
};

const repositoryFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("registry.failed", `input preparation repository ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const stableJson = (value: unknown): string => JSON.stringify(value, (_key, nested) => {
  if (nested === null || typeof nested !== "object" || Array.isArray(nested)) return nested;
  return Object.fromEntries(Object.entries(nested).sort(([left], [right]) => left.localeCompare(right)));
});

const fromRow = (row: InputPreparationRow): InputPreparationRecord => ({
  preparationId: row.preparation_id,
  environmentKey: row.environment_key,
  board: row.board,
  taskId: row.task_id,
  runId: /^\d+$/.test(row.run_id) ? Number(row.run_id) : row.run_id,
  generation: row.generation,
  digest: row.digest,
  lane: row.lane,
  laneRevision: row.lane_revision,
  policyRevision: row.policy_revision,
  limits: JSON.parse(row.limits_json) as InputPreparationLimits,
  inputs: JSON.parse(row.inputs_json) as ReadonlyArray<TaskRunInput>,
  state: row.state,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  if (!config.workspaceHandoffEnabled) {
    const unavailable = (): never => {
      throw brokerError("policy.denied", "workspace handoff is disabled");
    };
    return {
      getById: unavailable,
      getByRun: unavailable,
      listByDestination: unavailable,
      create: unavailable,
      acquireReferences: unavailable,
      releaseReferences: unavailable,
      hasAcquiredReference: unavailable,
      deleteHandoff: unavailable,
      markReclaimable: unavailable,
      deleteReclaimableHandoff: unavailable,
    } satisfies InputPreparationRepositoryService;
  }
  const database = yield* BrokerDatabase;
  const db = database.connection;
  yield* Effect.try({
    try: () => database.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS input_preparations (
          preparation_id TEXT PRIMARY KEY,
          environment_key TEXT NOT NULL,
          board TEXT NOT NULL,
          task_id TEXT NOT NULL,
          run_id TEXT NOT NULL,
          generation INTEGER NOT NULL CHECK (generation > 0),
          digest TEXT NOT NULL CHECK (length(digest) = 64),
          lane TEXT NOT NULL,
          lane_revision TEXT NOT NULL,
          policy_revision TEXT NOT NULL,
          limits_json TEXT NOT NULL CHECK (json_valid(limits_json) AND json_type(limits_json) = 'object'),
          inputs_json TEXT NOT NULL CHECK (json_valid(inputs_json) AND json_type(inputs_json) = 'array'),
          state TEXT NOT NULL CHECK (state IN ('prepared','released')),
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          UNIQUE(environment_key, task_id, run_id)
        ) STRICT;
        CREATE UNIQUE INDEX IF NOT EXISTS input_preparations_one_task_run
          ON input_preparations(task_id, run_id);
        CREATE TABLE IF NOT EXISTS handoff_references (
          handoff_id TEXT NOT NULL REFERENCES workspace_handoffs(handoff_id),
          preparation_id TEXT NOT NULL REFERENCES input_preparations(preparation_id),
          state TEXT NOT NULL CHECK (state IN ('acquired','released')),
          acquired_at INTEGER NOT NULL,
          released_at INTEGER,
          PRIMARY KEY (handoff_id, preparation_id)
        ) STRICT;
        CREATE INDEX IF NOT EXISTS handoff_references_active
          ON handoff_references(handoff_id, state);
      `);
    }),
    catch: (error) => repositoryFailure("schema initialization", error),
  });

  const getById = (preparationId: string): InputPreparationRecord | null => {
    try {
      const row = db.prepare("SELECT * FROM input_preparations WHERE preparation_id = ?").get(preparationId) as InputPreparationRow | undefined;
      return row === undefined ? null : fromRow(row);
    } catch (error) {
      throw repositoryFailure("lookup", error);
    }
  };

  const getByRun = (taskId: string, runId: string | number): InputPreparationRecord | null => {
    try {
      const row = db.prepare(
        "SELECT * FROM input_preparations WHERE task_id = ? AND run_id = ?",
      ).get(taskId, String(runId)) as InputPreparationRow | undefined;
      return row === undefined ? null : fromRow(row);
    } catch (error) {
      throw repositoryFailure("run lookup", error);
    }
  };

  const listByDestination = (environmentKey: string, taskId: string): ReadonlyArray<InputPreparationRecord> => {
    try {
      return (db.prepare(
        "SELECT * FROM input_preparations WHERE environment_key = ? AND task_id = ? ORDER BY run_id",
      ).all(environmentKey, taskId) as InputPreparationRow[]).map(fromRow);
    } catch (error) {
      throw repositoryFailure("destination lookup", error);
    }
  };

  const create = (request: PrepareTaskRunInputsRequest, handoffIds: ReadonlyArray<string> = []): InputPreparationRecord => {
    try {
      return database.transaction(() => {
        const prior = getByRun(request.taskId, request.runId);
        if (prior !== null) return prior;
        const preparationId = `ip_${randomUUID().replaceAll("-", "")}`;
        const now = Date.now();
        db.prepare(`
          INSERT INTO input_preparations (
            preparation_id, environment_key, board, task_id, run_id, generation, digest,
            lane, lane_revision, policy_revision, limits_json, inputs_json, state, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', ?, ?)
        `).run(
          preparationId,
          request.environmentKey,
          request.board,
          request.taskId,
          String(request.runId),
          request.generation,
          request.digest,
          request.lane,
          request.laneRevision,
          request.policyRevision,
          stableJson(request.limits),
          stableJson(request.inputs),
          now,
          now,
        );
        const record = fromRow(db.prepare("SELECT * FROM input_preparations WHERE preparation_id = ?").get(preparationId) as InputPreparationRow);
        const referenceNow = Date.now();
        for (const handoffId of handoffIds) {
          db.prepare(`
            INSERT INTO handoff_references (handoff_id, preparation_id, state, acquired_at, released_at)
            VALUES (?, ?, 'acquired', ?, NULL)
          `).run(handoffId, preparationId, referenceNow);
        }
        return record;
      });
    } catch (error) {
      throw repositoryFailure("create", error);
    }
  };

  const acquireReferences = (preparationId: string, handoffIds: ReadonlyArray<string>): void => {
    try {
      database.transaction(() => {
        const now = Date.now();
        for (const handoffId of handoffIds) {
          db.prepare(`
            INSERT INTO handoff_references (handoff_id, preparation_id, state, acquired_at, released_at)
            VALUES (?, ?, 'acquired', ?, NULL)
            ON CONFLICT(handoff_id, preparation_id) DO UPDATE SET state='acquired', released_at=NULL
          `).run(handoffId, preparationId, now);
        }
      });
    } catch (error) {
      throw repositoryFailure("acquire references", error);
    }
  };

  const releaseReferences = (preparationId: string): number => {
    try {
      return database.transaction(() => {
        const countRow = db.prepare(
          "SELECT COUNT(*) AS count FROM handoff_references WHERE preparation_id=? AND state='acquired'",
        ).get(preparationId) as { count: number };
        const count = countRow.count;
        const now = Date.now();
        db.prepare(
          "UPDATE handoff_references SET state='released', released_at=? WHERE preparation_id=? AND state='acquired'",
        ).run(now, preparationId);
        db.prepare("UPDATE input_preparations SET state='released', updated_at=? WHERE preparation_id=?").run(now, preparationId);
        return count;
      });
    } catch (error) {
      throw repositoryFailure("release references", error);
    }
  };

  const hasAcquiredReference = (handoffId: string): boolean => {
    try {
      const row = db.prepare(
        "SELECT 1 AS present FROM handoff_references WHERE handoff_id = ? AND state='acquired' LIMIT 1",
      ).get(handoffId) as { present: number } | undefined;
      return row !== undefined;
    } catch (error) {
      throw repositoryFailure("reference lookup", error);
    }
  };


  const deleteHandoff = (handoffId: string): void => {
    try {
      database.transaction(() => {
        if (hasAcquiredReference(handoffId)) {
          throw brokerError("handoff.conflict", "workspace handoff is retained by an input preparation", { handoffId });
        }
        fs.rmSync(path.join(config.workspaceHandoffRoot, "ready", handoffId), { recursive: true, force: true });
        db.prepare("DELETE FROM workspace_handoff_finalization_journal WHERE handoff_id = ?").run(handoffId);
        db.prepare("DELETE FROM handoff_references WHERE handoff_id = ?").run(handoffId);
        db.prepare("DELETE FROM workspace_handoffs WHERE handoff_id = ?").run(handoffId);
      });
    } catch (error) {
      throw repositoryFailure("delete handoff", error);
    }
  };

  const markReclaimable = (handoffId: string): HandoffReclaimRecord | null => {
    try {
      return database.transaction(() => {
        const existing = db.prepare(
          "SELECT handoff_id, state, reclaimable FROM workspace_handoffs WHERE handoff_id=?",
        ).get(handoffId) as HandoffReclaimRecord | undefined;
        if (existing === undefined) return null;
        if (existing.state === "ready" && existing.reclaimable === 0) {
          db.prepare("UPDATE workspace_handoffs SET reclaimable=1, updated_at=? WHERE handoff_id=?").run(Date.now(), handoffId);
          return { ...existing, reclaimable: 1 };
        }
        return existing;
      });
    } catch (error) {
      throw repositoryFailure("mark handoff reclaimable", error);
    }
  };

  const deleteReclaimableHandoff = (handoffId: string): boolean => {
    try {
      return database.transaction(() => {
        const row = db.prepare(
          "SELECT state, reclaimable FROM workspace_handoffs WHERE handoff_id=?",
        ).get(handoffId) as { state: HandoffReclaimRecord["state"]; reclaimable: number } | undefined;
        if (row === undefined || row.state !== "ready" || row.reclaimable !== 1 || hasAcquiredReference(handoffId)) return false;
        deleteHandoff(handoffId);
        return true;
      });
    } catch (error) {
      throw repositoryFailure("delete reclaimable handoff", error);
    }
  };

  return {
    getById,
    getByRun,
    listByDestination,
    create,
    acquireReferences,
    releaseReferences,
    hasAcquiredReference,
    deleteHandoff,
    markReclaimable,
    deleteReclaimableHandoff,
  } satisfies InputPreparationRepositoryService;
});

export const InputPreparationRepositoryLive = Layer.effect(InputPreparationRepository, make);
