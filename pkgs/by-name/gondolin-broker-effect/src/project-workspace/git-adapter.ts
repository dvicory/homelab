import { spawn } from "node:child_process";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { brokerError, BrokerError } from "../errors.js";
import type { ProjectMaterializationLimits, ProjectSource } from "../domain.js";

export interface GitAcquisitionRequest {
  readonly source: ProjectSource;
  readonly destination: string;
  readonly limits: ProjectMaterializationLimits;
  readonly secretsDir: string | null;
}

export interface GitAcquisitionResult {
  readonly resolvedRevision: string;
  readonly entryCount: number;
  readonly totalBytes: number;
}

const GIT_ADAPTERS = new Set(["github-token"]);

const adapterFailure = (operation: string, error: unknown): BrokerError =>
  error instanceof BrokerError
    ? error
    : brokerError("project_source.failed", `git source adapter ${operation} failed`, {
        cause: error instanceof Error ? error.message : String(error),
      });

const runGit = (
  argv: ReadonlyArray<string>,
  options: {
    readonly cwd?: string;
    readonly env?: Readonly<Record<string, string>>;
    readonly deadlineMs: number;
  },
): Promise<string> => {
  const { promise, resolve, reject } = Promise.withResolvers<string>();
  const child = spawn("git", [...argv], {
    ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
    env: {
      PATH: process.env.PATH ?? "",
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_TERMINAL_PROMPT: "0",
      ...options.env,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stdout: Array<Buffer> = [];
  const stderr: Array<Buffer> = [];
  let bytes = 0;
  const timer = setTimeout(() => {
    child.kill("SIGKILL");
    reject(new Error(`git ${argv[0] ?? "command"} exceeded its deadline`));
  }, options.deadlineMs);
  child.stdout.on("data", (chunk: Buffer) => {
    bytes += chunk.byteLength;
    if (bytes > 1024 * 1024) {
      child.kill("SIGKILL");
      return;
    }
    stdout.push(chunk);
  });
  child.stderr.on("data", (chunk: Buffer) => {
    if (stderr.reduce((total, part) => total + part.byteLength, 0) < 65536) stderr.push(chunk);
  });
  child.on("error", (error) => {
    clearTimeout(timer);
    reject(error);
  });
  child.on("close", (code, signal) => {
    clearTimeout(timer);
    if (code === 0) {
      resolve(Buffer.concat(stdout).toString("utf8").trim());
    } else {
      const detail = Buffer.concat(stderr).toString("utf8").trim();
      // Git diagnostics can echo server challenge material; never forward
      // the credential itself, and truncate everything else.
      reject(new Error(`git ${argv[0] ?? "command"} exited ${code ?? signal}: ${detail.slice(0, 512)}`));
    }
  });
  return promise;
};

const credentialEnvironment = async (
  source: ProjectSource,
  secretsDir: string | null,
  helperDir: string,
): Promise<Record<string, string>> => {
  if (source.credential === undefined) return {};
  if (!GIT_ADAPTERS.has(source.credential.adapter)) {
    throw brokerError("project_source.failed", "unknown source credential adapter", {
      adapter: source.credential.adapter,
    });
  }
  if (secretsDir === null) {
    throw brokerError("project_source.failed", "source credential store is unavailable");
  }
  const secretPath = path.join(secretsDir, `source-${source.credential.secretRef}`);
  const stat = await fs.lstat(secretPath).catch(() => null);
  if (stat === null || !stat.isFile()) {
    throw brokerError("project_source.failed", "source credential is not provisioned", {
      secretRef: source.credential.secretRef,
    });
  }
  // The askpass helper references the credential only by path; the token
  // value never enters argv, the environment, or the cloned repository.
  const helper = path.join(helperDir, "git-askpass.sh");
  await fs.writeFile(
    helper,
    `#!/bin/sh\ncase "$1" in\n  *[Uu]sername*) printf '%s\\n' x-access-token ;;\n  *) cat "${secretPath}" ;;\nesac\n`,
    { mode: 0o700 },
  );
  return {
    GIT_ASKPASS: helper,
    GIT_USERNAME: "x-access-token",
  };
};

const readCredentialMaterial = async (
  source: ProjectSource,
  secretsDir: string | null,
): Promise<ReadonlyArray<string>> => {
  if (source.credential === undefined || secretsDir === null) return [];
  try {
    const value = (await fs.readFile(path.join(secretsDir, `source-${source.credential.secretRef}`), "utf8")).trim();
    return value.length === 0 ? [] : [value];
  } catch {
    return [];
  }
};

const assertSelfContained = async (destination: string): Promise<void> => {
  const gitDir = path.join(destination, ".git");
  const stat = await fs.lstat(gitDir).catch(() => null);
  if (stat === null || !stat.isDirectory() || stat.isSymbolicLink()) {
    throw brokerError("project_source.failed", "materialized repository metadata is not a self-contained directory");
  }
  const alternates = path.join(gitDir, "objects", "info", "alternates");
  if ((await fs.lstat(alternates).catch(() => null)) !== null) {
    throw brokerError("project_source.failed", "materialized repository borrows external object storage");
  }
  const commondir = await fs.readFile(path.join(gitDir, "commondir"), "utf8").catch(() => null);
  if (commondir !== null) {
    throw brokerError("project_source.failed", "materialized repository shares external Git metadata");
  }
};

const assertSanitized = async (
  destination: string,
  forbiddenMaterial: ReadonlyArray<string>,
  forbiddenPaths: ReadonlyArray<string>,
): Promise<void> => {
  const scan = async (filePath: string): Promise<void> => {
    const content = await fs.readFile(filePath, "utf8").catch(() => "");
    for (const token of forbiddenMaterial) {
      if (token.length > 0 && content.includes(token)) {
        throw brokerError("project_source.failed", "credential material survived repository sanitization");
      }
    }
    for (const hostPath of forbiddenPaths) {
      if (hostPath.length > 0 && content.includes(hostPath)) {
        throw brokerError("project_source.failed", "host-only path survived repository sanitization");
      }
    }
  };
  await scan(path.join(destination, ".git", "config"));
  await scan(path.join(destination, ".git", "packed-refs"));
  const config = await runGit(["config", "--local", "--list"], {
    cwd: destination,
    deadlineMs: 30_000,
  });
  for (const line of config.split("\n")) {
    const key = line.split("=")[0] ?? "";
    if (
      key.startsWith("http.") ||
      key.startsWith("credential.") ||
      key.startsWith("url.") ||
      key.startsWith("remote.") ||
      key === "core.worktree"
    ) {
      throw brokerError("project_source.failed", "repository configuration survived sanitization", { key });
    }
    for (const token of forbiddenMaterial) {
      if (token.length > 0 && line.includes(token)) {
        throw brokerError("project_source.failed", "credential material survived repository sanitization");
      }
    }
  }
};

const measureTree = async (
  root: string,
  limits: ProjectMaterializationLimits,
): Promise<{ readonly entryCount: number; readonly totalBytes: number }> => {
  let entryCount = 0;
  let totalBytes = 0;
  const pending: Array<{ absolute: string; relative: string }> = [{ absolute: root, relative: "" }];
  while (pending.length > 0) {
    const directory = pending.pop()!;
    const entries = await fs.readdir(directory.absolute, { withFileTypes: true });
    for (const entry of entries) {
      const relativePath = directory.relative.length === 0 ? entry.name : `${directory.relative}/${entry.name}`;
      if (Buffer.byteLength(relativePath, "utf8") > limits.maxPathBytes) {
        throw brokerError("project_materialization.limit", "source path exceeds its limit", {
          path: relativePath,
        });
      }
      entryCount += 1;
      if (entryCount > limits.maxEntries) {
        throw brokerError("project_materialization.limit", "source exceeds its entry limit");
      }
      const absolute = path.join(directory.absolute, entry.name);
      const stat = await fs.lstat(absolute);
      if (stat.isDirectory()) {
        pending.push({ absolute, relative: relativePath });
        continue;
      }
      if (!stat.isFile() && !stat.isSymbolicLink()) {
        throw brokerError("project_source.failed", "source contains an unsupported node", {
          path: relativePath,
        });
      }
      if (stat.isFile()) {
        const byteLength = Number(stat.size);
        if (byteLength > limits.maxFileBytes) {
          throw brokerError("project_materialization.limit", "source file exceeds its size limit", {
            path: relativePath,
          });
        }
        totalBytes += byteLength;
        if (totalBytes > limits.maxSourceBytes) {
          throw brokerError("project_materialization.limit", "source exceeds its byte limit");
        }
      }
    }
  }
  return { entryCount, totalBytes };
};

/** Grant the broker group read/write traversal across an installed tree. */
const grantGroupAccess = async (root: string): Promise<void> => {
  const pending: string[] = [root];
  while (pending.length > 0) {
    const directory = pending.pop()!;
    await fs.chmod(directory, 0o2770);
    const entries = await fs.readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        pending.push(absolute);
      } else if (entry.isFile()) {
        const current = (await fs.lstat(absolute)).mode & 0o777;
        // Preserve the executable bit; strip world access entirely.
        await fs.chmod(absolute, (current & 0o111) !== 0 ? 0o770 : 0o660);
      }
      // Symlinks are left untouched: their targets resolve inside the tree.
    }
  }
};

/**
 * Strip group write across an installed tree: the broker (owner) retains full
 * control while gateway-side consumers face a read-only work plane.
 */
const restrictGroupToRead = async (root: string): Promise<void> => {
  const pending: string[] = [root];
  while (pending.length > 0) {
    const directory = pending.pop()!;
    await fs.chmod(directory, 0o2750);
    const entries = await fs.readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        pending.push(absolute);
      } else if (entry.isFile()) {
        const current = (await fs.lstat(absolute)).mode & 0o777;
        await fs.chmod(absolute, (current & 0o111) !== 0 ? 0o750 : 0o640);
      }
    }
  }
};

