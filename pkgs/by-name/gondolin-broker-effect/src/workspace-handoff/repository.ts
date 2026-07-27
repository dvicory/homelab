import { randomUUID } from "node:crypto";
import { Context, Effect, Layer, Schema } from "effect";
import { BrokerConfig } from "../config.js";
import { BrokerDatabase } from "../database.js";
import {
  CompleteWorkspaceImport,
  PrepareWorkspaceExportRequest,
  ReleaseWorkspaceExportRequest,
  SelectedArtifacts,
  StageWorkspaceCapture,
  StageWorkspaceImport,
  type CompleteWorkspaceImport as CompleteImportRequest,
  type PrepareWorkspaceExportRequest as PrepareExportRequest,
  type ReleaseWorkspaceExportRequest as ReleaseExportRequest,
  type StageWorkspaceCapture as StageCaptureRequest,
  type StageWorkspaceImport as StageImportRequest,
} from "./model.js";
import { BrokerError, brokerError } from "../errors.js";
import { initializeHandoffSchema } from "./schema.js";
import { TaskRunActivations } from "../task-run-activations.js";

export type HandoffState = "staging" | "ready" | "publication_failed" | "quarantined" | "failed";
export type ImportState = "staging" | "ready" | "failed";
export type ExportState = "active" | "released" | "expired";

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
  readonly policyDigest: string;
  readonly policyDecisionDigest: string;
  readonly selectedArtifacts: ReadonlyArray<string>;
  readonly state: HandoffState;
  readonly entryCount: number;
  readonly totalBytes: number;
  readonly failureReason: string | null;
}

export interface ImportRecord {
  readonly preparationId: string;
  readonly sourceHandoffId: string;
  readonly sourceTaskId: string;
  readonly sourceRunId: string;
  readonly destinationTaskId: string;
  readonly destinationRunId: string;
  readonly destinationEnvironmentKey: string;
  readonly sourcePolicyDigest: string;
  readonly destinationPolicyDigest: string;
  readonly policyDecisionDigest: string;
  readonly destinationWorkspaceId: string | null;
  readonly destinationWorkspaceLeaseId: string | null;
  readonly destinationLeaseFencingToken: number | null;
  readonly state: ImportState;
  readonly failureReason: string | null;
}

export interface ExportRecord {
  readonly exportToken: string;
  readonly deliveryId: string;
  readonly handoffId: string;
  readonly relativePath: string;
  readonly fileName: string;
  readonly byteSize: number;
  readonly expiresAt: number;
  readonly state: ExportState;
}

export interface PrepareExportFacts {
  readonly deliveryId: PrepareExportRequest["deliveryId"];
  readonly handoffId: PrepareExportRequest["handoffId"];
  readonly relativePath: PrepareExportRequest["relativePath"];
  readonly fileName: string;
  readonly byteSize: number;
  readonly expiresAt: number;
}

export interface HandoffStoreService {
  readonly stageCapture: (request: StageCaptureRequest) => HandoffRecord;
  readonly findByFinalization: (finalizationId: string) => HandoffRecord | null;
  readonly getHandoff: (handoffId: string) => HandoffRecord;
  readonly listHandoffs: (states?: ReadonlyArray<HandoffState>) => ReadonlyArray<HandoffRecord>;
  readonly markHandoffReady: (handoffId: string, entryCount: number, totalBytes: number) => HandoffRecord;
  readonly failHandoff: (
    handoffId: string,
    state: "publication_failed" | "quarantined" | "failed",
    reason: string,
  ) => HandoffRecord;
  readonly stageImport: (request: StageImportRequest) => ImportRecord;
  readonly reserveImportDestination: (request: CompleteImportRequest) => ImportRecord;
  readonly completeImport: (request: CompleteImportRequest) => ImportRecord;
  readonly failImport: (preparationId: string, reason: string) => ImportRecord;
  readonly prepareExport: (facts: PrepareExportFacts) => ExportRecord;
  readonly findExportByDelivery: (deliveryId: string) => ExportRecord | null;
  readonly getExport: (exportToken: string) => ExportRecord;
  readonly releaseExport: (request: ReleaseExportRequest) => ExportRecord;
  readonly expireExports: () => void;
}

export class HandoffStore extends Context.Tag("@agent-x/gondolin-broker-effect/HandoffStore")<
  HandoffStore,
  HandoffStoreService
