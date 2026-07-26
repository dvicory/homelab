import { randomUUID } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import * as fs from "node:fs";
import * as path from "node:path";
import { Context, Effect, Layer } from "effect";
import { BrokerConfig } from "./config.js";
import { BrokerDatabase } from "./database.js";
import { BrokerError, brokerError } from "./errors.js";

export type WorkspaceState = "active" | "closed" | "deleted";
export type WorkspaceLeaseState = "active" | "released";

export interface WorkspaceRecord {
  readonly workspaceId: string;
  readonly ownerEnvironmentKey: string;
  readonly kind: "private";
  readonly state: WorkspaceState;
  readonly retentionExpiresAt: number | null;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly lastAttachedAt: number | null;
}

export interface WorkspaceLeaseRecord {
  readonly leaseId: string;
  readonly workspaceId: string;
  readonly environmentKey: string;
  readonly mode: "read-write";
  readonly state: WorkspaceLeaseState;
  readonly fencingToken: number;
  readonly createdAt: number;
  readonly releasedAt: number | null;
}

export interface WorkspaceBinding {
  readonly workspace: WorkspaceRecord;
  readonly lease: WorkspaceLeaseRecord;
}

export interface AtomicWorkspaceBinding<A> extends WorkspaceBinding {
  readonly result: A;
}

export interface WorkspaceService {
  readonly acquireAtomically: <A>(
    environmentKey: string,
    requestedWorkspaceId: string | undefined,
    operation: (binding: WorkspaceBinding) => A,
  ) => Effect.Effect<AtomicWorkspaceBinding<A>, BrokerError>;
  readonly acquire: (environmentKey: string, workspaceId?: string) => Effect.Effect<WorkspaceBinding, BrokerError>;
  readonly resolve: (environmentKey: string, workspaceId: string, leaseId: string) => Effect.Effect<WorkspaceBinding & { readonly workspacePath: string }, BrokerError>;
  readonly describe: (environmentKey: string, workspaceId: string) => Effect.Effect<WorkspaceRecord, BrokerError>;
  readonly list: (environmentKey: string) => Effect.Effect<readonly WorkspaceRecord[], BrokerError>;
  readonly release: (environmentKey: string, workspaceId: string, leaseId: string) => Effect.Effect<WorkspaceLeaseRecord, BrokerError>;
  readonly close: (environmentKey: string, workspaceId: string) => Effect.Effect<WorkspaceRecord, BrokerError>;
  readonly delete: (environmentKey: string, workspaceId: string) => Effect.Effect<WorkspaceRecord, BrokerError>;
}

export class Workspaces extends Context.Tag("@agent-x/gondolin-broker-effect/Workspaces")<
  Workspaces,
  WorkspaceService
>() {}

type WorkspaceRow = {
  workspace_id: string;
  owner_environment_key: string;
  kind: "private";
  state: WorkspaceState;
  retention_expires_at: number | null;
  created_at: number;
  updated_at: number;
  last_attached_at: number | null;
};

type LeaseRow = {
  lease_id: string;
  workspace_id: string;
  environment_key: string;
  mode: "read-write";
  state: WorkspaceLeaseState;
  fencing_token: number;
  created_at: number;
  released_at: number | null;
};

const fromWorkspaceRow = (row: WorkspaceRow): WorkspaceRecord => ({
  workspaceId: row.workspace_id,
  ownerEnvironmentKey: row.owner_environment_key,
  kind: row.kind,
  state: row.state,
  retentionExpiresAt: row.retention_expires_at,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
  lastAttachedAt: row.last_attached_at,
});

const fromLeaseRow = (row: LeaseRow): WorkspaceLeaseRecord => ({
  leaseId: row.lease_id,
  workspaceId: row.workspace_id,
  environmentKey: row.environment_key,
  mode: row.mode,
  state: row.state,
  fencingToken: row.fencing_token,
  createdAt: row.created_at,
  releasedAt: row.released_at,
});

const workspaceFailure = (operation: string, error: unknown) =>
  brokerError("workspace.failed", `workspace ${operation} failed`, {
    cause: error instanceof Error ? error.message : String(error),
  });