/**
 * Apply the effective Project permission to an installed work plane. The
 * broker owns every file, so this is the uniform enforcement point for both
 * the guest VFS and trusted external workers sharing the host tree.
 */
export const applyWorkPlanePermission = async (
  workPlane: string,
  permission: "read-only" | "workspace-write",
): Promise<void> => {
  if (permission === "read-only") {
    await restrictGroupToRead(workPlane);
  } else {
    await grantGroupAccess(workPlane);
  }
};

/** Resolve the trusted upstream ref without creating a generation. */
export const resolveUpstreamRevision = async (
  source: ProjectSource,
  secretsDir: string | null,
  helperDir: string,
  deadlineMs: number,
): Promise<string> => {
  try {
    if (source.pin !== undefined) return source.pin;
    await fs.mkdir(helperDir, { recursive: true, mode: 0o700 });
    const env = await credentialEnvironment(source, secretsDir, helperDir);
    const output = await runGit(["ls-remote", source.upstream, source.defaultRef], {
      env,
      deadlineMs,
    });
    const revision = output.split(/\s+/)[0] ?? "";
    if (!/^[0-9a-f]{40}$/.test(revision)) {
      throw brokerError("project_source.failed", "upstream did not resolve an immutable commit");
    }
    return revision;
  } catch (error) {
    throw adapterFailure("resolution", error);
  } finally {
    await fs.rm(path.join(helperDir, "git-askpass.sh"), { force: true }).catch(() => undefined);
  }
};

