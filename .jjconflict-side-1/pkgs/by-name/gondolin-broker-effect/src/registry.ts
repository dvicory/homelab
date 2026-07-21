import { DatabaseSync } from "node:sqlite";
import * as fs from "node:fs";
import { Context, Effect, Layer } from "effect";
import { BrokerConfig } from "./config.js";
import { brokerError, type BrokerError } from "./errors.js";

export type EnvironmentState = "creating" | "active" | "closing" | "closed" | "failed";

export interface EnvironmentRecord {
  readonly environmentKey: string;
  readonly generation: number;
  readonly state: EnvironmentState;
  readonly policyGeneration: number;
  readonly worklane: string;
  readonly assetBuildId: string;
  readonly workspacePath: string;
  readonly vmId: string | null;
  readonly hostPid: number | null;
  readonly failureReason: string | null;
  readonly updatedAt: number;
}

export interface ReserveEnvironment {
  readonly environmentKey: string;
  readonly policyGeneration: number;
  readonly worklane: string;
  readonly assetBuildId: string;
  readonly workspacePath: string;
}

export interface RegistryService {
  readonly get: (environmentKey: string) => Effect.Effect<EnvironmentRecord | undefined, BrokerError>;
  readonly reserve: (request: ReserveEnvironment) => Effect.Effect<EnvironmentRecord, BrokerError>;
  readonly markActive: (environmentKey: string, generation: number, vmId: string, hostPid: number | null) => Effect.Effect<void, BrokerError>;
  readonly markClosing: (environmentKey: string, generation: number) => Effect.Effect<void, BrokerError>;
  readonly markClosed: (environmentKey: string, generation: number) => Effect.Effect<void, BrokerError>;
  readonly markFailed: (environmentKey: string, generation: number, reason: string) => Effect.Effect<void, BrokerError>;
}

export class Registry extends Context.Tag("@agent-x/gondolin-broker-effect/Registry")<
  Registry,
  RegistryService
>() {}

type Row = {
  environment_key: string;
  generation: number;
  state: EnvironmentState;
  policy_generation: number;
  worklane: string;
  asset_build_id: string;
  workspace_path: string;
  vm_id: string | null;
  host_pid: number | null;
  failure_reason: string | null;
  updated_at: number;
};

const fromRow = (row: Row): EnvironmentRecord => ({
  environmentKey: row.environment_key,
  generation: row.generation,
  state: row.state,
  policyGeneration: row.policy_generation,
  worklane: row.worklane,
  assetBuildId: row.asset_build_id,
  workspacePath: row.workspace_path,
  vmId: row.vm_id,
  hostPid: row.host_pid,
  failureReason: row.failure_reason,
  updatedAt: row.updated_at,
});

const registryFailure = (operation: string, error: unknown) =>
  brokerError("registry.failed", `registry ${operation} failed`, {
    cause: error instanceof Error ? error.message : String(error),
  });

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const db = yield* Effect.acquireRelease(
    Effect.try({
      try: () => {
        fs.mkdirSync(config.stateDir, { recursive: true, mode: 0o700 });
        const opened = new DatabaseSync(config.databasePath);
        opened.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;");
        opened.exec(`
          CREATE TABLE IF NOT EXISTS environments (
            environment_key TEXT PRIMARY KEY,
            generation INTEGER NOT NULL CHECK (generation > 0),
            state TEXT NOT NULL CHECK (state IN ('creating','active','closing','closed','failed')),
            policy_generation INTEGER NOT NULL CHECK (policy_generation > 0),
            worklane TEXT NOT NULL,
            asset_build_id TEXT NOT NULL,
            workspace_path TEXT NOT NULL,
            vm_id TEXT,
            host_pid INTEGER,
            failure_reason TEXT,
            updated_at INTEGER NOT NULL
          ) STRICT;
        `);
        fs.chmodSync(config.databasePath, 0o600);
        opened.prepare(
          "UPDATE environments SET state='failed', failure_reason='broker restarted before reconciliation', updated_at=? WHERE state IN ('creating','active','closing')",
        ).run(Date.now());
        return opened;
      },
      catch: (error) => registryFailure("open", error),
    }),
    (opened) => Effect.sync(() => opened.close()),
  );

  const query = db.prepare("SELECT * FROM environments WHERE environment_key = ?");
  const get = (environmentKey: string): Effect.Effect<EnvironmentRecord | undefined, BrokerError> =>
    Effect.try({
      try: () => {
        const row = query.get(environmentKey) as Row | undefined;
        return row === undefined ? undefined : fromRow(row);
      },
      catch: (error) => registryFailure("read", error),
    });

  const reserve = (request: ReserveEnvironment): Effect.Effect<EnvironmentRecord, BrokerError> =>
    Effect.try({
      try: () => {
        db.exec("BEGIN IMMEDIATE");
        try {
          const prior = query.get(request.environmentKey) as Row | undefined;
          const generation = (prior?.generation ?? 0) + 1;
          const now = Date.now();
          db.prepare(`
            INSERT INTO environments (
              environment_key, generation, state, policy_generation, worklane,
              asset_build_id, workspace_path, vm_id, host_pid, failure_reason, updated_at
            ) VALUES (?, ?, 'creating', ?, ?, ?, ?, NULL, NULL, NULL, ?)
            ON CONFLICT(environment_key) DO UPDATE SET
              generation=excluded.generation,
              state='creating',
              policy_generation=excluded.policy_generation,
              worklane=excluded.worklane,
              asset_build_id=excluded.asset_build_id,
              workspace_path=excluded.workspace_path,
              vm_id=NULL,
              host_pid=NULL,
              failure_reason=NULL,
              updated_at=excluded.updated_at
          `).run(
            request.environmentKey,
            generation,
            request.policyGeneration,
            request.worklane,
            request.assetBuildId,
            request.workspacePath,
            now,
          );
          db.exec("COMMIT");
          return {
            ...request,
            generation,
            state: "creating",
            vmId: null,
            hostPid: null,
            failureReason: null,
            updatedAt: now,
          };
        } catch (error) {
          db.exec("ROLLBACK");
          throw error;
        }
      },
      catch: (error) => registryFailure("reserve", error),
    });

  const transition = (
    environmentKey: string,
    generation: number,
    state: EnvironmentState,
    values: { readonly vmId?: string | null; readonly hostPid?: number | null; readonly failureReason?: string | null } = {},
  ): Effect.Effect<void, BrokerError> =>
    Effect.try({
      try: () => {
        const result = db.prepare(`
          UPDATE environments SET
            state = ?, vm_id = COALESCE(?, vm_id), host_pid = COALESCE(?, host_pid),
            failure_reason = ?, updated_at = ?
          WHERE environment_key = ? AND generation = ?
        `).run(
          state,
          values.vmId ?? null,
          values.hostPid ?? null,
          values.failureReason ?? null,
          Date.now(),
          environmentKey,
          generation,
        );
        if (result.changes !== 1) {
          throw new Error("environment generation does not exist");
        }
      },
      catch: (error) => registryFailure(`transition to ${state}`, error),
    });

  return {
    get,
    reserve,
    markActive: (key, generation, vmId, hostPid) => transition(key, generation, "active", { vmId, hostPid }),
    markClosing: (key, generation) => transition(key, generation, "closing"),
    markClosed: (key, generation) => transition(key, generation, "closed"),
    markFailed: (key, generation, reason) => transition(key, generation, "failed", { failureReason: reason }),
  } satisfies RegistryService;
});

export const RegistryLive = Layer.scoped(Registry, make);
