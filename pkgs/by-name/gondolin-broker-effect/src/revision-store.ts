import { randomUUID } from "node:crypto";
import { Context, Effect, Layer, Schema } from "effect";
import { BrokerDatabase } from "./database.js";
import {
  CompleteWorkspaceImport,
  StageWorkspaceImport,
  StageWorkspacePublication,
  type CompleteWorkspaceImport as CompleteImportRequest,
  type StageWorkspaceImport as StageImportRequest,
  type StageWorkspacePublication as StagePublicationRequest,
} from "./revision-domain.js";
import { BrokerError, brokerError } from "./errors.js";
import { initializeRevisionSchema, MANIFEST_VERSION } from "./revision-schema.js";
import { TaskRunActivations } from "./task-run-activations.js";

export type RevisionState = "staging" | "ready" | "quarantined" | "failed";
export type ImportState = "staging" | "ready" | "failed";

export interface RevisionRecord {
  readonly revisionId: string;
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
  readonly selectedRoots: ReadonlyArray<string>;
  readonly state: RevisionState;
  readonly manifestVersion: number;
  readonly manifestDigest: string | null;
  readonly entryCount: number;
  readonly logicalBytes: number;
  readonly failureReason: string | null;
}

export interface ImportRecord {
  readonly preparationId: string;
  readonly sourceRevisionId: string;
  readonly sourceTaskId: string;
  readonly sourceRunId: string;
  readonly destinationTaskId: string;
  readonly destinationRunId: string;
  readonly destinationEnvironmentKey: string;
  readonly sourcePolicyDigest: string;
  readonly destinationPolicyDigest: string;
  readonly policyDecisionDigest: string;
  readonly relationDigest: string;
  readonly destinationWorkspaceId: string | null;
  readonly destinationWorkspaceLeaseId: string | null;
  readonly destinationLeaseFencingToken: number | null;
  readonly state: ImportState;
  readonly failureReason: string | null;
}

export interface RevisionStoreService {
  readonly stagePublication: (request: StagePublicationRequest) => RevisionRecord;
  readonly getRevision: (revisionId: string) => RevisionRecord;
  readonly listRevisions: (states?: ReadonlyArray<RevisionState>) => ReadonlyArray<RevisionRecord>;
  readonly markRevisionReady: (
    revisionId: string,
    manifestDigest: string,
    entryCount: number,
    logicalBytes: number,
  ) => RevisionRecord;
  readonly failRevision: (
    revisionId: string,
    state: "quarantined" | "failed",
    reason: string,
  ) => RevisionRecord;
  readonly stageImport: (request: StageImportRequest) => ImportRecord;
  readonly completeImport: (request: CompleteImportRequest) => ImportRecord;
  readonly failImport: (preparationId: string, reason: string) => ImportRecord;
}

export class RevisionStore extends Context.Tag("@agent-x/gondolin-broker-effect/RevisionStore")<
  RevisionStore,
  RevisionStoreService
>() {}

type RevisionRow = {
  revision_id: string; finalization_id: string; source_activation_id: string;
  source_task_id: string; source_run_id: string; source_environment_key: string;
  source_workspace_id: string; source_workspace_lease_id: string;
  source_lease_fencing_token: number; policy_digest: string; policy_decision_digest: string;
  selected_roots_json: string; state: RevisionState; manifest_version: number;
  manifest_digest: string | null; entry_count: number; logical_bytes: number;
  failure_reason: string | null;
};
type ImportRow = {
  preparation_id: string; source_revision_id: string; source_task_id: string; source_run_id: string;
  destination_task_id: string; destination_run_id: string; destination_environment_key: string;
  source_policy_digest: string; destination_policy_digest: string; policy_decision_digest: string;
  relation_digest: string; destination_workspace_id: string | null;
  destination_workspace_lease_id: string | null; destination_lease_fencing_token: number | null;
  state: ImportState; failure_reason: string | null;
};
type ActivationSource = {
  task_id: string; run_id: string; environment_key: string; workspace_id: string;
  workspace_lease_id: string; policy_digest: string; fencing_token: number;
};

