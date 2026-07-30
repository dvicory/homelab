import * as fs from "node:fs";
import * as path from "node:path";
import { randomUUID } from "node:crypto";
import { Context, Effect, Layer, Schema } from "effect";
import { BrokerConfig } from "../config.js";
import { BrokerDatabase } from "../database.js";
import { BrokerError, brokerError } from "../errors.js";
import { TaskRunActivations } from "../task-run-activations.js";
import {
  SelectedArtifacts,
  StageWorkspaceCapture,
  type StageWorkspaceCapture as StageCaptureRequest,
} from "./model.js";
import { initializeHandoffSchema } from "./schema.js";

export type HandoffState = "staging" | "ready" | "quarantined" | "failed";
export type FinalizationPhase =
  | "staged"
  | "fenced"
  | "vm_closed"
  | "copied"
  | "validated"
  | "installed"
  | "ready"
  | "quarantined"
  | "failed";

export interface HandoffRecord {
  readonly handoffId: string;
  readonly finalizationId: string;
  readonly sourceActivationId: string;
  readonly sourceTaskId: string;
  readonly sourceRunId: string;
  readonly sourceEnvironmentKey: string;
  readonly sourceWorkspaceId: string;
  readonly sourceWorkspaceLeaseId: string;
  readonly sourceLeaseFencingToken: number;
  readonly authorityFacts: Readonly<Record<string, unknown>>;
  readonly policyDigest: string;
  readonly policyDecisionDigest: string;
  readonly selectedArtifacts: ReadonlyArray<string>;
  readonly state: HandoffState;
  readonly entryCount: number;
  readonly totalBytes: number;
  readonly failureReason: string | null;
  readonly reclaimable: boolean;
}

export interface HandoffStoreService {
  readonly stageCapture: (request: StageCaptureRequest) => HandoffRecord;
  readonly findByFinalization: (finalizationId: string) => HandoffRecord | null;
  readonly getHandoff: (handoffId: string) => HandoffRecord;
  readonly listHandoffs: (states?: ReadonlyArray<HandoffState>) => ReadonlyArray<HandoffRecord>;
  readonly recordPhase: (
    handoffId: string,
    phase: FinalizationPhase,
    detail?: string,
  ) => void;
  readonly phases: (finalizationId: string) => ReadonlyArray<FinalizationPhase>;
  readonly markHandoffReady: (
    handoffId: string,
    entryCount: number,
    totalBytes: number,
  ) => HandoffRecord;
  readonly failHandoff: (
    handoffId: string,
    state: "quarantined" | "failed",
    reason: string,
  ) => HandoffRecord;
  readonly deleteHandoff: (handoffId: string) => void;
}

export class HandoffStore extends Context.Tag("@agent-x/gondolin-broker-effect/HandoffStore")<
  HandoffStore,
  HandoffStoreService
>() {}

type HandoffRow = {
  handoff_id: string;
  finalization_id: string;
  source_activation_id: string;
  source_task_id: string;
  source_run_id: string;
  source_environment_key: string;
  source_workspace_id: string;
  source_workspace_lease_id: string;
  source_lease_fencing_token: number;
  authority_facts_json: string;
  policy_digest: string;
  policy_decision_digest: string;
  selected_artifacts_json: string;
  state: HandoffState;
  entry_count: number;
  total_bytes: number;
  failure_reason: string | null;
  reclaimable: number;
};

type ActivationSource = {
  task_id: string;
  run_id: string;
  environment_key: string;
  workspace_id: string;
  workspace_lease_id: string;
  policy_digest: string;
  authority_facts: string;
  fencing_token: number;
};

const decodeCapture = Schema.decodeUnknownSync(StageWorkspaceCapture, { onExcessProperty: "error" });
const decodeSelectedArtifacts = Schema.decodeUnknownSync(SelectedArtifacts, { onExcessProperty: "error" });

const decodeObject = (value: string): Readonly<Record<string, unknown>> => {
  const decoded: unknown = JSON.parse(value);
  if (decoded === null || typeof decoded !== "object" || Array.isArray(decoded)) {
    throw brokerError("handoff.failed", "handoff authority facts are invalid");
  }
  return decoded as Readonly<Record<string, unknown>>;
};

