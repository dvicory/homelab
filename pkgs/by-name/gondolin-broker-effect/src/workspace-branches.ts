import { Context, Effect, Layer, Schema } from "effect";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { requireAuthorityBinding } from "./authority.js";
import { BrokerConfig } from "./config.js";
import { BrokerDatabase } from "./database.js";
import { EnvironmentKey } from "./domain.js";
import { Environments } from "./environments.js";
import { BrokerError, brokerError } from "./errors.js";
import { Registry } from "./registry.js";
import { Workspaces } from "./workspaces.js";

const OperationId = Schema.String.pipe(
  Schema.pattern(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i),
);

export const PrepareWorkspaceBranchRequest = Schema.Struct({
  operationId: OperationId,
  sourceEnvironmentKey: EnvironmentKey,
  destinationEnvironmentKey: EnvironmentKey,
});
export type PrepareWorkspaceBranchRequest = typeof PrepareWorkspaceBranchRequest.Type;

export interface PreparedWorkspaceBranch {
  readonly operationId: string;
  readonly state: "ready";
  readonly sourceEnvironmentKey: string;
  readonly destinationEnvironmentKey: string;
  readonly sourceWorkspaceId: string;
  readonly destinationWorkspaceId: string;
  readonly destinationWorkspaceLeaseId: string;
}

export interface WorkspaceBranchService {
  readonly prepare: (
    request: PrepareWorkspaceBranchRequest,
  ) => Effect.Effect<PreparedWorkspaceBranch, BrokerError>;
}

export class WorkspaceBranches extends Context.Tag("@agent-x/gondolin-broker-effect/WorkspaceBranches")<
  WorkspaceBranches,
  WorkspaceBranchService
>() {}

type BranchState = "planned" | "copy_ready" | "destination_allocated" | "ready";
type BranchRow = {
  operation_id: string;
  source_environment_key: string;
  destination_environment_key: string;
  source_workspace_id: string;
  destination_workspace_id: string | null;
  destination_workspace_lease_id: string | null;
  state: BranchState;
};

