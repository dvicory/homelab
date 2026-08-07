/**
 * Typed VFS operations (V3 §13.4).
 *
 * File operations go through Gondolin's vm.fs/provider surface rather than a
 * guest shell per operation. Every path is normalized and confined to the
 * environment's workspace mount root; reads/writes are binary-safe with
 * explicit limits; writes use a temporary file plus rename; create/replace
 * modes are explicit; symlink handling is deterministic.
 */
import { BrokerError, REASONS } from "./errors.js";
import type { VmFs, VmFsStat } from "./gondolin.js";

export interface FsLimits {
  /** maximum bytes for a single read or write */
  maxFileBytes: number;
  /** maximum entries returned by fs.list */
  maxListEntries: number;
  /** maximum path length in characters */
  maxPathLength: number;
}

export const DEFAULT_FS_LIMITS: FsLimits = {
  maxFileBytes: 16 * 1024 * 1024,
  maxListEntries: 10000,
  maxPathLength: 4096,
};

/**
 * Normalize a guest path lexically and confine it to the workspace root.
 * Absolute paths must already be under the root; relative paths resolve
 * against it. Anything else — `..` above the root, NULs, oversize paths —
 * fails closed.
 */
export function confineGuestPath(input: string, root: string, limits: FsLimits = DEFAULT_FS_LIMITS): string {
  if (input.length === 0 || input.length > limits.maxPathLength || input.includes("\0")) {
    throw new BrokerError(REASONS.FS_PATH, "invalid path", { length: input.length });
  }
  const normalizedRoot = root.replace(/\/+$/, "");
  const absolute = input.startsWith("/");
  const candidate = absolute ? input : `${normalizedRoot}/${input}`;
  const segments: string[] = [];
  for (const raw of candidate.split("/")) {
    if (raw === "" || raw === ".") continue;
    if (raw === "..") {
      segments.pop();
      continue;
    }
    segments.push(raw);
  }
  const resolved = `/${segments.join("/")}`;
  if (resolved !== normalizedRoot && !resolved.startsWith(`${normalizedRoot}/`)) {
    throw new BrokerError(REASONS.FS_ESCAPE, "path escapes the workspace root", { path: input });
  }
  return resolved;
}

/**
 * Deterministic symlink policy for write-side operations (§13.4): no
 * component of the target path may be a symlink. Reads follow symlinks that
 * remain under the root (the guest and the VFS provider share that view).
 */
async function assertNoSymlinkComponents(fs: VmFs, absolutePath: string, root: string): Promise<void> {
  const normalizedRoot = root.replace(/\/+$/, "");
  const relative = absolutePath.slice(normalizedRoot.length + 1);
  const parts = relative.split("/");
  // Skip the final component (it may not exist yet); check ancestors.
  let current = normalizedRoot;
  for (const part of parts.slice(0, -1)) {
    current = `${current}/${part}`;
    let stat: VmFsStat;
    try {
      stat = await fs.stat(current);
    } catch {
      return; // missing ancestors cannot be symlinks; mkdir -p semantics cover them
    }
    if (stat.type === "symlink") {
      throw new BrokerError(REASONS.FS_TYPE, "write path traverses a symlink", { path: absolutePath });
    }
  }
}

export interface FsEntry {
  name: string;
  type?: VmFsStat["type"];
}

export class VfsService {
  #limits: FsLimits;

  constructor(limits: FsLimits = DEFAULT_FS_LIMITS) {
    this.#limits = limits;
  }

  async stat(fs: VmFs, root: string, inputPath: string): Promise<VmFsStat> {
    const path = confineGuestPath(inputPath, root, this.#limits);
    try {
      return await fs.stat(path);
    } catch (err) {
      throw notFoundOr(err, path);
    }
  }

  async list(fs: VmFs, root: string, inputPath: string): Promise<FsEntry[]> {
    const path = confineGuestPath(inputPath, root, this.#limits);
    let names: string[];
    try {
      names = await fs.listDir(path);
    } catch (err) {
      throw notFoundOr(err, path);
    }
    if (names.length > this.#limits.maxListEntries) {
      throw new BrokerError(REASONS.FS_LIMIT, "directory exceeds entry cap", {
        entries: names.length,
      });
    }
    return names.sort().map((name) => ({ name }));
  }

  async read(fs: VmFs, root: string, inputPath: string): Promise<Buffer> {
    const path = confineGuestPath(inputPath, root, this.#limits);
    let data: Buffer;
    try {
      data = await fs.readFile(path);
    } catch (err) {
      throw notFoundOr(err, path);
    }
    if (data.length > this.#limits.maxFileBytes) {
      throw new BrokerError(REASONS.FS_LIMIT, "file exceeds read cap", { bytes: data.length });
    }
    return data;
  }

  /** Atomic write: same-directory temporary file, then rename (§13.4). */
  async writeAtomic(
    fs: VmFs,
    root: string,
    inputPath: string,
    data: Buffer,
    mode: "create" | "replace" | "create-exclusive",
  ): Promise<void> {
    const path = confineGuestPath(inputPath, root, this.#limits);
    if (data.length > this.#limits.maxFileBytes) {
      throw new BrokerError(REASONS.FS_LIMIT, "write exceeds cap", { bytes: data.length });
    }
    await assertNoSymlinkComponents(fs, path, root);

    const exists = await existsQuietly(fs, path);
    if (mode === "create" && !exists) {
      throw new BrokerError(REASONS.FS_NOT_FOUND, "target does not exist", { path });
    }
    if (mode === "create-exclusive" && exists) {
      throw new BrokerError(REASONS.FS_EXISTS, "target already exists", { path });
    }

    const tmp = `${path}.hermes-broker-tmp-${process.pid}-${Date.now()}`;
    try {
      await fs.writeFile(tmp, data);
      await fs.rename(tmp, path);
    } catch (err) {
      try {
        await fs.deleteFile(tmp, false, true);
      } catch {
        // best effort
      }
      throw notFoundOr(err, path);
    }
  }

  async mkdir(fs: VmFs, root: string, inputPath: string, recursive: boolean): Promise<void> {
    const path = confineGuestPath(inputPath, root, this.#limits);
    await assertNoSymlinkComponents(fs, path, root);
    try {
      await fs.mkdir(path, recursive);
    } catch (err) {
      throw notFoundOr(err, path);
    }
  }

  async remove(fs: VmFs, root: string, inputPath: string, recursive: boolean): Promise<void> {
    const path = confineGuestPath(inputPath, root, this.#limits);
    if (path === root.replace(/\/+$/, "")) {
      throw new BrokerError(REASONS.FS_PATH, "refusing to remove the workspace root");
    }
    await assertNoSymlinkComponents(fs, path, root);
    try {
      await fs.deleteFile(path, recursive, false);
    } catch (err) {
      throw notFoundOr(err, path);
    }
  }
}

async function existsQuietly(fs: VmFs, path: string): Promise<boolean> {
  try {
    await fs.access(path);
    return true;
  } catch {
    return false;
  }
}

function notFoundOr(err: unknown, path: string): BrokerError {
  if (err instanceof BrokerError) return err;
  const message = err instanceof Error ? err.message : String(err);
  if (/ENOENT|not found|no such file/i.test(message)) {
    return new BrokerError(REASONS.FS_NOT_FOUND, "path not found", { path });
  }
  return new BrokerError(REASONS.INTERNAL, `fs operation failed: ${message}`, { path });
}
