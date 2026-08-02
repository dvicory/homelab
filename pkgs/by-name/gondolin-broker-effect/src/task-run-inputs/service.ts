import { randomUUID } from "node:crypto";
import * as fs from "node:fs/promises";
import * as fsSync from "node:fs";
import * as path from "node:path";
import { Context, Effect, Layer, Schema } from "effect";
import { BrokerConfig } from "../config.js";
import { BrokerDatabase } from "../database.js";
import type { ActivateTaskRunRequest } from "../domain.js";
import { BrokerError, brokerError } from "../errors.js";
import {
  InputPreparationLimits,
  PrepareTaskRunInputsRequest,
  type InputPreparationLimits as InputLimits,
  type PrepareTaskRunInputsRequest as PrepareRequest,
  type TaskRunInput,
} from "./model.js";
import { InputPreparationRepository, type InputPreparationRecord } from "./repository.js";
export type ReclaimStatus = "deleted" | "retained" | "skipped";
export type ReleaseResult = {
  readonly released: number;
  readonly deleted: ReadonlyArray<string>;
};

export interface InputPreparationService {
  readonly prepare: (request: PrepareRequest) => Effect.Effect<{
    readonly preparationId: string;
    readonly inputs: ReadonlyArray<{
      readonly producerTaskId: string;
      readonly guestPath: string;
    }>;
  }, BrokerError>;
  readonly validateActivation: (request: ActivateTaskRunRequest) => Effect.Effect<void, BrokerError>;
  readonly materialize: (request: ActivateTaskRunRequest, workspacePath: string) => Effect.Effect<void, BrokerError>;
  readonly release: (preparationId: string) => Effect.Effect<void, BrokerError>;
  readonly releaseTask: (environmentKey: string, taskId: string) => Effect.Effect<ReleaseResult, BrokerError>;
  readonly releaseRun: (environmentKey: string, taskId: string, runId: string | number) => Effect.Effect<ReleaseResult, BrokerError>;
  readonly markReclaimable: (handoffIds: ReadonlyArray<string>) => Effect.Effect<{
    readonly results: ReadonlyArray<{ readonly handoffId: string; readonly status: ReclaimStatus }>;
  }, BrokerError>;
}

export class InputPreparations extends Context.Tag(
  "@agent-x/gondolin-broker-effect/InputPreparations",
)<InputPreparations, InputPreparationService>() {}

