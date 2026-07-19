/**
 * Broker lifecycle registry (V3 §15.2).
 *
 * SQLite is the source of truth for environment identity, generation,
 * workspace paths, lifecycle state, active process sessions, runtime grants,
 * retention, tombstones, and reconciliation status. All multi-write
 * operations run in IMMEDIATE transactions; foreign keys are enforced.
 * Authorization is never inferred from directories alone: a directory
 * without a valid registry row is quarantined, never adopted.
 */
import { DatabaseSync } from "node:sqlite";
import { BrokerError, REASONS } from "./errors.js";

export type EnvironmentState =
  | "creating"
  | "active"
  | "closing"
  | "warm"
  | "pruned"
  | "failed"
  | "recreating";

export interface EnvironmentRow {
  envKey: string;
  profile: string;
  worklane: string | null;
  template: string;
  asset: string;
  buildId: string;
  policyHash: string;
  generation: string;
  workspacePath: string | null;
  state: EnvironmentState;
  stateReason: string | null;
  createdAt: number;
  lastActivityAt: number;
}

export type ProcessState = "running" | "exited" | "cancelled" | "failed";

export interface ProcessRow {
  procId: string;
  envKey: string;
  generation: string;
  mode: "foreground" | "background";
  cwd: string | null;
  state: ProcessState;
  exitCode: number | null;
  signal: number | null;
  cancelReason: string | null;
  startedAt: number;
  endedAt: number | null;
  expiresAt: number | null;
}

export interface GrantRow {
  grantId: string;
  envKey: string;
  capability: string;
  scope: "once" | "task" | "session";
  policyGeneration: string;
  createdAt: number;
  expiresAt: number | null;
  revokedAt: number | null;
}

