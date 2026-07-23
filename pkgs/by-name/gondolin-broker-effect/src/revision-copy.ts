import { createHash } from "node:crypto";
import { isUtf8 } from "node:buffer";
import { constants, createReadStream, type BigIntStats } from "node:fs";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { promisify } from "node:util";
import { execFile } from "node:child_process";
import type { WorkspaceRevisionEntry } from "./revision-domain.js";
import { BrokerError, brokerError } from "./errors.js";

export interface RevisionLimits {
  readonly maxLogicalBytes: number;
  readonly maxEntries: number;
  readonly maxFileBytes: number;
  readonly maxPathBytes: number;
}

const runFile = promisify(execFile);
const DIRECTORY_MODE = 0o755;
const FILE_MODE = 0o644;
const EXECUTABLE_MODE = 0o755;

const byteOrder = (left: string, right: string): number =>
  Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8"));

const copierFailure = (error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("revision.failed", "workspace copy failed", {
        cause: error instanceof Error ? error.message : String(error),
      });

const decodeNames = (names: ReadonlyArray<Buffer>, parent: string): Array<string> =>
  names.map((name) => {
    if (!isUtf8(name) || name.includes(0x00) || name.includes(0x2f)) {
      throw brokerError("revision.failed", "workspace contains an invalid file name", { path: parent });
    }
    const decoded = name.toString("utf8");
    if (decoded.normalize("NFC") !== decoded) {
      throw brokerError("revision.failed", "workspace name is not NFC-normalized", { path: parent });
    }
    return decoded;
  }).sort(byteOrder);

const validateRoots = (roots: ReadonlyArray<string>): ReadonlyArray<string> => {
  const ordered = [...roots].sort(byteOrder);
  for (let index = 0; index < ordered.length; index += 1) {
    const current = ordered[index]!;
    for (let later = index + 1; later < ordered.length; later += 1) {
      const candidate = ordered[later]!;
      if (current === "." || candidate === current || candidate.startsWith(`${current}/`)) {
        throw brokerError("request.invalid", "workspace selection roots overlap", {
          root: current,
          overlappingRoot: candidate,
        });
      }
    }
  }
  return ordered;
};

const validateSourceNodes = async (
  workspacePath: string,
  roots: ReadonlyArray<string>,
): Promise<void> => {
  const workspace = await fs.lstat(workspacePath, { bigint: true });
  if (!workspace.isDirectory() || workspace.isSymbolicLink()) {
    throw brokerError("revision.failed", "workspace root is not a real directory");
  }
  const pending = roots.map((root) => ({
    absolute: root === "." ? workspacePath : path.join(workspacePath, ...root.split("/")),
    relative: root,
  }));
  while (pending.length > 0) {
    const current = pending.pop()!;
    const stat = await fs.lstat(current.absolute, { bigint: true });
    if (stat.dev !== workspace.dev) {
      throw brokerError("revision.failed", "selected output crosses a filesystem boundary", {
        path: current.relative,
      });
    }
    if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) {
      throw brokerError("revision.failed", "selected output contains an unsupported node", {
        path: current.relative,
      });
    }
    if (!stat.isDirectory()) continue;
    const names = decodeNames(
      await fs.readdir(current.absolute, { encoding: "buffer" }),
      current.relative,
    );
    for (const name of names) {
      pending.push({
        absolute: path.join(current.absolute, name),
        relative: current.relative === "." ? name : `${current.relative}/${name}`,
      });
    }
  }
};

const rsyncArgs = [
  "--recursive",
  "--links",
  "--perms",
  "--one-file-system",
  "--no-owner",
  "--no-group",
  "--no-times",
  "--no-acls",
  "--no-xattrs",
  "--protect-args",
  "--fsync",
] as const;

const runRsync = async (sources: ReadonlyArray<string>, destination: string): Promise<void> => {
  try {
    await runFile("rsync", [...rsyncArgs, "--relative", "--", ...sources, `${destination}/`], {
      maxBuffer: 64 * 1024,
    });
  } catch (error) {
    throw copierFailure(error);
  }
};

export const copySelectedRoots = async (
  workspacePath: string,
  destination: string,
  selectedRoots: ReadonlyArray<string>,
): Promise<void> => {
  const roots = validateRoots(selectedRoots);
  await validateSourceNodes(workspacePath, roots);
  const sources = roots.map((root) =>
    root === "." ? `${workspacePath}/./` : `${workspacePath}/./${root}`);
  await runRsync(sources, destination);
};