const fromHandoff = (row: HandoffRow): HandoffRecord => ({
  handoffId: row.handoff_id,
  finalizationId: row.finalization_id,
  sourceActivationId: row.source_activation_id,
  sourceTaskId: row.source_task_id,
  sourceRunId: row.source_run_id,
  sourceEnvironmentKey: row.source_environment_key,
  sourceWorkspaceId: row.source_workspace_id,
  sourceWorkspaceLeaseId: row.source_workspace_lease_id,
  sourceLeaseFencingToken: row.source_lease_fencing_token,
  authorityFacts: decodeObject(row.authority_facts_json),
  policyDigest: row.policy_digest,
  policyDecisionDigest: row.policy_decision_digest,
  selectedArtifacts: decodeSelectedArtifacts(JSON.parse(row.selected_artifacts_json)),
  state: row.state,
  entryCount: row.entry_count,
  totalBytes: row.total_bytes,
  failureReason: row.failure_reason,
  reclaimable: row.reclaimable === 1,
});

const storeFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("handoff.failed", `handoff store ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const ensureSummary = (entryCount: number, totalBytes: number): void => {
  if ([entryCount, totalBytes].some((value) => !Number.isSafeInteger(value) || value < 0)) {
    throw brokerError("request.invalid", "handoff summary is invalid");
  }
};

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  if (!config.workspaceHandoffEnabled) {
    const unavailable = (): never => {
      throw brokerError("policy.denied", "workspace handoff is disabled");
    };
    return {
      stageCapture: unavailable,
      findByFinalization: unavailable,
      getHandoff: unavailable,
      listHandoffs: unavailable,
      recordPhase: unavailable,
      phases: unavailable,
      markHandoffReady: unavailable,
      failHandoff: unavailable,
      deleteHandoff: unavailable,
    } satisfies HandoffStoreService;
  }

  const database = yield* BrokerDatabase;
  yield* TaskRunActivations;
  const db = database.connection;
  yield* Effect.try({
    try: () => initializeHandoffSchema(database),
    catch: (error) => storeFailure("schema initialization", error),
  });

  const handoffById = db.prepare("SELECT * FROM workspace_handoffs WHERE handoff_id = ?");
  const handoffByFinalization = db.prepare(
    "SELECT * FROM workspace_handoffs WHERE finalization_id = ?",
  );
  const requireHandoff = (id: string): HandoffRow => {
    const row = handoffById.get(id) as HandoffRow | undefined;
    if (row === undefined) {
      throw brokerError("handoff.not_found", "workspace handoff does not exist", { handoffId: id });
    }
    return row;
  };

  const recordPhase = (
    handoffId: string,
    phase: FinalizationPhase,
    detail?: string,
  ): void => {
    try {
      database.transaction(() => {
        const row = requireHandoff(handoffId);
        if (detail !== undefined && detail.length > 4096) {
          throw brokerError("request.invalid", "handoff journal detail is too long");
        }
        db.prepare(`
          INSERT INTO workspace_handoff_finalization_journal
            (finalization_id, handoff_id, phase, detail, created_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(finalization_id, phase) DO NOTHING
        `).run(row.finalization_id, row.handoff_id, phase, detail ?? null, Date.now());
      });
    } catch (error) {
      throw storeFailure("record finalization phase", error);
    }
  };

  const stageCapture = (input: StageCaptureRequest): HandoffRecord => {
    try {
      return database.transaction(() => {
        const request = decodeCapture(input);
        const prior = handoffByFinalization.get(request.finalizationId) as HandoffRow | undefined;
        const selectedArtifactsJson = JSON.stringify(request.selectedArtifacts);
        if (prior !== undefined) {
          if (
            prior.source_activation_id !== request.sourceActivationId ||
            prior.policy_decision_digest !== request.policyDecisionDigest ||
            prior.selected_artifacts_json !== selectedArtifactsJson
          ) {
            throw brokerError("handoff.conflict", "finalization ID is bound to different capture facts");
          }
          return fromHandoff(prior);
        }
        const source = db.prepare(`
          SELECT a.task_id, a.run_id, a.environment_key, a.workspace_id, a.workspace_lease_id,
                 a.policy_digest, a.authority_facts, wl.fencing_token
          FROM task_run_activations a
          JOIN workspace_leases wl ON wl.lease_id = a.workspace_lease_id
          WHERE a.activation_id = ? AND a.state = 'active' AND wl.state = 'active'
        `).get(request.sourceActivationId) as ActivationSource | undefined;
        if (source === undefined || source.authority_facts === null) {
          throw brokerError("run_activation.not_found", "capture source activation is not active");
        }
        const existing = db.prepare(
          "SELECT handoff_id FROM workspace_handoffs WHERE source_activation_id = ?",
        ).get(request.sourceActivationId) as { handoff_id: string } | undefined;
        if (existing !== undefined) {
          throw brokerError("handoff.conflict", "source activation already has a workspace handoff", {
            handoffId: existing.handoff_id,
          });
        }
        decodeObject(source.authority_facts);
        const now = Date.now();
        const handoffId = randomUUID();
        db.prepare(`
          INSERT INTO workspace_handoffs (
            handoff_id, finalization_id, source_activation_id, source_task_id, source_run_id,
            source_environment_key, source_workspace_id, source_workspace_lease_id,
            source_lease_fencing_token, authority_facts_json, policy_digest,
            policy_decision_digest, selected_artifacts_json, state, entry_count, total_bytes,
            failure_reason, created_at, updated_at, ready_at, reclaimable
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'staging', 0, 0, NULL, ?, ?, NULL, 0)
        `).run(
          handoffId,
          request.finalizationId,
          request.sourceActivationId,
          source.task_id,
          source.run_id,
          source.environment_key,
          source.workspace_id,
          source.workspace_lease_id,
          source.fencing_token,
          source.authority_facts,
          source.policy_digest,
          request.policyDecisionDigest,
          selectedArtifactsJson,
          now,
          now,
        );
        db.prepare(`
          INSERT INTO workspace_handoff_finalization_journal
            (finalization_id, handoff_id, phase, detail, created_at)
          VALUES (?, ?, 'staged', NULL, ?)
        `).run(request.finalizationId, handoffId, now);
        return fromHandoff(requireHandoff(handoffId));
      });
    } catch (error) {
      throw storeFailure("stage capture", error);
    }
  };

  const findByFinalization = (finalizationId: string): HandoffRecord | null => {
    try {
      const row = handoffByFinalization.get(finalizationId) as HandoffRow | undefined;
      return row === undefined ? null : fromHandoff(row);
    } catch (error) {
      throw storeFailure("find capture", error);
    }
  };

  const getHandoff = (handoffId: string): HandoffRecord => {
    try {
      return fromHandoff(requireHandoff(handoffId));
    } catch (error) {
      throw storeFailure("get handoff", error);
    }
  };

  const listHandoffs = (states?: ReadonlyArray<HandoffState>): ReadonlyArray<HandoffRecord> => {
    try {
      if (states === undefined) {
        return (db.prepare("SELECT * FROM workspace_handoffs ORDER BY created_at, handoff_id").all() as HandoffRow[])
          .map(fromHandoff);
      }
      if (states.length === 0) return [];
      const allowed = new Set<HandoffState>(["staging", "ready", "quarantined", "failed"]);
      if (states.some((state) => !allowed.has(state))) {
        throw brokerError("request.invalid", "handoff state filter is invalid");
      }
      const placeholders = states.map(() => "?").join(", ");
      return (db.prepare(
        `SELECT * FROM workspace_handoffs WHERE state IN (${placeholders}) ORDER BY created_at, handoff_id`,
      ).all(...states) as HandoffRow[]).map(fromHandoff);
    } catch (error) {
      throw storeFailure("list handoffs", error);
    }
  };

  const phases = (finalizationId: string): ReadonlyArray<FinalizationPhase> => {
    try {
      return (db.prepare(`
        SELECT phase FROM workspace_handoff_finalization_journal
        WHERE finalization_id = ? ORDER BY journal_id
      `).all(finalizationId) as Array<{ phase: FinalizationPhase }>).map(({ phase }) => phase);
    } catch (error) {
      throw storeFailure("list finalization phases", error);
    }
  };

  const markHandoffReady = (
    handoffId: string,
    entryCount: number,
    totalBytes: number,
  ): HandoffRecord => {
    try {
      return database.transaction(() => {
        ensureSummary(entryCount, totalBytes);
        const row = requireHandoff(handoffId);
        if (row.state === "ready") {
          if (row.entry_count !== entryCount || row.total_bytes !== totalBytes) {
            throw brokerError("handoff.conflict", "ready handoff summary conflicts with committed state");
          }
          return fromHandoff(row);
        }
        if (row.state !== "staging") {
          throw brokerError("handoff.invalid_state", "only a staging handoff can become ready");
        }
        const now = Date.now();
        db.prepare(`
          UPDATE workspace_handoffs
          SET state='ready', entry_count=?, total_bytes=?, updated_at=?, ready_at=?
          WHERE handoff_id=?
        `).run(entryCount, totalBytes, now, now, handoffId);
        db.prepare(`
          INSERT INTO workspace_handoff_finalization_journal
            (finalization_id, handoff_id, phase, detail, created_at)
          VALUES (?, ?, 'ready', NULL, ?)
          ON CONFLICT(finalization_id, phase) DO NOTHING
        `).run(row.finalization_id, handoffId, now);
        return fromHandoff(requireHandoff(handoffId));
      });
    } catch (error) {
      throw storeFailure("mark handoff ready", error);
    }
  };

  const failHandoff = (
    handoffId: string,
    state: "quarantined" | "failed",
    reason: string,
  ): HandoffRecord => {
    try {
      return database.transaction(() => {
        if (reason.length === 0 || reason.length > 4096) {
          throw brokerError("request.invalid", "handoff failure reason is invalid");
        }
        const row = requireHandoff(handoffId);
        if (row.state === state && row.failure_reason === reason) return fromHandoff(row);
        if (row.state === "quarantined" || row.state === "failed") {
          throw brokerError("handoff.invalid_state", "handoff is already terminal");
        }
        if (row.state === "ready" && state === "failed") {
          throw brokerError("handoff.invalid_state", "a ready handoff can only be quarantined");
        }
        const now = Date.now();
        db.prepare(`
          UPDATE workspace_handoffs
          SET state=?, failure_reason=?, updated_at=?, ready_at=NULL WHERE handoff_id=?
        `).run(state, reason, now, handoffId);
        db.prepare(`
          INSERT INTO workspace_handoff_finalization_journal
            (finalization_id, handoff_id, phase, detail, created_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(finalization_id, phase) DO NOTHING
        `).run(row.finalization_id, handoffId, state, reason, now);
        return fromHandoff(requireHandoff(handoffId));
      });
    } catch (error) {
      throw storeFailure(`mark handoff ${state}`, error);
    }
  };
  const deleteHandoff = (handoffId: string): void => {
    try {
      database.transaction(() => {
        const reference = db.prepare(
          "SELECT 1 AS present FROM handoff_references WHERE handoff_id = ? AND state='acquired' LIMIT 1",
        ).get(handoffId) as { present: number } | undefined;
        if (reference !== undefined) {
          throw brokerError("handoff.conflict", "workspace handoff is retained by an input preparation", { handoffId });
        }
        fs.rmSync(path.join(config.workspaceHandoffRoot, "ready", handoffId), { recursive: true, force: true });
        db.prepare("DELETE FROM workspace_handoff_finalization_journal WHERE handoff_id = ?").run(handoffId);
        db.prepare("DELETE FROM handoff_references WHERE handoff_id = ?").run(handoffId);
        db.prepare("DELETE FROM workspace_handoffs WHERE handoff_id = ?").run(handoffId);
      });
    } catch (error) {
      throw storeFailure("delete handoff", error);
    }
  };

  return {
    stageCapture,
    findByFinalization,
    getHandoff,
    listHandoffs,
    recordPhase,
    phases,
    markHandoffReady,
    failHandoff,
    deleteHandoff,
  } satisfies HandoffStoreService;
});

export const HandoffStoreLive = Layer.effect(HandoffStore, make);