export interface TombstoneRow {
  envKey: string;
  generation: string;
  deletedAt: number;
  reason: string;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS environments (
  env_key TEXT PRIMARY KEY,
  profile TEXT NOT NULL,
  worklane TEXT,
  template TEXT NOT NULL,
  asset TEXT NOT NULL,
  build_id TEXT NOT NULL,
  policy_hash TEXT NOT NULL,
  generation TEXT NOT NULL,
  workspace_path TEXT,
  state TEXT NOT NULL CHECK (state IN ('creating','active','closing','warm','pruned','failed','recreating')),
  state_reason TEXT,
  created_at INTEGER NOT NULL,
  last_activity_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS processes (
  proc_id TEXT PRIMARY KEY,
  env_key TEXT NOT NULL REFERENCES environments(env_key) ON DELETE CASCADE,
  generation TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('foreground','background')),
  cwd TEXT,
  state TEXT NOT NULL CHECK (state IN ('running','exited','cancelled','failed')),
  exit_code INTEGER,
  signal INTEGER,
  cancel_reason TEXT,
  started_at INTEGER NOT NULL,
  ended_at INTEGER,
  expires_at INTEGER
);
CREATE INDEX IF NOT EXISTS processes_env ON processes(env_key, state);
CREATE TABLE IF NOT EXISTS grants (
  grant_id TEXT PRIMARY KEY,
  env_key TEXT NOT NULL REFERENCES environments(env_key) ON DELETE CASCADE,
  capability TEXT NOT NULL,
  scope TEXT NOT NULL CHECK (scope IN ('once','task','session')),
  policy_generation TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER,
  revoked_at INTEGER
);
CREATE INDEX IF NOT EXISTS grants_env ON grants(env_key, capability, revoked_at);
CREATE TABLE IF NOT EXISTS tombstones (
  env_key TEXT PRIMARY KEY,
  generation TEXT NOT NULL,
  deleted_at INTEGER NOT NULL,
  reason TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  profile TEXT NOT NULL,
  worklane TEXT,
  env_key TEXT,
  generation TEXT,
  request_id INTEGER,
  event TEXT NOT NULL,
  reason TEXT,
  layer TEXT,
  metadata TEXT
);
CREATE INDEX IF NOT EXISTS audit_env_ts ON audit(env_key, ts);
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
`;

interface RawEnvironmentRow {
  env_key: string;
  profile: string;
  worklane: string | null;
  template: string;
  asset: string;
  build_id: string;
  policy_hash: string;
  generation: string;
  workspace_path: string | null;
  state: string;
  state_reason: string | null;
  created_at: number;
  last_activity_at: number;
}

interface RawProcessRow {
  proc_id: string;
  env_key: string;
  generation: string;
  mode: string;
  cwd: string | null;
  state: string;
  exit_code: number | null;
  signal: number | null;
  cancel_reason: string | null;
  started_at: number;
  ended_at: number | null;
  expires_at: number | null;
}

interface RawGrantRow {
  grant_id: string;
  env_key: string;
  capability: string;
  scope: string;
  policy_generation: string;
  created_at: number;
  expires_at: number | null;
  revoked_at: number | null;
}

function toEnvironment(row: RawEnvironmentRow): EnvironmentRow {
  return {
    envKey: row.env_key,
    profile: row.profile,
    worklane: row.worklane,
    template: row.template,
    asset: row.asset,
    buildId: row.build_id,
    policyHash: row.policy_hash,
    generation: row.generation,
    workspacePath: row.workspace_path,
    state: row.state as EnvironmentState,
    stateReason: row.state_reason,
    createdAt: row.created_at,
    lastActivityAt: row.last_activity_at,
  };
}

function toProcess(row: RawProcessRow): ProcessRow {
  return {
    procId: row.proc_id,
    envKey: row.env_key,
    generation: row.generation,
    mode: row.mode as ProcessRow["mode"],
    cwd: row.cwd,
    state: row.state as ProcessState,
    exitCode: row.exit_code,
    signal: row.signal,
    cancelReason: row.cancel_reason,
    startedAt: row.started_at,
    endedAt: row.ended_at,
    expiresAt: row.expires_at,
  };
}

function toGrant(row: RawGrantRow): GrantRow {
  return {
    grantId: row.grant_id,
    envKey: row.env_key,
    capability: row.capability,
    scope: row.scope as GrantRow["scope"],
    policyGeneration: row.policy_generation,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    revokedAt: row.revoked_at,
  };
}

export class Registry {
  #db: DatabaseSync;

  constructor(path: string) {
    this.#db = new DatabaseSync(path);
    this.#db.exec("PRAGMA journal_mode = WAL");
    this.#db.exec("PRAGMA foreign_keys = ON");
    this.#db.exec("PRAGMA busy_timeout = 5000");
    this.#db.exec(SCHEMA);
  }

  close(): void {
    this.#db.close();
  }

  /** Shared connection for satellite writers that use registry tables
   * (audit). One writer avoids cross-connection lock contention. */
  get db(): DatabaseSync {
    return this.#db;
  }

  /** Run `fn` inside an IMMEDIATE transaction; roll back on any throw. */
  transaction<T>(fn: () => T): T {
    this.#db.exec("BEGIN IMMEDIATE");
    try {
      const result = fn();
      this.#db.exec("COMMIT");
      return result;
    } catch (err) {
      try {
        this.#db.exec("ROLLBACK");
      } catch {
        // rollback best-effort; the original error matters more
      }
      throw err;
    }
  }

  // -- environments ---------------------------------------------------------

  insertEnvironment(row: EnvironmentRow): void {
    this.#db
      .prepare(
        `INSERT INTO environments
         (env_key, profile, worklane, template, asset, build_id, policy_hash,
          generation, workspace_path, state, state_reason, created_at, last_activity_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        row.envKey, row.profile, row.worklane, row.template, row.asset, row.buildId,
        row.policyHash, row.generation, row.workspacePath, row.state, row.stateReason,
        row.createdAt, row.lastActivityAt,
      );
  }

  getEnvironment(envKey: string): EnvironmentRow | null {
    const row = this.#db
      .prepare("SELECT * FROM environments WHERE env_key = ?")
      .get(envKey) as RawEnvironmentRow | undefined;
    return row === undefined ? null : toEnvironment(row);
  }

  updateEnvironmentState(envKey: string, state: EnvironmentState, reason: string | null, now: number): void {
    const result = this.#db
      .prepare("UPDATE environments SET state = ?, state_reason = ?, last_activity_at = ? WHERE env_key = ?")
      .run(state, reason, now, envKey);
    if (result.changes === 0) {
      throw new BrokerError(REASONS.ENV_NOT_FOUND, `environment not found`, { envKey });
    }
  }

  /** Rotate an environment row to a new generation (recreation). */
  rotateEnvironment(row: EnvironmentRow): void {
    const result = this.#db
      .prepare(
        `UPDATE environments SET template = ?, asset = ?, build_id = ?, policy_hash = ?,
         generation = ?, workspace_path = ?, state = ?, state_reason = ?, last_activity_at = ?
         WHERE env_key = ?`,
      )
      .run(
        row.template, row.asset, row.buildId, row.policyHash, row.generation,
        row.workspacePath, row.state, row.stateReason, row.lastActivityAt, row.envKey,
      );
    if (result.changes === 0) {
      throw new BrokerError(REASONS.ENV_NOT_FOUND, `environment not found`, { envKey: row.envKey });
    }
  }

  touchEnvironment(envKey: string, now: number): void {
    this.#db.prepare("UPDATE environments SET last_activity_at = ? WHERE env_key = ?").run(now, envKey);
  }

  listEnvironments(states?: EnvironmentState[]): EnvironmentRow[] {
    if (!states || states.length === 0) {
      const rows = this.#db.prepare("SELECT * FROM environments").all() as unknown as RawEnvironmentRow[];
      return rows.map(toEnvironment);
    }
    const marks = states.map(() => "?").join(",");
    const rows = this.#db
      .prepare(`SELECT * FROM environments WHERE state IN (${marks})`)
      .all(...states) as unknown as RawEnvironmentRow[];
    return rows.map(toEnvironment);
  }

  deleteEnvironment(envKey: string): void {
    this.#db.prepare("DELETE FROM environments WHERE env_key = ?").run(envKey);
  }

  // -- tombstones -----------------------------------------------------------

  /** Record a tombstone; idempotent (keeps the earliest deletion record). */
  insertTombstone(row: TombstoneRow): void {
    this.#db
      .prepare("INSERT OR IGNORE INTO tombstones (env_key, generation, deleted_at, reason) VALUES (?, ?, ?, ?)")
      .run(row.envKey, row.generation, row.deletedAt, row.reason);
  }

  getTombstone(envKey: string): TombstoneRow | null {
    const row = this.#db
      .prepare("SELECT * FROM tombstones WHERE env_key = ?")
      .get(envKey) as
      | { env_key: string; generation: string; deleted_at: number; reason: string }
      | undefined;
    return row === undefined
      ? null
      : { envKey: row.env_key, generation: row.generation, deletedAt: row.deleted_at, reason: row.reason };
  }

  // -- processes --------------------------------------------------------------

  insertProcess(row: ProcessRow): void {
    this.#db
      .prepare(
        `INSERT INTO processes
         (proc_id, env_key, generation, mode, cwd, state, exit_code, signal,
          cancel_reason, started_at, ended_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        row.procId, row.envKey, row.generation, row.mode, row.cwd, row.state,
        row.exitCode, row.signal, row.cancelReason, row.startedAt, row.endedAt, row.expiresAt,
      );
  }

  getProcess(procId: string): ProcessRow | null {
    const row = this.#db.prepare("SELECT * FROM processes WHERE proc_id = ?").get(procId) as
      | RawProcessRow
      | undefined;
    return row === undefined ? null : toProcess(row);
  }

  finishProcess(
    procId: string,
    state: ProcessState,
    exitCode: number | null,
    signal: number | null,
    cancelReason: string | null,
    endedAt: number,
  ): void {
    this.#db
      .prepare(
        "UPDATE processes SET state = ?, exit_code = ?, signal = ?, cancel_reason = ?, ended_at = ? WHERE proc_id = ?",
      )
      .run(state, exitCode, signal, cancelReason, endedAt, procId);
  }

  listProcesses(filter: { envKey?: string; state?: ProcessState }): ProcessRow[] {
    const clauses: string[] = [];
    const params: (string | number)[] = [];
    if (filter.envKey !== undefined) {
      clauses.push("env_key = ?");
      params.push(filter.envKey);
    }
    if (filter.state !== undefined) {
      clauses.push("state = ?");
      params.push(filter.state);
    }
    const where = clauses.length === 0 ? "" : ` WHERE ${clauses.join(" AND ")}`;
    const rows = this.#db.prepare(`SELECT * FROM processes${where}`).all(...params) as unknown as RawProcessRow[];
    return rows.map(toProcess);
  }

  /** Expire finished background sessions past their deadline. */
  deleteExpiredProcesses(now: number): number {
    const result = this.#db
      .prepare("DELETE FROM processes WHERE state != 'running' AND expires_at IS NOT NULL AND expires_at < ?")
      .run(now);
    return Number(result.changes);
  }

  // -- grants -----------------------------------------------------------------

  insertGrant(row: GrantRow): void {
    this.#db
      .prepare(
        `INSERT INTO grants (grant_id, env_key, capability, scope, policy_generation, created_at, expires_at, revoked_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        row.grantId, row.envKey, row.capability, row.scope, row.policyGeneration,
        row.createdAt, row.expiresAt, row.revokedAt,
      );
  }

  activeGrant(envKey: string, capability: string, now: number): GrantRow | null {
    const row = this.#db
      .prepare(
        `SELECT * FROM grants
         WHERE env_key = ? AND capability = ? AND revoked_at IS NULL
           AND (expires_at IS NULL OR expires_at > ?)
         ORDER BY created_at DESC LIMIT 1`,
      )
      .get(envKey, capability, now) as RawGrantRow | undefined;
    return row === undefined ? null : toGrant(row);
  }

  revokeGrant(grantId: string, now: number): number {
    const result = this.#db
      .prepare("UPDATE grants SET revoked_at = ? WHERE grant_id = ? AND revoked_at IS NULL")
      .run(now, grantId);
    return Number(result.changes);
  }

  listGrants(envKey: string | null, now: number): GrantRow[] {
    const rows = (
      envKey === null
        ? (this.#db
            .prepare("SELECT * FROM grants WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)")
            .all(now) as unknown as RawGrantRow[])
        : (this.#db
            .prepare(
              "SELECT * FROM grants WHERE env_key = ? AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)",
            )
            .all(envKey, now) as unknown as RawGrantRow[])
    );
    return rows.map(toGrant);
  }

  // -- meta -------------------------------------------------------------------

  getMeta(key: string): string | null {
    const row = this.#db.prepare("SELECT value FROM meta WHERE key = ?").get(key) as
      | { value: string }
      | undefined;
    return row?.value ?? null;
  }

  setMeta(key: string, value: string): void {
    this.#db
      .prepare("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
      .run(key, value);
  }
}