const initializeSchema = (db: DatabaseSync, workspaceRoot: string) => {

  db.exec(`
    CREATE TABLE IF NOT EXISTS workspaces (
      workspace_id TEXT PRIMARY KEY CHECK (length(workspace_id) = 36),
      owner_environment_key TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind = 'private'),
      state TEXT NOT NULL CHECK (state IN ('active','closed','deleted')),
      retention_expires_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      last_attached_at INTEGER
    ) STRICT;
    CREATE INDEX IF NOT EXISTS workspaces_owner_state
      ON workspaces(owner_environment_key, state, updated_at);

    CREATE TABLE IF NOT EXISTS workspace_leases (
      lease_id TEXT PRIMARY KEY CHECK (length(lease_id) = 36),
      workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
      environment_key TEXT NOT NULL,
      mode TEXT NOT NULL CHECK (mode = 'read-write'),
      state TEXT NOT NULL CHECK (state IN ('active','released')),
      fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
      created_at INTEGER NOT NULL,
      released_at INTEGER
    ) STRICT;
    CREATE UNIQUE INDEX IF NOT EXISTS workspace_leases_one_active_writer
      ON workspace_leases(workspace_id) WHERE state = 'active';
    CREATE UNIQUE INDEX IF NOT EXISTS workspace_leases_one_active_environment
      ON workspace_leases(environment_key) WHERE state = 'active';

    CREATE TABLE IF NOT EXISTS authority_bindings (
      environment_key TEXT PRIMARY KEY,
      profile TEXT NOT NULL,
      executor TEXT NOT NULL,
      authority_class TEXT NOT NULL,
      policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
      workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
      workspace_lease_id TEXT NOT NULL REFERENCES workspace_leases(lease_id),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE IF NOT EXISTS environments (
      environment_key TEXT PRIMARY KEY,
      generation INTEGER NOT NULL CHECK (generation > 0),
      state TEXT NOT NULL CHECK (state IN ('creating','active','closing','closed','failed')),
      policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
      worklane TEXT NOT NULL,
      asset_build_id TEXT NOT NULL,
      workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
      workspace_lease_id TEXT NOT NULL REFERENCES workspace_leases(lease_id),
      run_activation_id TEXT CHECK (run_activation_id IS NULL OR length(run_activation_id) = 36),
      vm_id TEXT,
      host_pid INTEGER,
      failure_reason TEXT,
      updated_at INTEGER NOT NULL
    ) STRICT;
  `);
  const activationColumn = db.prepare(
    "SELECT 1 FROM pragma_table_info('environments') WHERE name='run_activation_id'",
  ).get();
  if (activationColumn === undefined) {
    db.exec(`
      ALTER TABLE environments
      ADD COLUMN run_activation_id TEXT
      CHECK (run_activation_id IS NULL OR length(run_activation_id) = 36);
    `);
  }
  fs.mkdirSync(path.join(workspaceRoot, "data"), { recursive: true, mode: 0o700 });
};

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const database = yield* BrokerDatabase;
  const db = database.connection;
  yield* Effect.try({
    try: () => database.transaction(() => initializeSchema(db, config.workspaceRoot)),
    catch: (error) => workspaceFailure("open", error),
  });

  const workspaceQuery = db.prepare("SELECT * FROM workspaces WHERE workspace_id = ?");
  const activeEnvironmentLeaseQuery = db.prepare(
    "SELECT * FROM workspace_leases WHERE environment_key = ? AND state = 'active'",
  );
  const leaseQuery = db.prepare("SELECT * FROM workspace_leases WHERE lease_id = ?");

  const workspacePath = (workspaceId: string): string => {
    const root = path.resolve(config.workspaceRoot, "data");
    const candidate = path.resolve(root, workspaceId);
    if (path.dirname(candidate) !== root) {
      throw brokerError("workspace.path_forbidden", "derived workspace path escapes configured root", { workspaceId });
    }
    return candidate;
  };

  const acquireAtomically = <A>(
    environmentKey: string,
    requestedWorkspaceId: string | undefined,
    operation: (binding: WorkspaceBinding) => A,
  ): Effect.Effect<AtomicWorkspaceBinding<A>, BrokerError> =>
    Effect.try({
      try: () => {
        let createdPath: string | undefined;
        try {
          return database.transaction(() => {
            const active = activeEnvironmentLeaseQuery.get(environmentKey) as LeaseRow | undefined;
            if (active !== undefined) {
              if (requestedWorkspaceId !== undefined && active.workspace_id !== requestedWorkspaceId) {
                throw brokerError("workspace.conflict", "environment already holds another workspace lease", {
                  environmentKey,
                  workspaceId: active.workspace_id,
                });
              }
              const binding = {
                workspace: fromWorkspaceRow(workspaceQuery.get(active.workspace_id) as WorkspaceRow),
                lease: fromLeaseRow(active),
              };
              return { ...binding, result: operation(binding) };
            }

            const now = Date.now();
            const workspaceId = requestedWorkspaceId ?? randomUUID();
            let workspaceRow = workspaceQuery.get(workspaceId) as WorkspaceRow | undefined;
            if (workspaceRow === undefined) {
              if (requestedWorkspaceId !== undefined) {
                throw brokerError("workspace.not_found", "workspace does not exist", { workspaceId });
              }
              createdPath = workspacePath(workspaceId);
              fs.mkdirSync(createdPath, { recursive: false, mode: 0o700 });
              db.prepare(`
                INSERT INTO workspaces (
                  workspace_id, owner_environment_key, kind, state,
                  retention_expires_at, created_at, updated_at, last_attached_at
                ) VALUES (?, ?, 'private', 'active', NULL, ?, ?, ?)
              `).run(workspaceId, environmentKey, now, now, now);
              workspaceRow = workspaceQuery.get(workspaceId) as WorkspaceRow;
            } else if (workspaceRow.owner_environment_key !== environmentKey || workspaceRow.state !== "active") {
              throw brokerError("workspace.conflict", "workspace is not active and owned by this environment", {
                workspaceId,
                state: workspaceRow.state,
              });
            }

            const priorToken = db.prepare(
              "SELECT COALESCE(MAX(fencing_token), 0) AS token FROM workspace_leases WHERE workspace_id = ?",
            ).get(workspaceId) as { token: number };
            const leaseId = randomUUID();
            db.prepare(`
              INSERT INTO workspace_leases (
                lease_id, workspace_id, environment_key, mode, state,
                fencing_token, created_at, released_at
              ) VALUES (?, ?, ?, 'read-write', 'active', ?, ?, NULL)
            `).run(leaseId, workspaceId, environmentKey, priorToken.token + 1, now);
            db.prepare("UPDATE workspaces SET updated_at = ?, last_attached_at = ? WHERE workspace_id = ?")
              .run(now, now, workspaceId);
            const binding = {
              workspace: fromWorkspaceRow(workspaceQuery.get(workspaceId) as WorkspaceRow),
              lease: fromLeaseRow(leaseQuery.get(leaseId) as LeaseRow),
            };
            return { ...binding, result: operation(binding) };
          });
        } catch (error) {
          if (createdPath !== undefined) fs.rmSync(createdPath, { recursive: true, force: true });
          throw error;
        }
      },
      catch: (error) => error instanceof BrokerError ? error : workspaceFailure("acquire", error),
    });

  const acquire = (
    environmentKey: string,
    requestedWorkspaceId?: string,
  ): Effect.Effect<WorkspaceBinding, BrokerError> =>
    acquireAtomically(environmentKey, requestedWorkspaceId, () => undefined).pipe(
      Effect.map(({ workspace, lease }) => ({ workspace, lease })),
    );

  const resolve = (environmentKey: string, workspaceId: string, leaseId: string) =>
    Effect.try({
      try: () => {
        const workspaceRow = workspaceQuery.get(workspaceId) as WorkspaceRow | undefined;
        const leaseRow = leaseQuery.get(leaseId) as LeaseRow | undefined;
        if (workspaceRow === undefined || workspaceRow.state === "deleted") {
          throw brokerError("workspace.not_found", "workspace does not exist", { workspaceId });
        }
        if (
          workspaceRow.owner_environment_key !== environmentKey ||
          leaseRow === undefined ||
          leaseRow.workspace_id !== workspaceId ||
          leaseRow.environment_key !== environmentKey ||
          leaseRow.state !== "active"
        ) {
          throw brokerError("workspace.stale_lease", "workspace lease is not active for this environment", {
            workspaceId,
            leaseId,
          });
        }
        return {
          workspace: fromWorkspaceRow(workspaceRow),
          lease: fromLeaseRow(leaseRow),
          workspacePath: workspacePath(workspaceId),
        };
      },
      catch: (error) => error instanceof BrokerError ? error : workspaceFailure("resolve", error),
    });

  const describe = (environmentKey: string, workspaceId: string) =>
    Effect.try({
      try: () => {
        const row = workspaceQuery.get(workspaceId) as WorkspaceRow | undefined;
        if (row === undefined || row.owner_environment_key !== environmentKey || row.state === "deleted") {
          throw brokerError("workspace.not_found", "workspace does not exist", { workspaceId });
        }
        return fromWorkspaceRow(row);
      },
      catch: (error) => error instanceof BrokerError ? error : workspaceFailure("describe", error),
    });

  const list = (environmentKey: string) =>
    Effect.try({
      try: () => (db.prepare(
        "SELECT * FROM workspaces WHERE owner_environment_key = ? AND state != 'deleted' ORDER BY created_at, workspace_id",
      ).all(environmentKey) as WorkspaceRow[]).map(fromWorkspaceRow),
      catch: (error) => workspaceFailure("list", error),
    });

  const release = (environmentKey: string, workspaceId: string, leaseId: string) =>
    Effect.try({
      try: () => {
        const now = Date.now();
        const result = db.prepare(`
          UPDATE workspace_leases SET state = 'released', released_at = ?
          WHERE lease_id = ? AND workspace_id = ? AND environment_key = ? AND state = 'active'
        `).run(now, leaseId, workspaceId, environmentKey);
        if (result.changes !== 1) {
          throw brokerError("workspace.stale_lease", "workspace lease is not active", { workspaceId, leaseId });
        }
        db.prepare("UPDATE workspaces SET updated_at = ? WHERE workspace_id = ?").run(now, workspaceId);
        return fromLeaseRow(leaseQuery.get(leaseId) as LeaseRow);
      },
      catch: (error) => error instanceof BrokerError ? error : workspaceFailure("release", error),
    });

  const close = (environmentKey: string, workspaceId: string) =>
    Effect.try({
      try: () => {
        const active = db.prepare(
          "SELECT 1 FROM workspace_leases WHERE workspace_id = ? AND state = 'active'",
        ).get(workspaceId);
        if (active !== undefined) throw brokerError("workspace.conflict", "active workspace cannot be closed", { workspaceId });
        const now = Date.now();
        const result = db.prepare(`
          UPDATE workspaces SET state = 'closed', updated_at = ?
          WHERE workspace_id = ? AND owner_environment_key = ? AND state = 'active'
        `).run(now, workspaceId, environmentKey);
        if (result.changes !== 1) throw brokerError("workspace.not_found", "active workspace does not exist", { workspaceId });
        return fromWorkspaceRow(workspaceQuery.get(workspaceId) as WorkspaceRow);
      },
      catch: (error) => error instanceof BrokerError ? error : workspaceFailure("close", error),
    });

  const remove = (environmentKey: string, workspaceId: string) =>
    Effect.try({
      try: () => {
        const row = workspaceQuery.get(workspaceId) as WorkspaceRow | undefined;
        if (row === undefined || row.owner_environment_key !== environmentKey || row.state === "deleted") {
          throw brokerError("workspace.not_found", "workspace does not exist", { workspaceId });
        }
        const active = db.prepare(
          "SELECT 1 FROM workspace_leases WHERE workspace_id = ? AND state = 'active'",
        ).get(workspaceId);
        if (active !== undefined) throw brokerError("workspace.conflict", "active workspace cannot be deleted", { workspaceId });
        fs.rmSync(workspacePath(workspaceId), { recursive: true, force: true });
        const now = Date.now();
        db.prepare("UPDATE workspaces SET state = 'deleted', updated_at = ? WHERE workspace_id = ?")
          .run(now, workspaceId);
        return fromWorkspaceRow(workspaceQuery.get(workspaceId) as WorkspaceRow);
      },
      catch: (error) => error instanceof BrokerError ? error : workspaceFailure("delete", error),
    });

  return {
    acquireAtomically,
    acquire,
    resolve,
    describe,
    list,
    release,
    close,
    delete: remove,
  } satisfies WorkspaceService;
});

export const WorkspacesLive = Layer.scoped(Workspaces, make);