const decodeRequest = Schema.decodeUnknownSync(PrepareTaskRunInputsRequest, { onExcessProperty: "error" });
const canonicalJson = (value: unknown): string => JSON.stringify(value, (_key, nested) => {
  if (nested === null || typeof nested !== "object" || Array.isArray(nested)) return nested;
  return Object.fromEntries(Object.entries(nested).sort(([left], [right]) => left.localeCompare(right)));
});
const runString = (runId: string | number): string => String(runId);
const preparationFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("handoff.failed", `input preparation ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });
const stableNotReady = (
  producerTaskId: string,
  reason: "missing" | "incomplete" | "failed" | "ambiguous" | "expired" | "quarantined" | "publication_failed",
): BrokerError => brokerError("inputs.producer_not_ready", `producer handoff is ${reason}`, { producerTaskId, reason });
const sourceOutput = (root: string, handoffId: string): string => path.join(root, "ready", handoffId, "output");
const qualifiedTaskPrefix = (board: string): string => `b${board.length}:${board}:t`;
const isBoardTaskIdentity = (board: string, taskId: string): boolean =>
  taskId.startsWith(qualifiedTaskPrefix(board));
const isRunForTask = (taskId: string, runId: string | number): boolean =>
  typeof runId === "string" && runId.startsWith(`${taskId}:r`);

const chmodReadOnly = async (root: string): Promise<void> => {
  const pending = [root];
  while (pending.length > 0) {
    const directory = pending.pop()!;
    const directoryStat = await fs.lstat(directory);
    if (directoryStat.isSymbolicLink() || !directoryStat.isDirectory()) throw brokerError("handoff.failed", "prepared input contains a non-directory node");
    await fs.chmod(directory, 0o550);
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      const stat = await fs.lstat(absolute);
      if (stat.isDirectory()) pending.push(absolute);
      else if (stat.isFile()) await fs.chmod(absolute, 0o440);
      else throw brokerError("handoff.failed", "prepared input contains an unsupported node");
    }
  }
};
const removeMaterializedTree = async (root: string): Promise<void> => {
  const rootStat = await fs.lstat(root).catch(() => null);
  if (rootStat === null) return;
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    await fs.rm(root, { force: true });
    return;
  }
  const pending = [root];
  while (pending.length > 0) {
    const directory = pending.pop()!;
    await fs.chmod(directory, 0o750);
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      const stat = await fs.lstat(absolute);
      if (stat.isDirectory() && !stat.isSymbolicLink()) pending.push(absolute);
      else if (stat.isFile()) await fs.chmod(absolute, 0o640);
    }
  }
  await fs.rm(root, { recursive: true, force: true });
};
const completeManifestMaxPathBytes = (root: string): number => {
  const pending: Array<{ readonly absolute: string; readonly relative: string }> = [{
    absolute: root,
    relative: "",
  }];
  let maximum = 0;
  while (pending.length > 0) {
    const directory = pending.pop()!;
    for (const entry of fsSync.readdirSync(directory.absolute, { withFileTypes: true })) {
      const relative = directory.relative.length === 0 ? entry.name : `${directory.relative}/${entry.name}`;
      maximum = Math.max(maximum, Buffer.byteLength(relative, "utf8"));
      const absolute = path.join(directory.absolute, entry.name);
      const stat = fsSync.lstatSync(absolute);
      if (stat.isDirectory() && !stat.isSymbolicLink()) {
        pending.push({ absolute, relative });
      } else if (!stat.isFile() || stat.isSymbolicLink()) {
        throw brokerError("handoff.failed", "prepared input contains an unsupported node", { path: relative });
      }
    }
  }
  return maximum;
};

const compareFacts = (existing: InputPreparationRecord, request: PrepareRequest): boolean =>
  existing.environmentKey === request.environmentKey &&
  existing.board === request.board &&
  existing.taskId === request.taskId &&
  runString(existing.runId) === runString(request.runId) &&
  existing.generation === request.generation &&
  existing.digest === request.digest &&
  existing.lane === request.lane &&
  existing.laneRevision === request.laneRevision &&
  existing.policyRevision === request.policyRevision &&
  canonicalJson(existing.limits) === canonicalJson(request.limits) &&
  canonicalJson(existing.inputs) === canonicalJson(request.inputs);

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const database = yield* BrokerDatabase;
  const repository = yield* InputPreparationRepository;
  const db = database.connection;

  const validateInputs = (request: PrepareRequest): void => {
    if (Schema.decodeUnknownSync(InputPreparationLimits)(request.limits).maxInputs <= 0) throw brokerError("inputs.limit", "input count limit must be positive");
    if (!isBoardTaskIdentity(request.board, request.taskId)) {
      throw brokerError("inputs.cross_board", "destination task identity does not belong to the requested board");
    }
    if (!isRunForTask(request.taskId, request.runId)) {
      throw brokerError("inputs.conflict", "destination run identity does not belong to the destination task");
    }
    if (request.inputs.length > request.limits.maxInputs) throw brokerError("inputs.limit", "input count exceeds broker input limit", { maxInputs: request.limits.maxInputs });
    const seenTasks = new Set<string>();
    const seenMounts = new Set<string>();
    for (const input of request.inputs) {
      if (!isBoardTaskIdentity(request.board, input.producerTaskId)) {
        throw brokerError("inputs.cross_board", "producer task identity does not belong to the destination board", { producerTaskId: input.producerTaskId });
      }
      if (!isRunForTask(input.producerTaskId, input.producerRunId)) {
        throw brokerError("inputs.conflict", "producer run identity does not belong to the producer task", { producerTaskId: input.producerTaskId });
      }
      if (seenTasks.has(input.producerTaskId)) throw brokerError("inputs.conflict", "producer task is listed more than once", { producerTaskId: input.producerTaskId });
      if (seenMounts.has(input.mountName)) throw brokerError("inputs.conflict", "input mount name is listed more than once", { mountName: input.mountName });
      seenTasks.add(input.producerTaskId);
      seenMounts.add(input.mountName);
    }
  };

  const validateHandoff = (request: PrepareRequest, input: TaskRunInput): { readonly bytes: number; readonly entries: number } => {
    const rows = db.prepare(`
      SELECT handoff_id, source_task_id, source_run_id, authority_facts_json, state,
             entry_count, total_bytes, failure_reason
      FROM workspace_handoffs WHERE source_task_id = ? AND source_run_id = ?
    `).all(input.producerTaskId, runString(input.producerRunId)) as Array<{
      handoff_id: string; source_task_id: string; source_run_id: string; authority_facts_json: string;
      state: "staging" | "ready" | "quarantined" | "failed"; entry_count: number; total_bytes: number;
      failure_reason: string | null;
    }>;
    const selected = rows.find((row) => row.handoff_id === input.handoffId);
    if (selected === undefined) {
      if (rows.length === 0) throw stableNotReady(input.producerTaskId, "missing");
      if (rows.some((row) => row.state === "staging")) throw stableNotReady(input.producerTaskId, "incomplete");
      if (rows.some((row) => row.state === "quarantined")) throw stableNotReady(input.producerTaskId, "quarantined");
      if (rows.some((row) => row.state === "failed")) throw stableNotReady(input.producerTaskId, "failed");
      throw stableNotReady(input.producerTaskId, "ambiguous");
    }
    let authority: Readonly<Record<string, unknown>>;
    try {
      authority = JSON.parse(selected.authority_facts_json) as Readonly<Record<string, unknown>>;
    } catch {
      throw brokerError("handoff.failed", "producer handoff authority facts are invalid", { producerTaskId: input.producerTaskId });
    }
    if (
      authority.lane !== input.producerLane ||
      (typeof authority.project === "string" ? authority.project : undefined) !== input.producerProject ||
      (typeof authority.sourceGeneration === "string" ? authority.sourceGeneration : undefined) !== input.producerSourceGeneration
    ) {
      throw brokerError("inputs.conflict", "producer provenance does not match the frozen handoff", { producerTaskId: input.producerTaskId });
    }
    if (
      selected.source_task_id !== input.producerTaskId ||
      selected.source_run_id !== runString(input.producerRunId)
    ) {
      throw brokerError("inputs.cross_board", "handoff source identity does not match the board-qualified producer", { producerTaskId: input.producerTaskId });
    }
    if (selected.state !== "ready") {
      const failure = selected.failure_reason ?? "";
      const reason = failure.includes("expired") ? "expired" : failure.includes("publication_failed") ? "publication_failed" : selected.state === "quarantined" ? "quarantined" : selected.state === "failed" ? "failed" : "incomplete";
      throw stableNotReady(input.producerTaskId, reason);
    }
    if (rows.filter((row) => row.state === "ready").length !== 1) throw stableNotReady(input.producerTaskId, "ambiguous");
    const pathBytes = completeManifestMaxPathBytes(
      sourceOutput(config.workspaceHandoffRoot, selected.handoff_id),
    );
    if (pathBytes > request.limits.maxInputPathBytes) throw brokerError("inputs.limit", "producer handoff path exceeds broker input limit", { producerTaskId: input.producerTaskId });
    return { bytes: selected.total_bytes, entries: selected.entry_count };
  };

  const prepare = (raw: PrepareRequest) => Effect.try({
    try: () => {
      const request = decodeRequest(raw);
      const existing = repository.getByRun(request.taskId, request.runId);
      if (existing !== null) {
        if (!compareFacts(existing, request)) throw brokerError("inputs.conflict", "input preparation replay facts differ", { preparationId: existing.preparationId });
        return { preparationId: existing.preparationId, inputs: existing.inputs.map((input) => ({ producerTaskId: input.producerTaskId, mountName: input.mountName, guestPath: `/workspace/inputs/${input.mountName}` })) };
      }
      validateInputs(request);
      let totalBytes = 0;
      let totalEntries = 0;
      for (const input of request.inputs) {
        const summary = validateHandoff(request, input);
        totalBytes += summary.bytes;
        totalEntries += summary.entries;
      }
      if (totalBytes > request.limits.maxInputBytes || totalEntries > request.limits.maxInputEntries) {
        throw brokerError("inputs.limit", "input manifests exceed broker input limits", {
          maxInputBytes: request.limits.maxInputBytes,
          maxInputEntries: request.limits.maxInputEntries,
        });
      }
      const record = repository.create(request, request.inputs.map(({ handoffId }) => handoffId));
      return {
        preparationId: record.preparationId,
        inputs: request.inputs.map((input) => ({
          producerTaskId: input.producerTaskId,
          mountName: input.mountName,
          guestPath: `/workspace/inputs/${input.mountName}`,
        })),
      };
    },
    catch: (error) => preparationFailure("prepare", error),
  });

  const getActivationPreparation = (request: ActivateTaskRunRequest): InputPreparationRecord | null => {
    if (request.inputPreparationId === undefined || request.inputPreparationId === null) return null;
    const record = repository.getById(request.inputPreparationId);
    if (record === null || record.state !== "prepared") throw brokerError("inputs.not_found", "input preparation does not exist");
    if (
      record.environmentKey !== request.environmentKey ||
      record.taskId !== request.taskId ||
      runString(record.runId) !== runString(request.runId) ||
      record.lane !== request.lane ||
      record.laneRevision !== request.laneRevision ||
      record.policyRevision !== request.policyRevision ||
      (request.inputGeneration !== undefined && record.generation !== request.inputGeneration) ||
      (request.inputDigest !== undefined && record.digest !== request.inputDigest)
    ) throw brokerError("inputs.conflict", "activation does not match prepared input facts", { preparationId: record.preparationId });
    if (request.inputGeneration === undefined || request.inputDigest === undefined) throw brokerError("inputs.conflict", "activation is missing prepared input generation facts", { preparationId: record.preparationId });
    return record;
  };

  const validateActivation = (request: ActivateTaskRunRequest) => Effect.try({ try: () => { getActivationPreparation(request); }, catch: (error) => preparationFailure("activation validation", error) });

  const materialize = (request: ActivateTaskRunRequest, workspacePath: string) => Effect.tryPromise({
    try: async () => {
      const record = getActivationPreparation(request);
      const inputsRoot = path.join(workspacePath, "inputs");
      await fs.mkdir(inputsRoot, { recursive: true, mode: 0o750 });
      await fs.chmod(inputsRoot, 0o750);
      if (record === null) {
        await fs.chmod(inputsRoot, 0o550);
        return;
      }
      // Stage beside, never inside, the mounted workspace. A prior live
      // generation can still read its workspace until activation fences it.
      const stagingRoot = path.join(path.dirname(workspacePath), ".input-staging");
      await fs.mkdir(stagingRoot, { recursive: true, mode: 0o700 });
      await fs.chmod(stagingRoot, 0o700);
      const created: string[] = [];
      try {
        for (const input of record.inputs) {
          const destination = path.join(inputsRoot, input.mountName);
          const source = sourceOutput(config.workspaceHandoffRoot, input.handoffId);
          const sourceStat = await fs.lstat(source);
          if (!sourceStat.isDirectory() || sourceStat.isSymbolicLink()) throw stableNotReady(input.producerTaskId, "publication_failed");
          if (fsSync.existsSync(destination)) {
            // Published destinations are created only by the atomic rename
            // below. A replay repairs permissions and reuses the complete tree.
            await chmodReadOnly(destination);
            continue;
          }
          const staging = path.join(stagingRoot, `${input.mountName}-${randomUUID()}.staging`);
          try {
            await fs.cp(source, staging, { recursive: true, force: false, errorOnExist: true });
            await chmodReadOnly(staging);
            // Darwin requires the renamed directory itself to remain owner-writable.
            // Only the broker owner can write this root; descendants are already read-only.
            await fs.chmod(staging, 0o750);
            try {
              await fs.rename(staging, destination);
              await fs.chmod(destination, 0o550);
              created.push(destination);
            } catch (error) {
              // A concurrent identical replay may have won the rename.
              if (!fsSync.existsSync(destination)) throw error;
              await chmodReadOnly(destination);
            }
          } finally {
            await removeMaterializedTree(staging);
          }
        }
        await fs.chmod(inputsRoot, 0o550);
      } catch (error) {
        await Promise.all(created.map(removeMaterializedTree));
        await fs.chmod(inputsRoot, 0o550);
        throw error;
      }
    },
    catch: (error) => preparationFailure("materialize", error),
  });

  const releaseRecords = (records: ReadonlyArray<InputPreparationRecord>): ReleaseResult => {
    const handoffIds = new Set<string>();
    let released = 0;
    for (const record of records) {
      for (const input of record.inputs) handoffIds.add(input.handoffId);
      released += repository.releaseReferences(record.preparationId);
    }
    const deleted: string[] = [];
    for (const handoffId of handoffIds) {
      if (repository.deleteReclaimableHandoff(handoffId)) deleted.push(handoffId);
    }
    return { released, deleted };
  };
  const releaseTask = (environmentKey: string, taskId: string) => Effect.try({
    try: () => releaseRecords(repository.listByDestination(environmentKey, taskId)),
    catch: (error) => preparationFailure("release task", error),
  });
  const releaseRun = (environmentKey: string, taskId: string, runId: string | number) => Effect.try({
    try: () => {
      const preparation = repository.getByRun(taskId, runId);
      if (preparation !== null && preparation.environmentKey !== environmentKey) {
        throw brokerError("inputs.conflict", "input preparation belongs to a different destination environment");
      }
      return releaseRecords(preparation === null ? [] : [preparation]);
    },
    catch: (error) => preparationFailure("release run", error),
  });
  const markReclaimable = (handoffIds: ReadonlyArray<string>) => Effect.try({
    try: () => ({
      results: handoffIds.map((handoffId) => {
        const row = repository.markReclaimable(handoffId);
        if (row === null || row.state !== "ready") return { handoffId, status: "skipped" as const };
        return repository.deleteReclaimableHandoff(handoffId)
          ? { handoffId, status: "deleted" as const }
          : { handoffId, status: "retained" as const };
      }),
    }),
    catch: (error) => preparationFailure("mark reclaimable", error),
  });
  const release = (preparationId: string) => Effect.try({
    try: () => { repository.releaseReferences(preparationId); },
    catch: (error) => preparationFailure("release", error),
  });
  return { prepare, validateActivation, materialize, release, releaseTask, releaseRun, markReclaimable } satisfies InputPreparationService;
});

export const InputPreparationsLive = Layer.effect(InputPreparations, make);
