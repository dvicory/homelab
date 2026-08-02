import { randomUUID } from "node:crypto";
import { isUtf8 } from "node:buffer";
import { constants } from "node:fs";
import type { BigIntStats } from "node:fs";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { brokerError, BrokerError } from "../errors.js";

export interface HandoffLimits {
  readonly maxLogicalBytes: number;
  readonly maxEntries: number;
  readonly maxFileBytes: number;
  readonly maxPathBytes: number;
}

export interface OutputNode {
  readonly relativePath: string;
  readonly kind: "directory" | "file";
  readonly byteLength: number;
  readonly mode: number;
  readonly dev: bigint;
  readonly ino: bigint;
  readonly nlink: bigint;
}

export interface OutputSnapshot {
  readonly entryCount: number;
  readonly totalBytes: number;
  readonly nodes: ReadonlyArray<OutputNode>;
}

const DIRECTORY_MODE = 0o755;
const FILE_MODE = 0o644;
const EXECUTABLE_MODE = 0o755;
const FROZEN_DIRECTORY_MODE = 0o755;
const FROZEN_FILE_MODE = 0o444;
const FROZEN_EXECUTABLE_MODE = 0o555;
const COPY_BUFFER_BYTES = 64 * 1024;
const NO_FOLLOW = constants.O_NOFOLLOW;

const copyFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("handoff.failed", `workspace handoff ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const validateLimits = (limits: HandoffLimits): void => {
  for (const [name, value] of Object.entries(limits)) {
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw brokerError("request.invalid", `${name} must be a positive safe integer`);
    }
  }
};

const byteOrder = (left: string, right: string): number =>
  Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8"));
const decodeName = (name: Buffer, parent: string): string => {
  if (!isUtf8(name) || name.includes(0x00) || name.includes(0x2f)) {
    throw brokerError("handoff.failed", "workspace output contains an invalid file name", { path: parent });
  }
  const value = name.toString("utf8");
  if (value.normalize("NFC") !== value || value === "." || value === ".." || value.includes("\\")) {
    throw brokerError("handoff.failed", "workspace output name is not normalized", { path: parent });
  }
  return value;
};

const readDirectoryNames = async (
  directory: string,
  parent: string,
  maxEntries: number,
): Promise<Array<string>> => {
  const names: Array<string> = [];
  const collisions = new Set<string>();
  const handle = await fs.opendir(directory, { encoding: "buffer" as unknown as BufferEncoding, bufferSize: 32 });
  try {
    while (true) {
      const entry = await handle.read();
      if (entry === null) break;
      if (names.length >= maxEntries) {
        throw brokerError("handoff.failed", "workspace output exceeds its entry limit");
      }
      const value = decodeName(entry.name as unknown as Buffer, parent);
      if (collisions.has(value)) {
        throw brokerError("handoff.failed", "workspace output contains colliding names", { path: parent, name: value });
      }
      collisions.add(value);
      names.push(value);
    }
  } finally {
    await handle.close();
  }
  return names.sort(byteOrder);
};

const ensureReadable = async (absolute: string, stat: BigIntStats, relativePath: string): Promise<void> => {
  if ((stat.mode & 0o444n) === 0n) {
    throw brokerError("handoff.failed", "workspace output contains an unreadable entry", { path: relativePath });
  }
  const handle = await fs.open(absolute, constants.O_RDONLY | NO_FOLLOW | (stat.isDirectory() ? constants.O_DIRECTORY : 0));
  await handle.close();
};

const inspectOutputPath = async (
  outputPath: string,
  limits: HandoffLimits,
  expectedDevice?: bigint,
): Promise<OutputSnapshot> => {
  validateLimits(limits);
  const root = await fs.lstat(outputPath, { bigint: true });
  if (!root.isDirectory() || root.isSymbolicLink()) {
    throw brokerError("handoff.failed", "workspace output is not a real directory");
  }
  const device = expectedDevice ?? root.dev;
  if (root.dev !== device) {
    throw brokerError("handoff.failed", "workspace output crosses a filesystem boundary");
  }
  await ensureReadable(outputPath, root, ".");

  const nodes: Array<OutputNode> = [];
  let totalBytes = 0;
  const pending: Array<{ absolute: string; relative: string }> = [{ absolute: outputPath, relative: "" }];
  while (pending.length > 0) {
    const directory = pending.pop()!;
    const pendingStat = await fs.lstat(directory.absolute, { bigint: true });
    if (!pendingStat.isDirectory() || pendingStat.isSymbolicLink() || pendingStat.dev !== device) {
      throw brokerError("handoff.failed", "workspace output pending directory is not a real same-device directory", {
        path: directory.relative.length === 0 ? "." : directory.relative,
      });
    }
    const names = await readDirectoryNames(
      directory.absolute,
      directory.relative.length === 0 ? "." : directory.relative,
      Math.max(0, limits.maxEntries - nodes.length),
    );
    for (const name of names) {
      const relativePath = directory.relative.length === 0 ? name : `${directory.relative}/${name}`;
      if (Buffer.byteLength(relativePath, "utf8") > limits.maxPathBytes) {
        throw brokerError("handoff.failed", "workspace output path exceeds its limit", { path: relativePath });
      }
      if (nodes.length >= limits.maxEntries) {
        throw brokerError("handoff.failed", "workspace output exceeds its entry limit");
      }
      const absolute = path.join(directory.absolute, name);
      const stat = await fs.lstat(absolute, { bigint: true });
      if (stat.dev !== device) {
        throw brokerError("handoff.failed", "workspace output crosses a filesystem boundary", { path: relativePath });
      }
      if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) {
        throw brokerError("handoff.failed", "workspace output contains an unsupported node", { path: relativePath });
      }
      await ensureReadable(absolute, stat, relativePath);
      if (stat.isDirectory()) {
        nodes.push({
          relativePath,
          kind: "directory",
          byteLength: 0,
          mode: (stat.mode & 0o111n) === 0n ? DIRECTORY_MODE : EXECUTABLE_MODE,
          dev: stat.dev,
          ino: stat.ino,
          nlink: stat.nlink,
        });
        pending.push({ absolute, relative: relativePath });
        continue;
      }
      if (stat.nlink !== 1n) {
        throw brokerError("handoff.failed", "workspace output contains a multiply linked file", { path: relativePath });
      }
      const byteLength = Number(stat.size);
      if (!Number.isSafeInteger(byteLength) || byteLength > limits.maxFileBytes) {
        throw brokerError("handoff.failed", "workspace output file exceeds its size limit", { path: relativePath });
      }
      if (totalBytes > limits.maxLogicalBytes - byteLength) {
        throw brokerError("handoff.failed", "workspace output exceeds its byte limit");
      }
      nodes.push({
        relativePath,
        kind: "file",
        byteLength,
        mode: (stat.mode & 0o111n) === 0n ? FILE_MODE : EXECUTABLE_MODE,
        dev: stat.dev,
        ino: stat.ino,
        nlink: stat.nlink,
      });
      totalBytes += byteLength;
    }
  }
  nodes.sort((left, right) => byteOrder(left.relativePath, right.relativePath));
  return { entryCount: nodes.length, totalBytes, nodes };
};

export const outputPathForWorkspace = (workspacePath: string): string => path.join(workspacePath, "output");

const validateSelectedArtifacts = async (
  outputPath: string,
  outputDevice: bigint,
  selectedArtifacts: ReadonlyArray<string>,
): Promise<void> => {
  for (const selected of selectedArtifacts) {
    if (!selected.startsWith("output/") || selected.length === "output/".length) {
      throw brokerError("handoff.failed", "selected artifact path is not below output", { path: selected });
    }
    const relative = selected.slice("output/".length);
    const absolute = path.join(outputPath, ...relative.split("/"));
    let stat: BigIntStats;
    try {
      stat = await fs.lstat(absolute, { bigint: true });
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "ENOENT" || code === "ENOTDIR" || code === "ELOOP") {
        throw brokerError("handoff.conflict", "selected artifact changed during handoff finalization", { path: selected });
      }
      throw error;
    }
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1n || stat.dev !== outputDevice) {
      throw brokerError("handoff.failed", "selected artifact is not a regular local file", { path: selected });
    }
  }
};

export const preflightOutput = async (
  workspacePath: string,
  limits: HandoffLimits,
  selectedArtifacts: ReadonlyArray<string> = [],
): Promise<OutputSnapshot> => {
  try {
    const workspace = await fs.lstat(workspacePath, { bigint: true });
    if (!workspace.isDirectory() || workspace.isSymbolicLink()) {
      throw brokerError("handoff.failed", "workspace root is not a real directory");
    }
    const outputPath = outputPathForWorkspace(workspacePath);
    let output: BigIntStats;
    try {
      output = await fs.lstat(outputPath, { bigint: true });
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "ENOENT" && selectedArtifacts.length === 0) {
        return { entryCount: 0, totalBytes: 0, nodes: [] };
      }
      if (selectedArtifacts.length > 0 && (code === "ENOENT" || code === "ENOTDIR" || code === "ELOOP")) {
        throw brokerError("handoff.conflict", "selected artifact output changed during handoff finalization", { path: "output" });
      }
      throw error;
    }
    if (!output.isDirectory() || output.isSymbolicLink()) {
      throw brokerError("handoff.failed", "workspace output is not a real directory");
    }
    if (output.dev !== workspace.dev) {
      throw brokerError("handoff.failed", "workspace output crosses a filesystem boundary");
    }
    const snapshot = await inspectOutputPath(outputPath, limits, workspace.dev);
    await validateSelectedArtifacts(outputPath, workspace.dev, selectedArtifacts);
    return snapshot;
  } catch (error) {
    throw copyFailure("preflight", error);
  }
};

const sameNode = (left: OutputNode | undefined, right: OutputNode | undefined): boolean =>
  left !== undefined && right !== undefined &&
  left.relativePath === right.relativePath && left.kind === right.kind &&
  left.byteLength === right.byteLength && left.mode === right.mode &&
  left.dev === right.dev && left.ino === right.ino && left.nlink === right.nlink;

const ensureRealParentChain = async (root: string, relativePath: string): Promise<void> => {
  let current = root;
  for (const segment of relativePath.split("/").slice(0, -1)) {
    current = path.join(current, segment);
    const stat = await fs.lstat(current, { bigint: true });
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw brokerError("handoff.failed", "workspace output parent is not a real directory", { path: relativePath });
    }
  }
};

export const assertSnapshotUnchanged = (before: OutputSnapshot, after: OutputSnapshot): void => {
  if (before.entryCount !== after.entryCount || before.totalBytes !== after.totalBytes ||
      before.nodes.length !== after.nodes.length || before.nodes.some((node, index) => !sameNode(node, after.nodes[index]))) {
    throw brokerError("handoff.failed", "workspace output changed during handoff finalization");
  }
};

const normalizeMode = (node: OutputNode, frozen: boolean): number => {
  if (node.kind === "directory") return frozen ? FROZEN_DIRECTORY_MODE : DIRECTORY_MODE;
  if ((node.mode & 0o111) !== 0) return frozen ? FROZEN_EXECUTABLE_MODE : EXECUTABLE_MODE;
  return frozen ? FROZEN_FILE_MODE : FILE_MODE;
};

const ensureDestinationParent = async (absolute: string): Promise<void> => {
  await fs.mkdir(path.dirname(absolute), { recursive: true, mode: 0o700 });
};

const copyRegularFile = async (
  source: string,
  destination: string,
  expected: OutputNode,
  frozen: boolean,
): Promise<void> => {
  const sourceHandle = await fs.open(source, constants.O_RDONLY | NO_FOLLOW);
  try {
    const sourceStat = await sourceHandle.stat({ bigint: true });
    if (!sourceStat.isFile() || sourceStat.isSymbolicLink() || sourceStat.dev !== expected.dev ||
        sourceStat.ino !== expected.ino || sourceStat.nlink !== 1n || Number(sourceStat.size) !== expected.byteLength) {
      throw brokerError("handoff.failed", "workspace output file changed during copy", { path: expected.relativePath });
    }
    await ensureDestinationParent(destination);
    const destinationHandle = await fs.open(
      destination,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | NO_FOLLOW,
      normalizeMode(expected, false),
    );
    try {
      const buffer = Buffer.allocUnsafe(COPY_BUFFER_BYTES);
      let copied = 0;
      while (copied < expected.byteLength) {
        const { bytesRead } = await sourceHandle.read(buffer, 0, Math.min(buffer.byteLength, expected.byteLength - copied), copied);
        if (bytesRead === 0) throw brokerError("handoff.failed", "workspace output file ended during copy", { path: expected.relativePath });
        let written = 0;
        while (written < bytesRead) {
          const result = await destinationHandle.write(buffer, written, bytesRead - written);
          written += result.bytesWritten;
        }
        copied += bytesRead;
      }
      const destinationStat = await destinationHandle.stat({ bigint: true });
      if (Number(destinationStat.size) !== expected.byteLength) {
        throw brokerError("handoff.failed", "copied workspace output file has an unexpected size", { path: expected.relativePath });
      }
      await destinationHandle.chmod(normalizeMode(expected, frozen));
      await destinationHandle.sync();
    } finally {
      await destinationHandle.close();
    }
  } finally {
    await sourceHandle.close();
  }
};

const copyNodes = async (
  sourceOutput: string,
  destinationOutput: string,
  snapshot: OutputSnapshot,
  frozen: boolean,
): Promise<void> => {
  const sourceRoot = await fs.lstat(sourceOutput, { bigint: true });
  if (!sourceRoot.isDirectory() || sourceRoot.isSymbolicLink()) {
    throw brokerError("handoff.failed", "workspace output source is not a real directory");
  }
  await fs.mkdir(destinationOutput, { recursive: true, mode: 0o700 });
  const directories = snapshot.nodes.filter((node) => node.kind === "directory")
    .sort((left, right) => left.relativePath.split("/").length - right.relativePath.split("/").length);
  for (const node of directories) {
    const absolute = path.join(destinationOutput, ...node.relativePath.split("/"));
    await fs.mkdir(absolute, { recursive: false, mode: normalizeMode(node, false) });
    await fs.chmod(absolute, normalizeMode(node, false));
  }
  for (const node of snapshot.nodes.filter((candidate) => candidate.kind === "file")) {
    await ensureRealParentChain(sourceOutput, node.relativePath);
    await copyRegularFile(
      path.join(sourceOutput, ...node.relativePath.split("/")),
      path.join(destinationOutput, ...node.relativePath.split("/")),
      node,
      frozen,
    );
  }
  await fs.chmod(destinationOutput, frozen ? FROZEN_DIRECTORY_MODE : DIRECTORY_MODE);
  for (const node of [...directories].reverse()) {
    const absolute = path.join(destinationOutput, ...node.relativePath.split("/"));
    await fs.chmod(absolute, normalizeMode(node, frozen));
    await syncDirectory(absolute);
  }
  await syncDirectory(destinationOutput);
};

export const copyOutputToTemp = async (
  sourceWorkspacePath: string,
  destinationTempPath: string,
  snapshot: OutputSnapshot,
): Promise<void> => {
  try {
    const sourceOutputPath = outputPathForWorkspace(sourceWorkspacePath);
    if (snapshot.entryCount === 0 && snapshot.totalBytes === 0) {
      try {
        await fs.lstat(sourceOutputPath, { bigint: true });
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") {
          const destinationOutput = outputPathForWorkspace(destinationTempPath);
          await fs.mkdir(destinationOutput, { recursive: false, mode: FROZEN_DIRECTORY_MODE });
          await fs.chmod(destinationOutput, FROZEN_DIRECTORY_MODE);
          await syncDirectory(destinationOutput);
          await syncDirectory(destinationTempPath);
          return;
        }
        throw error;
      }
    }
    await copyNodes(sourceOutputPath, outputPathForWorkspace(destinationTempPath), snapshot, true);
    await syncDirectory(destinationTempPath);
  } catch (error) {
    throw copyFailure("copy", error);
  }
};

export const validateFrozenOutput = async (
  handoffOutputPath: string,
  limits: HandoffLimits,
  expected?: OutputSnapshot,
): Promise<OutputSnapshot> => {
  try {
    const observed = await inspectOutputPath(handoffOutputPath, limits);
    const rootStat = await fs.lstat(handoffOutputPath, { bigint: true });
    if (Number(rootStat.mode & 0o777n) !== FROZEN_DIRECTORY_MODE) {
      throw brokerError("handoff.failed", "frozen workspace output root mode is invalid");
    }

    if (expected !== undefined) assertSnapshotUnchanged(expected, observed);
    for (const node of observed.nodes) {
      const stat = await fs.lstat(path.join(handoffOutputPath, ...node.relativePath.split("/")), { bigint: true });
      const expectedMode = normalizeMode(node, true);
      if (Number(stat.mode & 0o777n) !== expectedMode || (node.kind === "file" && stat.nlink !== 1n)) {
        throw brokerError("handoff.failed", "frozen workspace output mode or link policy is invalid", { path: node.relativePath });
      }
    }
    return observed;
  } catch (error) {
    throw copyFailure("validation", error);
  }
};
const cleanupDestinationTemps = async (destinationWorkspacePath: string): Promise<void> => {
  const destinationName = path.basename(outputPathForWorkspace(destinationWorkspacePath));
  for (const name of await fs.readdir(destinationWorkspacePath)) {
    if (!name.startsWith(`${destinationName}.previous-`) && !name.startsWith(".output-handoff-")) continue;
    const candidate = path.join(destinationWorkspacePath, name);
    const stat = await fs.lstat(candidate, { bigint: true });
    if (stat.isDirectory() && !stat.isSymbolicLink()) {
      await fs.rm(candidate, { recursive: true, force: true });
    }
  }
};
export const copyFrozenOutput = async (
  sourceOutputPath: string,
  destinationWorkspacePath: string,
  limits: HandoffLimits,
): Promise<OutputSnapshot> => {
  let temporaryOutput: string | undefined;
  let backupOutput: string | undefined;
  try {
    const snapshot = await validateFrozenOutput(sourceOutputPath, limits);
    const destinationOutput = outputPathForWorkspace(destinationWorkspacePath);
    await cleanupDestinationTemps(destinationWorkspacePath);
    let existing: BigIntStats | undefined;
    try {
      existing = await fs.lstat(destinationOutput, { bigint: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    if (existing !== undefined) {
      if (!existing.isDirectory() || existing.isSymbolicLink()) {
        throw brokerError("handoff.failed", "destination workspace output is not a real directory");
      }
      const directory = await fs.opendir(destinationOutput, { encoding: "buffer" as unknown as BufferEncoding, bufferSize: 1 });
      let firstEntry: unknown;
      try {
        firstEntry = await directory.read();
      } finally {
        await directory.close();
      }
      if (firstEntry !== null) {
        const prior = await inspectOutputPath(destinationOutput, limits);
        const sameStructure = prior.entryCount === snapshot.entryCount &&
          prior.totalBytes === snapshot.totalBytes &&
          prior.nodes.length === snapshot.nodes.length &&
          prior.nodes.every((node, index) => {
            const expected = snapshot.nodes[index];
            return expected !== undefined && node.relativePath === expected.relativePath &&
              node.kind === expected.kind && node.byteLength === expected.byteLength &&
              node.mode === expected.mode;
          });
        if (sameStructure) {
          await cleanupDestinationTemps(destinationWorkspacePath);
          return snapshot;
        }
        throw brokerError("handoff.conflict", "destination workspace output is not empty");
      }
    }

    temporaryOutput = path.join(destinationWorkspacePath, `.output-handoff-${randomUUID()}`);
    await copyNodes(sourceOutputPath, temporaryOutput, snapshot, false);
    const copied = await inspectOutputPath(temporaryOutput, limits);
    if (copied.entryCount !== snapshot.entryCount || copied.totalBytes !== snapshot.totalBytes ||
        copied.nodes.some((node, index) => {
          const expected = snapshot.nodes[index];
          return expected === undefined || node.relativePath !== expected.relativePath ||
            node.kind !== expected.kind || node.byteLength !== expected.byteLength || node.mode !== expected.mode;
        })) {
      throw brokerError("handoff.failed", "imported workspace output structure changed during copy");
    }
    await syncDirectory(destinationWorkspacePath);

    if (existing !== undefined) {
      backupOutput = `${destinationOutput}.previous-${randomUUID()}`;
      await fs.rename(destinationOutput, backupOutput);
    }
    await fs.rename(temporaryOutput, destinationOutput);
    temporaryOutput = undefined;
    await syncDirectory(destinationWorkspacePath);
    if (backupOutput !== undefined) {
      await fs.rmdir(backupOutput);
      backupOutput = undefined;
      await syncDirectory(destinationWorkspacePath);
    }
    return snapshot;
  } catch (error) {
    if (temporaryOutput !== undefined) await fs.rm(temporaryOutput, { recursive: true, force: true }).catch(() => undefined);
    if (backupOutput !== undefined) {
      try {
        if (!(await fs.lstat(outputPathForWorkspace(destinationWorkspacePath)).then(() => true, () => false))) {
          await fs.rename(backupOutput, outputPathForWorkspace(destinationWorkspacePath));
        }
      } catch {
        // Preserve the original failure; reconciliation can quarantine the backup.
      }
    }
    throw copyFailure("import", error);
  }
};

export const syncDirectory = async (directory: string): Promise<void> => {
  const handle = await fs.open(directory, constants.O_RDONLY | constants.O_DIRECTORY | NO_FOLLOW);
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
};