>() {}


 type HandoffRow = {
  handoff_id: string; finalization_id: string; source_activation_id: string;
  source_task_id: string; source_run_id: string; source_environment_key: string;
  source_workspace_id: string; source_workspace_lease_id: string;
  source_lease_fencing_token: number; policy_digest: string; policy_decision_digest: string;
  selected_artifacts_json: string;
  state: HandoffState; entry_count: number; total_bytes: number; failure_reason: string | null;
};
 type ImportRow = {
  preparation_id: string; source_handoff_id: string; source_task_id: string; source_run_id: string;
  destination_task_id: string; destination_run_id: string; destination_environment_key: string;
  source_policy_digest: string; destination_policy_digest: string; policy_decision_digest: string;
  destination_workspace_id: string | null; destination_workspace_lease_id: string | null;
  destination_lease_fencing_token: number | null; state: ImportState; failure_reason: string | null;
};
 type ExportRow = {
  export_token: string; delivery_id: string; handoff_id: string; relative_path: string;
  file_name: string; byte_size: number; expires_at: number; state: ExportState;
};
 type ActivationSource = {
  task_id: string; run_id: string; environment_key: string; workspace_id: string;
  workspace_lease_id: string; policy_digest: string; fencing_token: number;
};

const decodeCapture = Schema.decodeUnknownSync(StageWorkspaceCapture, { onExcessProperty: "error" });
const decodeSelectedArtifacts = Schema.decodeUnknownSync(SelectedArtifacts, { onExcessProperty: "error" });
const decodeImport = Schema.decodeUnknownSync(StageWorkspaceImport, { onExcessProperty: "error" });
const decodeCompleteImport = Schema.decodeUnknownSync(CompleteWorkspaceImport, { onExcessProperty: "error" });
const decodePrepareExport = Schema.decodeUnknownSync(PrepareWorkspaceExportRequest, { onExcessProperty: "error" });
const decodeReleaseExport = Schema.decodeUnknownSync(ReleaseWorkspaceExportRequest, { onExcessProperty: "error" });

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
  policyDigest: row.policy_digest,
  selectedArtifacts: decodeSelectedArtifacts(JSON.parse(row.selected_artifacts_json)),
  policyDecisionDigest: row.policy_decision_digest,
  state: row.state,
  entryCount: row.entry_count,
  totalBytes: row.total_bytes,
  failureReason: row.failure_reason,
});

const fromImport = (row: ImportRow): ImportRecord => ({
  preparationId: row.preparation_id,
  sourceHandoffId: row.source_handoff_id,
  sourceTaskId: row.source_task_id,
  sourceRunId: row.source_run_id,
  destinationTaskId: row.destination_task_id,
  destinationRunId: row.destination_run_id,
  destinationEnvironmentKey: row.destination_environment_key,
  sourcePolicyDigest: row.source_policy_digest,
  destinationPolicyDigest: row.destination_policy_digest,
  policyDecisionDigest: row.policy_decision_digest,
  destinationWorkspaceId: row.destination_workspace_id,
  destinationWorkspaceLeaseId: row.destination_workspace_lease_id,
  destinationLeaseFencingToken: row.destination_lease_fencing_token,
  state: row.state,
  failureReason: row.failure_reason,
});