const branchFailure = (operation: string, error: unknown) =>
  error instanceof BrokerError
    ? error
    : brokerError("workspace.failed", `workspace branch ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const assertDirectory = async (directory: string, label: string): Promise<void> => {
  const metadata = await fs.lstat(directory);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw brokerError("workspace.failed", `${label} is not a real directory`);
  }
};

const directoryIsEmpty = async (directory: string): Promise<boolean> => {
  const handle = await fs.opendir(directory);
  try {
    return (await handle.read()) === null;
  } finally {
    await handle.close();
  }
};

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const database = yield* BrokerDatabase;
  const registry = yield* Registry;
  const workspaces = yield* Workspaces;
  const environments = yield* Environments;
  const db = database.connection;
  const stagingRoot = path.resolve(config.workspaceRoot, "branch-staging");

  yield* Effect.try({
    try: () => database.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS workspace_branch_operations (
          operation_id TEXT PRIMARY KEY CHECK (length(operation_id) = 36),
          source_environment_key TEXT NOT NULL,
          destination_environment_key TEXT NOT NULL UNIQUE,
          source_workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
          destination_workspace_id TEXT REFERENCES workspaces(workspace_id),
          destination_workspace_lease_id TEXT REFERENCES workspace_leases(lease_id),
          state TEXT NOT NULL CHECK (state IN ('planned','copy_ready','destination_allocated','ready')),
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        ) STRICT;
      `);
    }),
    catch: (error) => branchFailure("schema initialization", error),
  });
  yield* Effect.tryPromise({
    try: () => fs.mkdir(stagingRoot, { recursive: true, mode: 0o700 }),
    catch: (error) => branchFailure("staging initialization", error),
  });

  const query = db.prepare("SELECT * FROM workspace_branch_operations WHERE operation_id = ?");
  const destinationQuery = db.prepare(
    "SELECT * FROM workspace_branch_operations WHERE destination_environment_key = ?",
  );
  const read = (operationId: string): BranchRow | undefined =>
    query.get(operationId) as BranchRow | undefined;

  const publicResult = (row: BranchRow): PreparedWorkspaceBranch => {
    if (
      row.state !== "ready" ||
      row.destination_workspace_id === null ||
      row.destination_workspace_lease_id === null
    ) {
      throw brokerError("workspace.conflict", "workspace branch is not ready", {
        operationId: row.operation_id,
        state: row.state,
      });
    }
    return {
      operationId: row.operation_id,
      state: "ready",
      sourceEnvironmentKey: row.source_environment_key,
      destinationEnvironmentKey: row.destination_environment_key,
      sourceWorkspaceId: row.source_workspace_id,
      destinationWorkspaceId: row.destination_workspace_id,
      destinationWorkspaceLeaseId: row.destination_workspace_lease_id,
    };
  };


  const prepare = (
    request: PrepareWorkspaceBranchRequest,
  ): Effect.Effect<PreparedWorkspaceBranch, BrokerError> =>
    Effect.gen(function* () {
      if (request.sourceEnvironmentKey === request.destinationEnvironmentKey) {
        return yield* brokerError("workspace.conflict", "branch source and destination must differ");
      }
      let row = read(request.operationId);
      if (
        row !== undefined &&
        (
          row.source_environment_key !== request.sourceEnvironmentKey ||
          row.destination_environment_key !== request.destinationEnvironmentKey
        )
      ) {
        return yield* brokerError(
          "workspace.conflict",
          "workspace branch operation facts changed",
          { operationId: request.operationId },
        );
      }
      const sourceAuthority = yield* requireAuthorityBinding(
        registry,
        config,
        request.sourceEnvironmentKey,
      );
      if (row === undefined) {
        const destinationOperation = destinationQuery.get(
          request.destinationEnvironmentKey,
        ) as BranchRow | undefined;
        if (destinationOperation !== undefined) {
          return yield* brokerError("workspace.conflict", "branch destination is already prepared", {
            destinationEnvironmentKey: request.destinationEnvironmentKey,
          });
        }
        const existingDestination = yield* registry.getAuthority(request.destinationEnvironmentKey);
        if (existingDestination !== undefined) {
          return yield* brokerError("authority.conflict", "branch destination already has authority", {
            destinationEnvironmentKey: request.destinationEnvironmentKey,
          });
        }
        const now = Date.now();
        yield* Effect.try({
          try: () => db.prepare(`
            INSERT INTO workspace_branch_operations (
              operation_id, source_environment_key, destination_environment_key,
              source_workspace_id, destination_workspace_id,
              destination_workspace_lease_id, state, created_at, updated_at
            ) VALUES (?, ?, ?, ?, NULL, NULL, 'planned', ?, ?)
          `).run(
            request.operationId,
            request.sourceEnvironmentKey,
            request.destinationEnvironmentKey,
            sourceAuthority.workspaceId,
            now,
            now,
          ),
          catch: (error) => branchFailure("journal creation", error),
        });
        row = read(request.operationId);
      }
      if (row === undefined) {
        return yield* brokerError("workspace.failed", "workspace branch journal is unavailable");
      }
      if (row.source_workspace_id !== sourceAuthority.workspaceId) {
        return yield* brokerError("workspace.conflict", "branch source workspace changed", {
          operationId: request.operationId,
        });
      }
      if (row.state === "ready") return publicResult(row);

      return yield* environments.runWithEnvironmentStopped(
        request.sourceEnvironmentKey,
        Effect.gen(function* () {
          let current = read(request.operationId);
          if (current === undefined) {
            return yield* brokerError("workspace.failed", "workspace branch journal disappeared");
          }
          const source = yield* workspaces.resolve(
            request.sourceEnvironmentKey,
            sourceAuthority.workspaceId,
            sourceAuthority.workspaceLeaseId,
          );
          const operationRoot = path.join(stagingRoot, request.operationId);
          const stagedData = path.join(operationRoot, "data");

          if (current.state === "planned") {
            yield* Effect.tryPromise({
              try: async () => {
                await assertDirectory(source.workspacePath, "source workspace");
                await fs.rm(operationRoot, { recursive: true, force: true });
                await fs.mkdir(operationRoot, { recursive: false, mode: 0o700 });
                await fs.cp(source.workspacePath, stagedData, {
                  recursive: true,
                  force: false,
                  errorOnExist: true,
                  dereference: false,
                  verbatimSymlinks: true,
                  preserveTimestamps: true,
                });
                await assertDirectory(stagedData, "staged branch workspace");
              },
              catch: (error) => branchFailure("copy", error),
            });
            yield* Effect.try({
              try: () => db.prepare(
                "UPDATE workspace_branch_operations SET state='copy_ready', updated_at=? WHERE operation_id=? AND state='planned'",
              ).run(Date.now(), request.operationId),
              catch: (error) => branchFailure("copy journal", error),
            });
            current = read(request.operationId)!;
          }

          if (current.state === "copy_ready") {
            const destination = yield* workspaces.acquire(request.destinationEnvironmentKey);
            yield* Effect.try({
              try: () => db.prepare(`
                UPDATE workspace_branch_operations
                SET destination_workspace_id=?, destination_workspace_lease_id=?,
                    state='destination_allocated', updated_at=?
                WHERE operation_id=? AND state='copy_ready'
              `).run(
                destination.workspace.workspaceId,
                destination.lease.leaseId,
                Date.now(),
                request.operationId,
              ),
              catch: (error) => branchFailure("destination journal", error),
            });
            current = read(request.operationId)!;
          }

          if (
            current.state !== "destination_allocated" ||
            current.destination_workspace_id === null ||
            current.destination_workspace_lease_id === null
          ) {
            return yield* brokerError("workspace.conflict", "workspace branch journal has invalid state", {
              operationId: request.operationId,
              state: current.state,
            });
          }
          const destination = yield* workspaces.resolve(
            request.destinationEnvironmentKey,
            current.destination_workspace_id,
            current.destination_workspace_lease_id,
          );
          yield* Effect.tryPromise({
            try: async () => {
              const stagedExists = await fs.lstat(stagedData).then(() => true, () => false);
              if (stagedExists) {
                if (!(await directoryIsEmpty(destination.workspacePath))) {
                  throw brokerError("workspace.conflict", "branch destination is not empty");
                }
                await fs.rm(destination.workspacePath, { recursive: true, force: false });
                await fs.rename(stagedData, destination.workspacePath);
              }
              await assertDirectory(destination.workspacePath, "installed branch workspace");
            },
            catch: (error) => branchFailure("installation", error),
          });
          yield* registry.bindAuthority({
            environmentKey: request.destinationEnvironmentKey,
            profile: sourceAuthority.profile,
            executor: sourceAuthority.executor,
            authorityClass: sourceAuthority.authorityClass,
            policyDigest: sourceAuthority.policyDigest,
            workspaceId: current.destination_workspace_id,
            workspaceLeaseId: current.destination_workspace_lease_id,
          });
          yield* Effect.try({
            try: () => db.prepare(
              "UPDATE workspace_branch_operations SET state='ready', updated_at=? WHERE operation_id=? AND state='destination_allocated'",
            ).run(Date.now(), request.operationId),
            catch: (error) => branchFailure("ready journal", error),
          });
          current = read(request.operationId)!;
          return publicResult(current);
        }),
      );
    });

  return { prepare } satisfies WorkspaceBranchService;
});

export const WorkspaceBranchesLive = Layer.effect(WorkspaceBranches, make);