/**
 * Acquire one immutable source generation into detached staging. The clone
 * is task-independent broker-owned storage; sanitization removes remotes and
 * credential-capable configuration before any workspace install.
 */
export const acquireGitSource = async (request: GitAcquisitionRequest): Promise<GitAcquisitionResult> => {
  const { source, destination, limits } = request;
  const helperDir = path.join(path.dirname(destination), ".helpers");
  try {
    await fs.rm(destination, { recursive: true, force: true });
    await fs.mkdir(path.dirname(destination), { recursive: true, mode: 0o700 });
    await fs.mkdir(helperDir, { recursive: true, mode: 0o700 });
    const env = await credentialEnvironment(request.source, request.secretsDir, helperDir);
    await runGit(
      [
        "clone",
        "--single-branch",
        "--branch",
        source.defaultRef,
        "--no-tags",
        "-c",
        "credential.helper=",
        "--",
        source.upstream,
        destination,
      ],
      { env, deadlineMs: limits.deadlineMs },
    );
    if (source.pin !== undefined) {
      await runGit(["checkout", "--detach", source.pin], {
        cwd: destination,
        env,
        deadlineMs: limits.deadlineMs,
      });
    }
    const resolvedRevision = await runGit(["rev-parse", "HEAD"], {
      cwd: destination,
      deadlineMs: 30_000,
    });
    if (!/^[0-9a-f]{40}$/.test(resolvedRevision)) {
      throw brokerError("project_source.failed", "acquired source did not resolve an immutable commit");
    }
    // Sanitize before anything else observes the tree: drop the origin
    // remote and every credential-capable configuration section, then prove
    // credential material and host-only paths are absent.
    await runGit(["remote", "remove", "origin"], { cwd: destination, deadlineMs: 30_000 }).catch(() => "");
    for (const section of ["http", "credential", "url", "gcrypt"]) {
      await runGit(["config", "--local", "--remove-section", section], {
        cwd: destination,
        deadlineMs: 30_000,
      }).catch(() => "");
    }
    await fs.rm(path.join(destination, ".git", "hooks"), { recursive: true, force: true });
    await assertSelfContained(destination);
    await assertSanitized(
      destination,
      await readCredentialMaterial(source, request.secretsDir),
      [request.secretsDir ?? "", helperDir],
    );
    const measurement = await measureTree(destination, limits);
    return { resolvedRevision, ...measurement };
  } catch (error) {
    await fs.rm(destination, { recursive: true, force: true }).catch(() => undefined);
    throw adapterFailure("acquisition", error);
  } finally {
    await fs.rm(helperDir, { recursive: true, force: true }).catch(() => undefined);
  }
};