export const copyTree = async (source: string, destination: string): Promise<void> => {
  await runRsync([`${source}/./`], destination);
};

const validateLimits = (limits: RevisionLimits): void => {
  for (const [name, value] of Object.entries(limits)) {
    if (!Number.isSafeInteger(value) || value <= 0) {
      throw brokerError("request.invalid", `${name} must be a positive safe integer`);
    }
  }
};

const digestFile = async (filePath: string): Promise<string> => {
  const digest = createHash("sha256");
  for await (const chunk of createReadStream(filePath, { flags: "r" })) {
    digest.update(chunk);
  }
  return digest.digest("hex");
};

export const inspectTree = async (
  treePath: string,
  limits: RevisionLimits,
  normalizeModes: boolean,
): Promise<ReadonlyArray<WorkspaceRevisionEntry>> => {
  validateLimits(limits);
  const entries: Array<WorkspaceRevisionEntry> = [];
  let logicalBytes = 0;
  const pending = [{ absolute: treePath, relative: "" }];
  while (pending.length > 0) {
    const directory = pending.pop()!;
    const names = decodeNames(
      await fs.readdir(directory.absolute, { encoding: "buffer" }),
      directory.relative.length === 0 ? "." : directory.relative,
    );
    for (const name of names) {
      const relative = directory.relative.length === 0 ? name : `${directory.relative}/${name}`;
      if (Buffer.byteLength(relative, "utf8") > limits.maxPathBytes) {
        throw brokerError("revision.failed", "revision path exceeds byte limit", { path: relative });
      }
      if (entries.length >= limits.maxEntries) {
        throw brokerError("revision.failed", "revision exceeds entry limit");
      }
      const absolute = path.join(directory.absolute, name);
      const stat = await fs.lstat(absolute, { bigint: true });
      if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) {
        throw brokerError("revision.failed", "staging tree contains an unsupported node", { path: relative });
      }
      if (stat.isDirectory()) {
        if (normalizeModes) await fs.chmod(absolute, DIRECTORY_MODE);
        entries.push({
          path: relative,
          kind: "directory",
          mode: DIRECTORY_MODE,
          byteLength: 0,
          contentDigest: null,
        });
        pending.push({ absolute, relative });
        continue;
      }
      if (stat.nlink !== 1n) {
        throw brokerError("revision.failed", "staging tree contains a multiply linked file", { path: relative });
      }
      const byteLength = Number(stat.size);
      if (!Number.isSafeInteger(byteLength) || byteLength > limits.maxFileBytes) {
        throw brokerError("revision.failed", "revision file exceeds size limit", { path: relative });
      }
      if (logicalBytes > limits.maxLogicalBytes - byteLength) {
        throw brokerError("revision.failed", "revision exceeds logical byte limit");
      }
      const mode = (stat.mode & 0o111n) === 0n ? FILE_MODE : EXECUTABLE_MODE;
      if (normalizeModes) await fs.chmod(absolute, mode);
      entries.push({
        path: relative,
        kind: "file",
        mode,
        byteLength,
        contentDigest: await digestFile(absolute),
      });
      logicalBytes += byteLength;
    }
  }
  return entries.sort((left, right) => byteOrder(left.path, right.path));
};

export const syncDirectory = async (directory: string): Promise<void> => {
  const handle = await fs.open(directory, constants.O_RDONLY | constants.O_DIRECTORY);
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
};

export const makeTreeReadOnly = async (
  treePath: string,
  entries: ReadonlyArray<WorkspaceRevisionEntry>,
): Promise<void> => {
  for (const entry of entries.filter((candidate) => candidate.kind === "file")) {
    await fs.chmod(path.join(treePath, ...entry.path.split("/")), entry.mode === EXECUTABLE_MODE ? 0o555 : 0o444);
  }
  for (const entry of [...entries]
    .filter((candidate) => candidate.kind === "directory")
    .sort((left, right) => right.path.split("/").length - left.path.split("/").length)) {
    await fs.chmod(path.join(treePath, ...entry.path.split("/")), 0o555);
  }
  await fs.chmod(treePath, 0o555);
};