const fromExport = (row: ExportRow): ExportRecord => ({
  exportToken: row.export_token,
  deliveryId: row.delivery_id,
  handoffId: row.handoff_id,
  relativePath: row.relative_path,
  fileName: row.file_name,
  byteSize: row.byte_size,
  expiresAt: row.expires_at,
  state: row.state,
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
      markHandoffReady: unavailable,
      failHandoff: unavailable,
      stageImport: unavailable,
      reserveImportDestination: unavailable,
      completeImport: unavailable,
      failImport: unavailable,
      findExportByDelivery: unavailable,
      prepareExport: unavailable,
      getExport: unavailable,
      releaseExport: unavailable,
      expireExports: unavailable,
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
  const handoffByFinalization = db.prepare("SELECT * FROM workspace_handoffs WHERE finalization_id = ?");
  const importById = db.prepare("SELECT * FROM workspace_handoff_imports WHERE preparation_id = ?");
  const exportByToken = db.prepare("SELECT * FROM workspace_handoff_exports WHERE export_token = ?");
  const exportByDelivery = db.prepare("SELECT * FROM workspace_handoff_exports WHERE delivery_id = ?");
  const requireHandoff = (id: string): HandoffRow => {
    const row = handoffById.get(id) as HandoffRow | undefined;
    if (row === undefined) throw brokerError("handoff.not_found", "workspace handoff does not exist", { handoffId: id });
    return row;
  };
  const requireImport = (id: string): ImportRow => {
    const row = importById.get(id) as ImportRow | undefined;
    if (row === undefined) throw brokerError("handoff.not_found", "workspace import does not exist", { preparationId: id });
    return row;
  };
  const requireExport = (token: string): ExportRow => {
    const row = exportByToken.get(token) as ExportRow | undefined;
    if (row === undefined) throw brokerError("handoff.not_found", "workspace export token does not exist");
    return row;
  };

  const stageCapture = (input: StageCaptureRequest): HandoffRecord => {
    try {
      return database.transaction(() => {
        const request = decodeCapture(input);
        const prior = handoffByFinalization.get(request.finalizationId) as HandoffRow | undefined;
        const selectedArtifactsJson = JSON.stringify(request.selectedArtifacts);
        if (prior !== undefined) {
          if (prior.source_activation_id !== request.sourceActivationId ||
              prior.policy_decision_digest !== request.policyDecisionDigest ||
              prior.selected_artifacts_json !== selectedArtifactsJson) {
            throw brokerError("handoff.conflict", "finalization ID is bound to different capture facts");
          }
          return fromHandoff(prior);
        }
        const source = db.prepare(`
          SELECT a.task_id, a.run_id, a.environment_key, a.workspace_id, a.workspace_lease_id,
                 a.policy_digest, wl.fencing_token
          FROM task_run_activations a
          JOIN workspace_leases wl ON wl.lease_id = a.workspace_lease_id
          WHERE a.activation_id = ? AND a.state = 'active' AND wl.state = 'active'
        `).get(request.sourceActivationId) as ActivationSource | undefined;
        if (source === undefined) throw brokerError("run_activation.not_found", "capture source activation is not active");
        const existing = db.prepare(
          "SELECT handoff_id FROM workspace_handoffs WHERE source_activation_id = ?",
        ).get(request.sourceActivationId) as { handoff_id: string } | undefined;
        if (existing !== undefined) {
          throw brokerError("handoff.conflict", "source activation already has a workspace handoff", {
            handoffId: existing.handoff_id,
          });
        }
        const now = Date.now();
        const handoffId = randomUUID();
        db.prepare(`
          INSERT INTO workspace_handoffs (
            handoff_id, finalization_id, source_activation_id, source_task_id, source_run_id,
            source_environment_key, source_workspace_id, source_workspace_lease_id,
            source_lease_fencing_token, policy_digest, policy_decision_digest, selected_artifacts_json, state,
            entry_count, total_bytes, failure_reason, created_at, updated_at, ready_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'staging', 0, 0, NULL, ?, ?, NULL)
        `).run(
          handoffId, request.finalizationId, request.sourceActivationId, source.task_id, source.run_id,
          source.environment_key, source.workspace_id, source.workspace_lease_id, source.fencing_token,
          source.policy_digest, request.policyDecisionDigest, selectedArtifactsJson, now, now,
        );
        return fromHandoff(requireHandoff(handoffId));
      });
    } catch (error) { throw storeFailure("stage capture", error); }
  };

  const findByFinalization = (finalizationId: string): HandoffRecord | null => {
    try {
      const row = handoffByFinalization.get(finalizationId) as HandoffRow | undefined;
      return row === undefined ? null : fromHandoff(row);
    } catch (error) { throw storeFailure("find capture", error); }
  };

  const listHandoffs = (states?: ReadonlyArray<HandoffState>): ReadonlyArray<HandoffRecord> => {
    try {
      if (states === undefined) {
        return (db.prepare("SELECT * FROM workspace_handoffs ORDER BY created_at, handoff_id").all() as HandoffRow[]).map(fromHandoff);
      }
      if (states.length === 0) return [];
      const allowed = new Set<HandoffState>(["staging", "ready", "publication_failed", "quarantined", "failed"]);
      if (states.some((state) => !allowed.has(state))) throw brokerError("request.invalid", "handoff state filter is invalid");
      const placeholders = states.map(() => "?").join(", ");
      return (db.prepare(`SELECT * FROM workspace_handoffs WHERE state IN (${placeholders}) ORDER BY created_at, handoff_id`)
        .all(...states) as HandoffRow[]).map(fromHandoff);
    } catch (error) { throw storeFailure("list handoffs", error); }
  };

  const markHandoffReady = (handoffId: string, entryCount: number, totalBytes: number): HandoffRecord => {
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
        if (row.state !== "staging") throw brokerError("handoff.invalid_state", "only a staging handoff can become ready");
        const now = Date.now();
        db.prepare(`UPDATE workspace_handoffs SET state='ready', entry_count=?, total_bytes=?, updated_at=?, ready_at=?
          WHERE handoff_id=?`).run(entryCount, totalBytes, now, now, handoffId);
        return fromHandoff(requireHandoff(handoffId));
      });
    } catch (error) { throw storeFailure("mark handoff ready", error); }
  };

  const failHandoff = (
    handoffId: string,
    state: "publication_failed" | "quarantined" | "failed",
    reason: string,
  ): HandoffRecord => {
    try {
      return database.transaction(() => {
        if (reason.length === 0 || reason.length > 4096) throw brokerError("request.invalid", "handoff failure reason is invalid");
        const row = requireHandoff(handoffId);
        if (row.state === state && row.failure_reason === reason) return fromHandoff(row);
        if (["publication_failed", "quarantined", "failed"].includes(row.state)) {
          throw brokerError("handoff.invalid_state", "handoff is already terminal");
        }
        if (row.state === "ready" && state === "publication_failed") {
          throw brokerError("handoff.invalid_state", "a ready handoff can only be quarantined");
        }
        const now = Date.now();
        db.prepare(`UPDATE workspace_handoffs SET state=?, failure_reason=?, updated_at=?, ready_at=NULL WHERE handoff_id=?`)
          .run(state, reason, now, handoffId);
        return fromHandoff(requireHandoff(handoffId));
      });
    } catch (error) { throw storeFailure(`mark handoff ${state}`, error); }
  };

  const stageImport = (input: StageImportRequest): ImportRecord => {
    try {
      return database.transaction(() => {
        const request = decodeImport(input);
        const prior = importById.get(request.preparationId) as ImportRow | undefined;
        if (prior !== undefined) {
          if (prior.source_handoff_id !== request.sourceHandoffId ||
              prior.destination_task_id !== request.destinationTaskId ||
              prior.destination_run_id !== request.destinationRunId ||
              prior.destination_environment_key !== request.destinationEnvironmentKey ||
              prior.source_policy_digest !== request.sourcePolicyDigest ||
              prior.destination_policy_digest !== request.destinationPolicyDigest ||
              prior.policy_decision_digest !== request.policyDecisionDigest) {
            throw brokerError("handoff.conflict", "preparation ID is bound to different import facts");
          }
          return fromImport(prior);
        }
        const source = requireHandoff(request.sourceHandoffId);
        if (source.state !== "ready") throw brokerError("handoff.invalid_state", "only a ready handoff can be imported");
        if (source.policy_digest !== request.sourcePolicyDigest) {
          throw brokerError("handoff.conflict", "source policy digest does not match handoff provenance");
        }
        const existing = db.prepare(
          "SELECT preparation_id FROM workspace_handoff_imports WHERE destination_run_id = ?",
        ).get(request.destinationRunId) as { preparation_id: string } | undefined;
        if (existing !== undefined) {
          throw brokerError("handoff.conflict", "destination run already has a workspace import", {
            preparationId: existing.preparation_id,
          });
        }
        const now = Date.now();
        db.prepare(`
          INSERT INTO workspace_handoff_imports (
            preparation_id, source_handoff_id, source_task_id, source_run_id, destination_task_id,
            destination_run_id, destination_environment_key, source_policy_digest,
            destination_policy_digest, policy_decision_digest, destination_workspace_id,
            destination_workspace_lease_id, destination_lease_fencing_token, state, failure_reason,
            created_at, updated_at, ready_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 'staging', NULL, ?, ?, NULL)
        `).run(
          request.preparationId, request.sourceHandoffId, source.source_task_id, source.source_run_id,
          request.destinationTaskId, request.destinationRunId, request.destinationEnvironmentKey,
          request.sourcePolicyDigest, request.destinationPolicyDigest, request.policyDecisionDigest,
          now, now,
        );
        return fromImport(requireImport(request.preparationId));
      });
    } catch (error) { throw storeFailure("stage import", error); }
  };

  const activeDestinationLease = (row: ImportRow, request: CompleteImportRequest): { fencing_token: number } => {
    const lease = db.prepare(`
      SELECT wl.fencing_token, wl.state, w.owner_environment_key
      FROM workspace_leases wl JOIN workspaces w ON w.workspace_id=wl.workspace_id
      WHERE wl.lease_id=? AND wl.workspace_id=?
    `).get(request.destinationWorkspaceLeaseId, request.destinationWorkspaceId) as {
      fencing_token: number; state: string; owner_environment_key: string;
    } | undefined;
    if (lease === undefined || lease.state !== "active" || lease.owner_environment_key !== row.destination_environment_key) {
      throw brokerError("handoff.conflict", "import destination is not an active private workspace");
    }
    return lease;
  };

  const reserveImportDestination = (input: CompleteImportRequest): ImportRecord => {
    try {
      return database.transaction(() => {
        const request = decodeCompleteImport(input);
        const row = requireImport(request.preparationId);
        if (row.state === "failed") throw brokerError("handoff.invalid_state", "failed import cannot reserve a destination");
        if (row.destination_workspace_id !== null) {
          if (row.destination_workspace_id !== request.destinationWorkspaceId ||
              row.destination_workspace_lease_id !== request.destinationWorkspaceLeaseId) {
            throw brokerError("handoff.conflict", "import is bound to a different destination workspace");
          }
          activeDestinationLease(row, request);
          return fromImport(row);
        }
        if (row.state !== "staging") throw brokerError("handoff.invalid_state", "only a staging import can reserve a destination");
        const lease = activeDestinationLease(row, request);
        db.prepare(`UPDATE workspace_handoff_imports SET destination_workspace_id=?, destination_workspace_lease_id=?,
          destination_lease_fencing_token=?, updated_at=? WHERE preparation_id=?`).run(
          request.destinationWorkspaceId, request.destinationWorkspaceLeaseId, lease.fencing_token, Date.now(), request.preparationId,
        );
        return fromImport(requireImport(request.preparationId));
      });
    } catch (error) { throw storeFailure("reserve import destination", error); }
  };

  const completeImport = (input: CompleteImportRequest): ImportRecord => {
    try {
      return database.transaction(() => {
        const request = decodeCompleteImport(input);
        const row = requireImport(request.preparationId);
        if (row.state === "ready") {
          if (row.destination_workspace_id !== request.destinationWorkspaceId ||
              row.destination_workspace_lease_id !== request.destinationWorkspaceLeaseId) {
            throw brokerError("handoff.conflict", "ready import result conflicts with committed state");
          }
          return fromImport(row);
        }
        if (row.state !== "staging") throw brokerError("handoff.invalid_state", "only a staging import can become ready");
        if (row.destination_workspace_id !== request.destinationWorkspaceId ||
            row.destination_workspace_lease_id !== request.destinationWorkspaceLeaseId) {
          throw brokerError("handoff.conflict", "import destination was not reserved");
        }
        activeDestinationLease(row, request);
        const now = Date.now();
        db.prepare("UPDATE workspace_handoff_imports SET state='ready', updated_at=?, ready_at=? WHERE preparation_id=?")
          .run(now, now, request.preparationId);
        return fromImport(requireImport(request.preparationId));
      });
    } catch (error) { throw storeFailure("complete import", error); }
  };

  const failImport = (preparationId: string, reason: string): ImportRecord => {
    try {
      return database.transaction(() => {
        if (reason.length === 0 || reason.length > 4096) throw brokerError("request.invalid", "import failure reason is invalid");
        const row = requireImport(preparationId);
        if (row.state === "failed" && row.failure_reason === reason) return fromImport(row);
        if (row.state !== "staging") throw brokerError("handoff.invalid_state", "only a staging import can fail");
        db.prepare(`UPDATE workspace_handoff_imports SET state='failed', destination_workspace_id=NULL,
          destination_workspace_lease_id=NULL, destination_lease_fencing_token=NULL, failure_reason=?, updated_at=?
          WHERE preparation_id=?`).run(reason, Date.now(), preparationId);
        return fromImport(requireImport(preparationId));
      });
    } catch (error) { throw storeFailure("fail import", error); }
  };
  const findExportByDelivery = (deliveryId: string): ExportRecord | null => {
    try {
      return database.transaction(() => {
        const row = exportByDelivery.get(deliveryId) as ExportRow | undefined;
        if (row === undefined) return null;
        if (row.state === "active" && row.expires_at <= Date.now()) {
          db.prepare("UPDATE workspace_handoff_exports SET state='expired', updated_at=? WHERE export_token=?")
            .run(Date.now(), row.export_token);
          return fromExport({ ...row, state: "expired" });
        }
        return fromExport(row);
      });
    } catch (error) { throw storeFailure("find export by delivery", error); }
  };


  const prepareExport = (input: PrepareExportFacts): ExportRecord => {
    try {
      return database.transaction(() => {
        const decoded = decodePrepareExport({
          deliveryId: input.deliveryId,
          handoffId: input.handoffId,
          relativePath: input.relativePath,
        });
        const request: PrepareExportFacts = { ...input, ...decoded };
        if (!Number.isSafeInteger(request.byteSize) || request.byteSize < 0 ||
            !Number.isSafeInteger(request.expiresAt) || request.expiresAt <= Date.now() ||
            request.fileName.length === 0 || request.fileName.includes("/")) {
          throw brokerError("request.invalid", "workspace export facts are invalid");
        }
        const handoff = requireHandoff(request.handoffId);
        if (handoff.state !== "ready") throw brokerError("handoff.invalid_state", "only a ready handoff can be exported");
        const prior = exportByDelivery.get(request.deliveryId) as ExportRow | undefined;
        if (prior !== undefined) {
          if (prior.handoff_id !== request.handoffId || prior.relative_path !== request.relativePath ||
              prior.file_name !== request.fileName || prior.byte_size !== request.byteSize) {
            throw brokerError("handoff.conflict", "delivery ID is bound to different export facts");
          }
          if (prior.state !== "active" || prior.expires_at <= Date.now()) {
            throw brokerError("handoff.invalid_state", "workspace export token is no longer active");
          }
          return fromExport(prior);
        }
        const token = randomUUID();
        const now = Date.now();
        db.prepare(`INSERT INTO workspace_handoff_exports (
          export_token, delivery_id, handoff_id, relative_path, file_name, byte_size,
          expires_at, state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)`).run(
          token, request.deliveryId, request.handoffId, request.relativePath, request.fileName,
          request.byteSize, request.expiresAt, now, now,
        );
        return fromExport(requireExport(token));
      });
    } catch (error) { throw storeFailure("prepare export", error); }
  };

  const getExport = (exportToken: string): ExportRecord => {
    try {
      const record = database.transaction(() => {
        const row = requireExport(exportToken);
        if (row.state === "active" && row.expires_at <= Date.now()) {
          db.prepare("UPDATE workspace_handoff_exports SET state='expired', updated_at=? WHERE export_token=?")
            .run(Date.now(), exportToken);
          return fromExport({ ...row, state: "expired" });
        }
        return fromExport(row);
      });
      return record;
    } catch (error) { throw storeFailure("resolve export", error); }
  };

  const releaseExport = (input: ReleaseExportRequest): ExportRecord => {
    try {
      return database.transaction(() => {
        const request = decodeReleaseExport(input);
        const row = requireExport(request.exportToken);
        if (row.state === "active") {
          db.prepare("UPDATE workspace_handoff_exports SET state='released', updated_at=? WHERE export_token=?")
            .run(Date.now(), request.exportToken);
          return fromExport(requireExport(request.exportToken));
        }
        return fromExport(row);
      });
    } catch (error) { throw storeFailure("release export", error); }
  };

  const expireExports = (): void => {
    try {
      db.prepare("UPDATE workspace_handoff_exports SET state='expired', updated_at=? WHERE state='active' AND expires_at<=?")
        .run(Date.now(), Date.now());
    } catch (error) { throw storeFailure("expire exports", error); }
  };

  return {
    stageCapture,
    findByFinalization,
    getHandoff: (handoffId) => fromHandoff(requireHandoff(handoffId)),
    listHandoffs,
    markHandoffReady,
    failHandoff,
    stageImport,
    reserveImportDestination,
    completeImport,
    failImport,
    prepareExport,
    findExportByDelivery,
    getExport,
    releaseExport,
    expireExports,
  } satisfies HandoffStoreService;
});

export const HandoffStoreLive = Layer.effect(HandoffStore, make);