/** Install a staged generation into a workspace work plane via rename. */
export const installGeneration = async (
  source: string,
  destination: string,
  limits: ProjectMaterializationLimits,
): Promise<{ readonly entryCount: number; readonly totalBytes: number }> => {
  try {
    const backup = `${destination}.previous`;
    await fs.rm(backup, { recursive: true, force: true });
    if ((await fs.lstat(destination).catch(() => null)) !== null) {
      await fs.rename(destination, backup);
    }
    try {
      await fs.cp(source, destination, {
        recursive: true,
        verbatimSymlinks: true,
        errorOnExist: false,
        force: false,
      });
    } catch (error) {
      await fs.rm(destination, { recursive: true, force: true }).catch(() => undefined);
      if ((await fs.lstat(backup).catch(() => null)) !== null) {
        await fs.rename(backup, destination);
      }
      throw error;
    }
    await fs.rm(backup, { recursive: true, force: true });
    return await measureTree(destination, limits);
  } catch (error) {
    throw error instanceof BrokerError
      ? error
      : brokerError("project_materialization.failed", "workspace installation failed", {
          cause: error instanceof Error ? error.message : String(error),
        });
  }
};

/** List bounded work-tree paths that diverge from the baseline generation. */
export const changedPaths = async (
  workTree: string,
  maxPaths: number,
): Promise<ReadonlyArray<string>> => {
  try {
    const output = await runGit(["status", "--porcelain=v1", "--untracked-files=all", "-z", "."], {
      cwd: workTree,
      deadlineMs: 60_000,
    });
    if (output.length === 0) return [];
    const entries = output.split("\0").filter((entry) => entry.length > 3);
    const paths = entries.map((entry) => entry.slice(3));
    return paths.slice(0, maxPaths).sort();
  } catch (error) {
    throw adapterFailure("result inspection", error);
  }
};