const decodePublication = Schema.decodeUnknownSync(StageWorkspacePublication, { onExcessProperty: "error" });
const decodeImport = Schema.decodeUnknownSync(StageWorkspaceImport, { onExcessProperty: "error" });
const decodeCompleteImport = Schema.decodeUnknownSync(CompleteWorkspaceImport, { onExcessProperty: "error" });
const digest = /^[0-9a-f]{64}$/;

const rootsJson = (roots: ReadonlyArray<string>): string => {
  if (new Set(roots).size !== roots.length) {
    throw brokerError("request.invalid", "workspace publication roots must be unique");
  }
  return JSON.stringify([...roots].sort((left, right) =>
    Buffer.compare(Buffer.from(left), Buffer.from(right))));
};

const fromRevision = (row: RevisionRow): RevisionRecord => ({
  revisionId: row.revision_id,
  finalizationId: row.finalization_id,
  sourceActivationId: row.source_activation_id,
  sourceTaskId: row.source_task_id,
  sourceRunId: row.source_run_id,
  sourceEnvironmentKey: row.source_environment_key,
  sourceWorkspaceId: row.source_workspace_id,
  sourceWorkspaceLeaseId: row.source_workspace_lease_id,
  sourceLeaseFencingToken: row.source_lease_fencing_token,
  policyDigest: row.policy_digest,
  policyDecisionDigest: row.policy_decision_digest,
  selectedRoots: JSON.parse(row.selected_roots_json) as string[],
  state: row.state,
  manifestVersion: row.manifest_version,
  manifestDigest: row.manifest_digest,
  entryCount: row.entry_count,
  logicalBytes: row.logical_bytes,
  failureReason: row.failure_reason,
});

const fromImport = (row: ImportRow): ImportRecord => ({
  preparationId: row.preparation_id,
  sourceRevisionId: row.source_revision_id,
  sourceTaskId: row.source_task_id,
  sourceRunId: row.source_run_id,
  destinationTaskId: row.destination_task_id,
  destinationRunId: row.destination_run_id,
  destinationEnvironmentKey: row.destination_environment_key,
  sourcePolicyDigest: row.source_policy_digest,
  destinationPolicyDigest: row.destination_policy_digest,
  policyDecisionDigest: row.policy_decision_digest,
  relationDigest: row.relation_digest,
  destinationWorkspaceId: row.destination_workspace_id,
  destinationWorkspaceLeaseId: row.destination_workspace_lease_id,
  destinationLeaseFencingToken: row.destination_lease_fencing_token,
  state: row.state,
  failureReason: row.failure_reason,
});

const storeFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("revision.failed", `revision store ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const make = Effect.gen(function* () {
  const database = yield* BrokerDatabase;
  yield* TaskRunActivations;
  const db = database.connection;
  yield* Effect.try({
    try: () => initializeRevisionSchema(database),
    catch: (error) => storeFailure("schema initialization", error),
  });

  const revisionById = db.prepare("SELECT * FROM workspace_revisions WHERE revision_id = ?");
  const revisionByFinalization = db.prepare("SELECT * FROM workspace_revisions WHERE finalization_id = ?");
  const importById = db.prepare("SELECT * FROM workspace_revision_imports WHERE preparation_id = ?");
  const requireRevision = (id: string): RevisionRow => {
    const row = revisionById.get(id) as RevisionRow | undefined;
    if (row === undefined) {
      throw brokerError("revision.not_found", "workspace revision does not exist", { revisionId: id });
    }
    return row;
  };
  const requireImport = (id: string): ImportRow => {
    const row = importById.get(id) as ImportRow | undefined;
    if (row === undefined) {
      throw brokerError("revision.not_found", "workspace import does not exist", { preparationId: id });
    }
    return row;
  };

  const stagePublication = (input: StagePublicationRequest): RevisionRecord => {
    try {
      return database.transaction(() => {
        const request = decodePublication(input);
        const selectedRootsJson = rootsJson(request.selectedRoots);
        const prior = revisionByFinalization.get(request.finalizationId) as RevisionRow | undefined;
        if (prior !== undefined) {
          if (
            prior.source_activation_id !== request.sourceActivationId ||
            prior.policy_decision_digest !== request.policyDecisionDigest ||
            prior.selected_roots_json !== selectedRootsJson
          ) {
            throw brokerError("revision.conflict", "finalization ID is bound to different publication facts");
          }
          return fromRevision(prior);
        }
        const source = db.prepare(`
          SELECT a.task_id, a.run_id, a.environment_key, a.workspace_id, a.workspace_lease_id,
                 a.policy_digest, wl.fencing_token
          FROM task_run_activations a
          JOIN workspace_leases wl ON wl.lease_id = a.workspace_lease_id
          WHERE a.activation_id = ? AND a.state = 'active' AND wl.state = 'active'
        `).get(request.sourceActivationId) as ActivationSource | undefined;
        if (source === undefined) {
          throw brokerError("run_activation.not_found", "publication source activation is not active");
        }
        const existing = db.prepare(
          "SELECT revision_id FROM workspace_revisions WHERE source_activation_id = ?",
        ).get(request.sourceActivationId) as { revision_id: string } | undefined;
        if (existing !== undefined) {
          throw brokerError("revision.conflict", "source activation already has a publication", {
            revisionId: existing.revision_id,
          });
        }
        const revisionId = randomUUID();
        const now = Date.now();
        db.prepare(`INSERT INTO workspace_revisions
          (revision_id, finalization_id, source_activation_id, source_task_id, source_run_id,
           source_environment_key, source_workspace_id, source_workspace_lease_id,
           source_lease_fencing_token, policy_digest, policy_decision_digest, selected_roots_json,
           state, manifest_version, manifest_digest, entry_count, logical_bytes, failure_reason,
           created_at, updated_at, ready_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'staging', ?, NULL, 0, 0, NULL, ?, ?, NULL)`
        ).run(
          revisionId, request.finalizationId, request.sourceActivationId, source.task_id, source.run_id,
          source.environment_key, source.workspace_id, source.workspace_lease_id, source.fencing_token,
          source.policy_digest, request.policyDecisionDigest, selectedRootsJson, MANIFEST_VERSION, now, now,
        );
        return fromRevision(requireRevision(revisionId));
      });
    } catch (error) { throw storeFailure("stage publication", error); }
  };

  const listRevisions = (states?: ReadonlyArray<RevisionState>): ReadonlyArray<RevisionRecord> => {
    try {
      if (states === undefined) {
        const rows = db.prepare(
          "SELECT * FROM workspace_revisions ORDER BY created_at, revision_id",
        ).all() as Array<RevisionRow>;
        return rows.map(fromRevision);
      }
      if (states.length === 0) return [];
      const allowed = new Set<RevisionState>(["staging", "ready", "quarantined", "failed"]);
      if (states.some((state) => !allowed.has(state))) {
        throw brokerError("request.invalid", "revision state filter is invalid");
      }
      const placeholders = states.map(() => "?").join(", ");
      return (db.prepare(`SELECT * FROM workspace_revisions WHERE state IN (${placeholders})
        ORDER BY created_at, revision_id`).all(...states) as Array<RevisionRow>).map(fromRevision);
    } catch (error) { throw storeFailure("list revisions", error); }
  };

  const markRevisionReady = (
    revisionId: string,
    manifestDigest: string,
    entryCount: number,
    logicalBytes: number,
  ): RevisionRecord => {
    try {
      return database.transaction(() => {
        if (!digest.test(manifestDigest) || [entryCount, logicalBytes].some(
          (value) => !Number.isSafeInteger(value) || value < 0,
        )) throw brokerError("request.invalid", "revision summary is invalid");
        const row = requireRevision(revisionId);
        if (row.state === "ready") {
          if (
            row.manifest_digest !== manifestDigest ||
            row.entry_count !== entryCount ||
            row.logical_bytes !== logicalBytes
          ) throw brokerError("revision.conflict", "ready revision summary conflicts with committed state");
          return fromRevision(row);
        }
        if (row.state !== "staging") {
          throw brokerError("revision.invalid_state", "only a staging revision can become ready");
        }
        const now = Date.now();
        db.prepare(`UPDATE workspace_revisions SET state='ready', manifest_digest=?, entry_count=?,
          logical_bytes=?, updated_at=?, ready_at=? WHERE revision_id=?`
        ).run(manifestDigest, entryCount, logicalBytes, now, now, revisionId);
        return fromRevision(requireRevision(revisionId));
      });
    } catch (error) { throw storeFailure("mark revision ready", error); }
  };

  const failRevision = (
    revisionId: string,
    state: "quarantined" | "failed",
    reason: string,
  ): RevisionRecord => {
    try {
      return database.transaction(() => {
        if (reason.length === 0 || reason.length > 4096) {
          throw brokerError("request.invalid", "revision failure reason is invalid");
        }
        const row = requireRevision(revisionId);
        if (row.state === state && row.failure_reason === reason) return fromRevision(row);
        if (row.state === "quarantined" || row.state === "failed") {
          throw brokerError("revision.invalid_state", "revision is already terminal");
        }
        if (row.state === "ready" && state !== "quarantined") {
          throw brokerError("revision.invalid_state", "a ready revision can only be quarantined");
        }
        const now = Date.now();
        db.prepare(`UPDATE workspace_revisions SET state=?, manifest_digest=NULL, entry_count=0,
          logical_bytes=0, failure_reason=?, updated_at=?, ready_at=NULL WHERE revision_id=?`
        ).run(state, reason, now, revisionId);
        return fromRevision(requireRevision(revisionId));
      });
    } catch (error) { throw storeFailure(`mark revision ${state}`, error); }
  };

  const stageImport = (input: StageImportRequest): ImportRecord => {
    try {
      return database.transaction(() => {
        const request = decodeImport(input);
        const prior = importById.get(request.preparationId) as ImportRow | undefined;
        if (prior !== undefined) {
          if (
            prior.source_revision_id !== request.sourceRevisionId ||
            prior.destination_task_id !== request.destinationTaskId ||
            prior.destination_run_id !== request.destinationRunId ||
            prior.destination_environment_key !== request.destinationEnvironmentKey ||
            prior.source_policy_digest !== request.sourcePolicyDigest ||
            prior.destination_policy_digest !== request.destinationPolicyDigest ||
            prior.policy_decision_digest !== request.policyDecisionDigest ||
            prior.relation_digest !== request.relationDigest
          ) throw brokerError("revision.conflict", "preparation ID is bound to different import facts");
          return fromImport(prior);
        }
        const source = requireRevision(request.sourceRevisionId);
        if (source.state !== "ready") {
          throw brokerError("revision.invalid_state", "only a ready revision can be imported");
        }
        if (source.policy_digest !== request.sourcePolicyDigest) {
          throw brokerError("revision.conflict", "source policy digest does not match revision provenance");
        }
        const existing = db.prepare(
          "SELECT preparation_id FROM workspace_revision_imports WHERE destination_run_id = ?",
        ).get(request.destinationRunId) as { preparation_id: string } | undefined;
        if (existing !== undefined) {
          throw brokerError("revision.conflict", "destination run already has a workspace import", {
            preparationId: existing.preparation_id,
          });
        }
        const now = Date.now();
        db.prepare(`INSERT INTO workspace_revision_imports
          (preparation_id, source_revision_id, source_task_id, source_run_id, destination_task_id,
           destination_run_id, destination_environment_key, source_policy_digest,
           destination_policy_digest, policy_decision_digest, relation_digest,
           destination_workspace_id, destination_workspace_lease_id,
           destination_lease_fencing_token, state, failure_reason, created_at, updated_at, ready_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 'staging', NULL, ?, ?, NULL)`
        ).run(
          request.preparationId, request.sourceRevisionId, source.source_task_id, source.source_run_id,
          request.destinationTaskId, request.destinationRunId, request.destinationEnvironmentKey,
          request.sourcePolicyDigest, request.destinationPolicyDigest, request.policyDecisionDigest,
          request.relationDigest, now, now,
        );
        return fromImport(requireImport(request.preparationId));
      });
    } catch (error) { throw storeFailure("stage import", error); }
  };

  const completeImport = (input: CompleteImportRequest): ImportRecord => {
    try {
      return database.transaction(() => {
        const request = decodeCompleteImport(input);
        const row = requireImport(request.preparationId);
        if (row.state === "ready") {
          if (
            row.destination_workspace_id !== request.destinationWorkspaceId ||
            row.destination_workspace_lease_id !== request.destinationWorkspaceLeaseId
          ) throw brokerError("revision.conflict", "ready import result conflicts with committed state");
          return fromImport(row);
        }
        if (row.state !== "staging") {
          throw brokerError("revision.invalid_state", "only a staging import can become ready");
        }
        const lease = db.prepare(`SELECT wl.fencing_token, wl.state, w.owner_environment_key
          FROM workspace_leases wl JOIN workspaces w ON w.workspace_id=wl.workspace_id
          WHERE wl.lease_id=? AND wl.workspace_id=?`
        ).get(request.destinationWorkspaceLeaseId, request.destinationWorkspaceId) as {
          fencing_token: number; state: string; owner_environment_key: string;
        } | undefined;
        if (
          lease === undefined || lease.state !== "active" ||
          lease.owner_environment_key !== row.destination_environment_key
        ) throw brokerError("revision.conflict", "import result is not the destination active private workspace");
        const now = Date.now();
        db.prepare(`UPDATE workspace_revision_imports SET state='ready', destination_workspace_id=?,
          destination_workspace_lease_id=?, destination_lease_fencing_token=?, updated_at=?, ready_at=?
          WHERE preparation_id=?`
        ).run(
          request.destinationWorkspaceId, request.destinationWorkspaceLeaseId,
          lease.fencing_token, now, now, request.preparationId,
        );
        return fromImport(requireImport(request.preparationId));
      });
    } catch (error) { throw storeFailure("complete import", error); }
  };

  const failImport = (preparationId: string, reason: string): ImportRecord => {
    try {
      return database.transaction(() => {
        if (reason.length === 0 || reason.length > 4096) {
          throw brokerError("request.invalid", "import failure reason is invalid");
        }
        const row = requireImport(preparationId);
        if (row.state === "failed" && row.failure_reason === reason) return fromImport(row);
        if (row.state !== "staging") {
          throw brokerError("revision.invalid_state", "only a staging import can fail");
        }
        db.prepare(`UPDATE workspace_revision_imports SET state='failed', failure_reason=?, updated_at=?
          WHERE preparation_id=?`
        ).run(reason, Date.now(), preparationId);
        return fromImport(requireImport(preparationId));
      });
    } catch (error) { throw storeFailure("fail import", error); }
  };

  return {
    stagePublication,
    getRevision: (revisionId) => fromRevision(requireRevision(revisionId)),
    listRevisions,
    markRevisionReady,
    failRevision,
    stageImport,
    completeImport,
    failImport,
  } satisfies RevisionStoreService;
});

export const RevisionStoreLive = Layer.effect(RevisionStore, make);
