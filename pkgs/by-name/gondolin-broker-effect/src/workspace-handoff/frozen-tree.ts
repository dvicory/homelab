import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { Context, Effect, Layer, Schema } from "effect";
import { HandoffRelativePath } from "./model.js";
import { BrokerConfig } from "../config.js";
import {
  assertSnapshotUnchanged,
  copyFrozenOutput,
  copyOutputToTemp,
  outputPathForWorkspace,
  preflightOutput,
  syncDirectory,
  validateFrozenOutput,
  type HandoffLimits,
  type OutputSnapshot,
} from "./capture.js";
import { BrokerError, brokerError } from "../errors.js";
import { HandoffStore, type ExportRecord, type HandoffRecord } from "./repository.js";

export type { HandoffLimits } from "./capture.js";

export interface ExportFileStream {
  readonly fileName: string;
  readonly byteSize: number;
  readonly body: AsyncIterable<Uint8Array>;
}

export interface HandoffStorageService {
  readonly preflightOutput: (
    sourceWorkspacePath: string,
    limits: HandoffLimits,
    selectedArtifacts?: ReadonlyArray<string>,
  ) => Effect.Effect<OutputSnapshot, BrokerError>;
  readonly captureHandoff: (
    handoff: HandoffRecord,
    sourceWorkspacePath: string,
    limits: HandoffLimits,
    preflight: OutputSnapshot,
  ) => Effect.Effect<OutputSnapshot, BrokerError>;
  readonly validateHandoff: (
    handoff: HandoffRecord,
    limits: HandoffLimits,
  ) => Effect.Effect<OutputSnapshot, BrokerError>;
  readonly materializeHandoff: (
    handoff: HandoffRecord,
    destinationWorkspacePath: string,
    limits: HandoffLimits,
  ) => Effect.Effect<OutputSnapshot, BrokerError>;
  readonly inspectExportFile: (
    handoffId: string,
    relativePath: string,
  ) => Effect.Effect<{ readonly fileName: string; readonly byteSize: number }, BrokerError>;
  readonly openExport: (
    exportRecord: ExportRecord,
  ) => Effect.Effect<ExportFileStream, BrokerError>;
  readonly reconcile: () => Effect.Effect<void, BrokerError>;
}

export class HandoffStorage extends Context.Tag("@agent-x/gondolin-broker-effect/HandoffStorage")<
  HandoffStorage,
  HandoffStorageService
>() {}


const STAGING_NAME = "staging";
const READY_NAME = "ready";
const QUARANTINE_NAME = "quarantine";
const DEFAULT_RECONCILE_LIMITS: HandoffLimits = {
  maxLogicalBytes: Number.MAX_SAFE_INTEGER,
  maxEntries: 10_000_000,
  maxFileBytes: Number.MAX_SAFE_INTEGER,
  maxPathBytes: 4096,
};
const MAX_RECONCILE_ENTRIES = 10_000;
const NO_FOLLOW = constants.O_NOFOLLOW;
const decodeRelativePath = Schema.decodeUnknownSync(HandoffRelativePath, { onExcessProperty: "error" });

const storageFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("handoff.failed", `handoff storage ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });
export const isTerminalCaptureFailure = (error: unknown): boolean => {
  if (!(error instanceof BrokerError)) return false;
  if (error.reason === "handoff.conflict" || error.reason === "request.invalid") return true;
  if (error.reason !== "handoff.failed") return false;
  return error.details === undefined || !Object.hasOwn(error.details, "cause");
};

const exists = async (candidate: string): Promise<boolean> =>
  fs.lstat(candidate).then(() => true, (error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return false;
    throw error;
  });

const handoffPath = (root: string, area: string, handoffId: string): string => path.join(root, area, handoffId);

const summaryLimits = (handoff: HandoffRecord): HandoffLimits => ({
  maxLogicalBytes: Math.max(1, handoff.totalBytes),
  maxEntries: Math.max(1, handoff.entryCount),
  maxFileBytes: Math.max(1, handoff.totalBytes),
  maxPathBytes: 4096,
});

const exportPathFor = (readyRoot: string, handoffId: string, relativePath: string): string =>
  path.join(readyRoot, handoffId, "output", ...relativePath.split("/"));

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  if (!config.workspaceHandoffEnabled) {
    const unavailable = () => Effect.fail(brokerError("policy.denied", "workspace handoff is disabled"));
    return {
      preflightOutput: unavailable,
      captureHandoff: unavailable,
      validateHandoff: unavailable,
      materializeHandoff: unavailable,
      inspectExportFile: unavailable,
      openExport: unavailable,
      reconcile: unavailable,
    } satisfies HandoffStorageService;
  }
  const store = yield* HandoffStore;
  const handoffRoot = config.workspaceHandoffRoot;
  const stagingRoot = path.join(handoffRoot, STAGING_NAME);
  const readyRoot = path.join(handoffRoot, READY_NAME);
  const quarantineRoot = path.join(handoffRoot, QUARANTINE_NAME);

  const initialize = async (): Promise<void> => {
    await fs.mkdir(stagingRoot, { recursive: true, mode: 0o700 });
    await fs.mkdir(readyRoot, { recursive: true, mode: 0o700 });
    await fs.mkdir(quarantineRoot, { recursive: true, mode: 0o700 });
    for (const root of [handoffRoot, stagingRoot, readyRoot, quarantineRoot]) {
      const stat = await fs.lstat(root, { bigint: true });
      if (!stat.isDirectory() || stat.isSymbolicLink()) throw brokerError("handoff.failed", "handoff storage root is not a real directory");
    }
  };

  yield* Effect.tryPromise({ try: initialize, catch: (error) => storageFailure("initialization", error) });

  const quarantine = async (candidate: string, handoffId: string, reason: string): Promise<void> => {
    if (!(await exists(candidate))) return;
    const safeReason = reason.replace(/[^A-Za-z0-9._-]/g, "-").slice(0, 64) || "failure";
    const destination = path.join(quarantineRoot, `${handoffId}-${Date.now()}-${randomUUID()}-${safeReason}`);
    await fs.rename(candidate, destination);
    await syncDirectory(quarantineRoot);
  };

  const readyOutput = (handoffId: string): string => path.join(readyRoot, handoffId, "output");

  const validateReady = async (handoff: HandoffRecord, limits: HandoffLimits): Promise<OutputSnapshot> => {
    if (handoff.state !== "ready") throw brokerError("handoff.invalid_state", "only a ready handoff can be used");
    const observed = await validateFrozenOutput(readyOutput(handoff.handoffId), limits);
    // The compact journal records summary counts only. A second structural pass
    // verifies the frozen tree without hashing or reading file content.
    if (observed.entryCount !== handoff.entryCount || observed.totalBytes !== handoff.totalBytes) {
      throw brokerError("handoff.failed", "frozen workspace output summary conflicts with broker state");
    }
    return observed;
  };

  const preflight = (sourceWorkspacePath: string, limits: HandoffLimits, selectedArtifacts: ReadonlyArray<string> = []) =>
    Effect.tryPromise({
      try: () => preflightOutput(sourceWorkspacePath, limits, selectedArtifacts),
      catch: (error) => storageFailure("preflight", error),
    });

  const capture = async (
    handoff: HandoffRecord,
    sourceWorkspacePath: string,
    limits: HandoffLimits,
    firstPreflight: OutputSnapshot,
  ): Promise<OutputSnapshot> => {
    if (handoff.state === "ready") return validateReady(handoff, limits);
    if (handoff.state !== "staging") throw brokerError("handoff.invalid_state", "only a staging handoff can be captured");
    const stagingPath = path.join(stagingRoot, `${handoff.handoffId}-${randomUUID()}`);
    const readyPath = handoffPath(handoffRoot, READY_NAME, handoff.handoffId);
    try {
      await fs.mkdir(stagingPath, { recursive: false, mode: 0o700 });
      const detached = await preflightOutput(sourceWorkspacePath, limits, handoff.selectedArtifacts);
      assertSnapshotUnchanged(firstPreflight, detached);
      await copyOutputToTemp(sourceWorkspacePath, stagingPath, detached);
      const stagedOutput = outputPathForWorkspace(stagingPath);
      const validated = await validateFrozenOutput(stagedOutput, limits);
      if (validated.entryCount !== detached.entryCount || validated.totalBytes !== detached.totalBytes) {
        throw brokerError("handoff.failed", "copied workspace output summary changed before publication");
      }
      await syncDirectory(stagingPath);
      if (await exists(readyPath)) {
        const existing = await validateFrozenOutput(readyOutput(handoff.handoffId), limits);
        if (existing.entryCount !== detached.entryCount || existing.totalBytes !== detached.totalBytes) {
          throw brokerError("handoff.conflict", "ready handoff conflicts with capture summary");
        }
        await quarantine(stagingPath, handoff.handoffId, "duplicate-capture");
        return existing;
      }
      await fs.rename(stagingPath, readyPath);
      await syncDirectory(stagingRoot);
      await syncDirectory(readyRoot);
      return validated;
    } catch (error) {
      if (isTerminalCaptureFailure(error)) {
        try {
          store.failHandoff(handoff.handoffId, "publication_failed", storageFailure("capture", error).message);
        } catch {
          // Reconciliation will journal a durable failure if the database was unavailable.
        }
      }
      throw storageFailure("capture", error);
    }
  };

  const materialize = async (
    handoff: HandoffRecord,
    destinationWorkspacePath: string,
    limits: HandoffLimits,
  ): Promise<OutputSnapshot> => {
    const source = await validateReady(handoff, limits);
    const destination = await fs.lstat(destinationWorkspacePath, { bigint: true });
    if (!destination.isDirectory() || destination.isSymbolicLink()) throw brokerError("handoff.failed", "destination workspace is not a real directory");
    await copyFrozenOutput(readyOutput(handoff.handoffId), destinationWorkspacePath, limits);
    return source;
  };

  const inspectExport = async (handoffId: string, relativePath: string): Promise<{ fileName: string; byteSize: number }> => {
    const normalizedPath = decodeRelativePath(relativePath);
    const handoff = store.getHandoff(handoffId);
    await validateReady(handoff, summaryLimits(handoff));
    const candidate = exportPathFor(readyRoot, handoffId, normalizedPath);
    const stat = await fs.lstat(candidate, { bigint: true });
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1n || (stat.mode & 0o444n) === 0n) {
      throw brokerError("handoff.failed", "workspace export path is not a readable regular file");
    }
    const byteSize = Number(stat.size);
    return { fileName: path.basename(normalizedPath), byteSize };
  };

  const openExport = async (exportRecord: ExportRecord): Promise<ExportFileStream> => {
    const normalizedPath = decodeRelativePath(exportRecord.relativePath);
    const handoff = store.getHandoff(exportRecord.handoffId);
    await validateReady(handoff, summaryLimits(handoff));
    const candidate = exportPathFor(readyRoot, exportRecord.handoffId, normalizedPath);
    const initial = await fs.lstat(candidate, { bigint: true });
    if (!initial.isFile() || initial.isSymbolicLink() || initial.nlink !== 1n || Number(initial.size) !== exportRecord.byteSize) {
      throw brokerError("handoff.failed", "workspace export file changed after preparation");
    }
    const body = async function* (): AsyncGenerator<Uint8Array> {
      const handle = await fs.open(candidate, constants.O_RDONLY | NO_FOLLOW);
      try {
        const stat = await handle.stat({ bigint: true });
        if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1n || Number(stat.size) !== exportRecord.byteSize) {
          throw brokerError("handoff.failed", "workspace export file changed before streaming");
        }
        const buffer = Buffer.allocUnsafe(64 * 1024);
        let offset = 0;
        while (offset < exportRecord.byteSize) {
          const { bytesRead } = await handle.read(buffer, 0, Math.min(buffer.byteLength, exportRecord.byteSize - offset), offset);
          if (bytesRead === 0) throw brokerError("handoff.failed", "workspace export ended before its expected size");
          offset += bytesRead;
          yield Buffer.from(buffer.subarray(0, bytesRead));
        }
      } finally {
        await handle.close();
      }
    };
    return { fileName: exportRecord.fileName, byteSize: exportRecord.byteSize, body: body() };
  };

  const reconcilePromise = async (): Promise<void> => {
    const known = new Set(store.listHandoffs(["staging", "ready"]).map((handoff) => handoff.handoffId));
    for (const handoff of store.listHandoffs(["staging"])) {
      const readyPath = handoffPath(handoffRoot, READY_NAME, handoff.handoffId);
      if (await exists(readyPath)) {
        try {
          const observed = await validateFrozenOutput(readyOutput(handoff.handoffId), DEFAULT_RECONCILE_LIMITS);
          store.markHandoffReady(handoff.handoffId, observed.entryCount, observed.totalBytes);
        } catch (error) {
          await quarantine(readyPath, handoff.handoffId, "invalid-ready");
          store.failHandoff(handoff.handoffId, "quarantined", storageFailure("reconcile", error).message);
        }
    }
    }
    for (const handoff of store.listHandoffs(["ready"])) {
      try {
        await validateReady(handoff, DEFAULT_RECONCILE_LIMITS);
      } catch (error) {
        await quarantine(handoffPath(handoffRoot, READY_NAME, handoff.handoffId), handoff.handoffId, "verification-failure");
        store.failHandoff(handoff.handoffId, "quarantined", storageFailure("reconcile", error).message);
      }
    }
    for (const [root, area] of [[stagingRoot, "staging"], [readyRoot, "ready"]] as const) {
      const directory = await fs.opendir(root, { bufferSize: 32 });
      let examined = 0;
      try {
        while (true) {
          const entry = await directory.read();
          if (entry === null) break;
          const name = entry.name;
          examined += 1;
          if (examined > MAX_RECONCILE_ENTRIES) {
            throw brokerError("handoff.failed", "handoff reconciliation entry limit exceeded");
          }
          const id = root === readyRoot
            ? name
            : [...known].find((candidate) => name.startsWith(`${candidate}-`)) ?? name;
          if (root === readyRoot && known.has(id)) continue;
          await quarantine(path.join(root, name), id, area === "staging" ? "stale-staging" : "orphan");
        }
      } finally {
        await directory.close();
      }
    }
    store.expireExports();
  };

  yield* Effect.tryPromise({ try: reconcilePromise, catch: (error) => storageFailure("reconciliation", error) });

  return {
    preflightOutput: preflight,
    captureHandoff: (handoff, sourceWorkspacePath, limits, firstPreflight) => Effect.tryPromise({
      try: () => capture(handoff, sourceWorkspacePath, limits, firstPreflight),
      catch: (error) => storageFailure("capture", error),
    }),
    validateHandoff: (handoff, limits) => Effect.tryPromise({
      try: () => validateReady(handoff, limits),
      catch: (error) => storageFailure("validate", error),
    }),
    materializeHandoff: (handoff, destinationWorkspacePath, limits) => Effect.tryPromise({
      try: () => materialize(handoff, destinationWorkspacePath, limits),
      catch: (error) => storageFailure("materialize", error),
    }),
    inspectExportFile: (handoffId, relativePath) => Effect.tryPromise({
      try: () => inspectExport(handoffId, relativePath),
      catch: (error) => storageFailure("inspect export", error),
    }),
    openExport: (exportRecord) => Effect.tryPromise({
      try: () => openExport(exportRecord),
      catch: (error) => storageFailure("open export", error),
    }),
    reconcile: () => Effect.tryPromise({ try: reconcilePromise, catch: (error) => storageFailure("reconcile", error) }),
  } satisfies HandoffStorageService;
});

export const HandoffStorageLive = Layer.effect(HandoffStorage, make);
