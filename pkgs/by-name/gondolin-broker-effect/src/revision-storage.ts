import { constants } from "node:fs";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { Context, Effect, Layer } from "effect";
import { BrokerConfig } from "./config.js";
import {
  copySelectedRoots,
  copyTree,
  inspectTree,
  makeTreeReadOnly,
  syncDirectory,
  type RevisionLimits,
} from "./revision-copy.js";
import { BrokerError, brokerError } from "./errors.js";
import {
  makeRevisionManifest,
  parseRevisionManifest,
  serializeRevisionManifest,
  type RevisionManifest,
} from "./revision-manifest.js";
import { RevisionStore, type RevisionRecord } from "./revision-store.js";

export type { RevisionLimits } from "./revision-copy.js";

export interface RevisionStorageService {
  readonly stageRevision: (
    revisionId: string,
    sourceWorkspacePath: string,
    limits: RevisionLimits,
  ) => Effect.Effect<RevisionRecord, BrokerError>;
  readonly verifyRevision: (revisionId: string) => Effect.Effect<RevisionManifest, BrokerError>;
  readonly materializeRevision: (
    revisionId: string,
    destinationWorkspacePath: string,
  ) => Effect.Effect<RevisionManifest, BrokerError>;
  readonly reconcile: () => Effect.Effect<void, BrokerError>;
}

export class RevisionStorage extends Context.Tag("@agent-x/gondolin-broker-effect/RevisionStorage")<
  RevisionStorage,
  RevisionStorageService
>() {}

const MANIFEST_NAME = "manifest.json";
const TREE_NAME = "tree";
const STAGING_NAME = "staging";
const READY_NAME = "ready";
const QUARANTINE_NAME = "quarantine";

const storageFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("revision.failed", `revision storage ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const exists = async (candidate: string): Promise<boolean> =>
  fs.lstat(candidate).then(() => true, (error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return false;
    throw error;
  });

const summaryLimits = (revision: RevisionRecord): RevisionLimits => ({
  maxLogicalBytes: Math.max(1, revision.logicalBytes),
  maxEntries: Math.max(1, revision.entryCount),
  maxFileBytes: Math.max(1, revision.logicalBytes),
  maxPathBytes: 4096,
});

const make = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  if (!config.workspaceHandoffEnabled) {
    const unavailable = () => Effect.fail(brokerError("policy.denied", "workspace handoff is disabled"));
    return {
      stageRevision: unavailable,
      verifyRevision: unavailable,
      materializeRevision: unavailable,
      reconcile: unavailable,
    } satisfies RevisionStorageService;
  }
  const store = yield* RevisionStore;
  const stagingRoot = path.join(config.workspaceRevisionRoot, STAGING_NAME);
  const readyRoot = path.join(config.workspaceRevisionRoot, READY_NAME);
  const quarantineRoot = path.join(config.workspaceRevisionRoot, QUARANTINE_NAME);

  const initialize = async (): Promise<void> => {
    await fs.mkdir(stagingRoot, { recursive: true, mode: 0o700 });
    await fs.mkdir(readyRoot, { recursive: true, mode: 0o700 });
    await fs.mkdir(quarantineRoot, { recursive: true, mode: 0o700 });
  };

  const quarantine = async (candidate: string, revisionId: string, reason: string): Promise<void> => {
    if (!(await exists(candidate))) return;
    await fs.rename(candidate, path.join(quarantineRoot, `${revisionId}-${Date.now()}-${reason}`));
    await syncDirectory(quarantineRoot);
  };

  const verifyPath = async (
    revisionPath: string,
    revision: RevisionRecord,
  ): Promise<RevisionManifest> => {
    const rootNames = (await fs.readdir(revisionPath)).sort();
    if (rootNames.length !== 2 || rootNames[0] !== MANIFEST_NAME || rootNames[1] !== TREE_NAME) {
      throw brokerError("revision.failed", "revision root contains unexpected entries");
    }
    const manifestPath = path.join(revisionPath, MANIFEST_NAME);
    const treePath = path.join(revisionPath, TREE_NAME);
    const manifestStat = await fs.lstat(manifestPath, { bigint: true });
    const treeStat = await fs.lstat(treePath, { bigint: true });
    if (
      !manifestStat.isFile() || manifestStat.isSymbolicLink() || Number(manifestStat.mode & 0o777n) !== 0o444 ||
      !treeStat.isDirectory() || treeStat.isSymbolicLink() || Number(treeStat.mode & 0o777n) !== 0o555
    ) throw brokerError("revision.failed", "revision root metadata is invalid");

    const manifest = parseRevisionManifest(await fs.readFile(manifestPath, "utf8"));
    if (manifest.version !== revision.manifestVersion) {
      throw brokerError("revision.failed", "revision manifest version conflicts with broker state");
    }
    const entries = await inspectTree(treePath, summaryLimits({
      ...revision,
      logicalBytes: Math.max(revision.logicalBytes, manifest.entries.reduce((sum, entry) => sum + entry.byteLength, 0)),
      entryCount: Math.max(revision.entryCount, manifest.entries.length),
    }), false);
    const observed = makeRevisionManifest(entries);
    for (const entry of entries) {
      const stat = await fs.lstat(path.join(treePath, ...entry.path.split("/")), { bigint: true });
      const expectedMode = entry.kind === "directory" || entry.mode === 0o755 ? 0o555 : 0o444;
      if (Number(stat.mode & 0o777n) !== expectedMode) {
        throw brokerError("revision.failed", "revision entry is not read-only", { path: entry.path });
      }
    }
    if (observed.manifestDigest !== manifest.manifestDigest) {
      throw brokerError("revision.failed", "revision content does not match its manifest");
    }
    if (
      revision.manifestDigest !== null &&
      (revision.manifestDigest !== manifest.manifestDigest ||
        revision.entryCount !== entries.length ||
        revision.logicalBytes !== entries.reduce((sum, entry) => sum + entry.byteLength, 0))
    ) throw brokerError("revision.failed", "revision summary conflicts with broker state");
    return observed;
  };

  const verifyRevisionPromise = async (revisionId: string): Promise<RevisionManifest> => {
    const revision = store.getRevision(revisionId);
    if (revision.state !== "ready") {
      throw brokerError("revision.invalid_state", "only a ready revision can be verified");
    }
    return verifyPath(path.join(readyRoot, revisionId), revision);
  };

  const stageRevisionPromise = async (
    revisionId: string,
    sourceWorkspacePath: string,
    limits: RevisionLimits,
  ): Promise<RevisionRecord> => {
    const revision = store.getRevision(revisionId);
    if (revision.state === "ready") {
      await verifyRevisionPromise(revisionId);
      return revision;
    }
    if (revision.state !== "staging") {
      throw brokerError("revision.invalid_state", "only a staging revision can be published");
    }
    const stagingPath = path.join(stagingRoot, revisionId);
    const readyPath = path.join(readyRoot, revisionId);
    if (await exists(readyPath)) {
      const manifest = await verifyPath(readyPath, revision);
      const logicalBytes = manifest.entries.reduce((sum, entry) => sum + entry.byteLength, 0);
      return store.markRevisionReady(revisionId, manifest.manifestDigest, manifest.entries.length, logicalBytes);
    }

    await fs.rm(stagingPath, { recursive: true, force: true });
    await fs.mkdir(stagingPath, { mode: 0o700 });
    const treePath = path.join(stagingPath, TREE_NAME);
    await fs.mkdir(treePath, { mode: 0o700 });
    try {
      await copySelectedRoots(sourceWorkspacePath, treePath, revision.selectedRoots);
      const entries = await inspectTree(treePath, limits, true);
      const manifest = makeRevisionManifest(entries);
      const manifestPath = path.join(stagingPath, MANIFEST_NAME);
      const handle = await fs.open(
        manifestPath,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
        0o600,
      );
      try {
        await handle.writeFile(serializeRevisionManifest(manifest), "utf8");
        await handle.sync();
      } finally {
        await handle.close();
      }
      await fs.chmod(manifestPath, 0o444);
      await makeTreeReadOnly(treePath, entries);
      await syncDirectory(stagingPath);
      await fs.rename(stagingPath, readyPath);
      await syncDirectory(stagingRoot);
      await syncDirectory(readyRoot);
      await verifyPath(readyPath, revision);
      const logicalBytes = entries.reduce((sum, entry) => sum + entry.byteLength, 0);
      return store.markRevisionReady(revisionId, manifest.manifestDigest, entries.length, logicalBytes);
    } catch (error) {
      if (await exists(readyPath)) throw error;
      await quarantine(stagingPath, revisionId, "stage-failure").catch(() => undefined);
      try {
        store.failRevision(revisionId, "quarantined", storageFailure("stage", error).message);
      } catch {
        // Recovery handles database failure after filesystem mutation.
      }
      throw error;
    }
  };

  const materializePromise = async (
    revisionId: string,
    destinationWorkspacePath: string,
  ): Promise<RevisionManifest> => {
    const revision = store.getRevision(revisionId);
    const manifest = await verifyRevisionPromise(revisionId);
    const destination = await fs.lstat(destinationWorkspacePath, { bigint: true });
    if (!destination.isDirectory() || destination.isSymbolicLink()) {
      throw brokerError("revision.failed", "destination workspace is not a real directory");
    }
    const destinationEmpty = (await fs.readdir(destinationWorkspacePath)).length === 0;
    if (destinationEmpty) {
      await copyTree(path.join(readyRoot, revisionId, TREE_NAME), destinationWorkspacePath);
    }
    const entries = await inspectTree(destinationWorkspacePath, summaryLimits(revision), true);
    const copied = makeRevisionManifest(entries);
    if (copied.manifestDigest !== manifest.manifestDigest) {
      throw brokerError(
        destinationEmpty ? "revision.failed" : "revision.conflict",
        "materialized workspace does not match source revision",
      );
    }
    await syncDirectory(destinationWorkspacePath);
    return copied;
  };

  const reconcilePromise = async (): Promise<void> => {
    await initialize();
    const known = new Set(store.listRevisions().map((revision) => revision.revisionId));
    for (const revision of store.listRevisions(["staging"])) {
      const stagingPath = path.join(stagingRoot, revision.revisionId);
      const readyPath = path.join(readyRoot, revision.revisionId);
      if (await exists(readyPath)) {
        try {
          const manifest = await verifyPath(readyPath, revision);
          const logicalBytes = manifest.entries.reduce((sum, entry) => sum + entry.byteLength, 0);
          store.markRevisionReady(revision.revisionId, manifest.manifestDigest, manifest.entries.length, logicalBytes);
        } catch (error) {
          await quarantine(readyPath, revision.revisionId, "invalid-ready");
          store.failRevision(revision.revisionId, "quarantined", storageFailure("reconcile", error).message);
        }
      } else if (await exists(stagingPath)) {
        await quarantine(stagingPath, revision.revisionId, "interrupted-stage");
        store.failRevision(revision.revisionId, "quarantined", "publication was interrupted during staging");
      } else {
        store.failRevision(revision.revisionId, "failed", "publication content is missing during recovery");
      }
    }
    for (const revision of store.listRevisions(["ready"])) {
      try {
        await verifyRevisionPromise(revision.revisionId);
      } catch (error) {
        await quarantine(path.join(readyRoot, revision.revisionId), revision.revisionId, "verification-failure");
        store.failRevision(revision.revisionId, "quarantined", storageFailure("reconcile", error).message);
      }
    }
    for (const name of await fs.readdir(stagingRoot)) {
      if (!known.has(name)) await quarantine(path.join(stagingRoot, name), name, "orphan-stage");
    }
    for (const name of await fs.readdir(readyRoot)) {
      if (!known.has(name)) await quarantine(path.join(readyRoot, name), name, "orphan-ready");
    }
  };

  yield* Effect.tryPromise({ try: reconcilePromise, catch: (error) => storageFailure("initialization", error) });

  const activeStages = new Map<string, Promise<RevisionRecord>>();
  const stageOnce = (
    revisionId: string,
    sourceWorkspacePath: string,
    limits: RevisionLimits,
  ): Promise<RevisionRecord> => {
    const active = activeStages.get(revisionId);
    if (active !== undefined) return active;
    const started = stageRevisionPromise(revisionId, sourceWorkspacePath, limits)
      .finally(() => activeStages.delete(revisionId));
    activeStages.set(revisionId, started);
    return started;
  };

  return {
    stageRevision: (revisionId, sourceWorkspacePath, limits) => Effect.tryPromise({
      try: () => stageOnce(revisionId, sourceWorkspacePath, limits),
      catch: (error) => storageFailure("stage", error),
    }),
    verifyRevision: (revisionId) => Effect.tryPromise({
      try: () => verifyRevisionPromise(revisionId),
      catch: (error) => storageFailure("verify", error),
    }),
    materializeRevision: (revisionId, destinationWorkspacePath) => Effect.tryPromise({
      try: () => materializePromise(revisionId, destinationWorkspacePath),
      catch: (error) => storageFailure("materialize", error),
    }),
    reconcile: () => Effect.tryPromise({
      try: reconcilePromise,
      catch: (error) => storageFailure("reconcile", error),
    }),
  } satisfies RevisionStorageService;
});

export const RevisionStorageLive = Layer.effect(RevisionStorage, make);
