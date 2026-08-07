/** Controllable in-memory VM/fs doubles for broker unit tests.
 *  These implement the same VmProvider/VmHandle/VmFs contracts the
 *  production Gondolin provider implements. */
import { EventEmitter } from "node:events";

export class FakeFs {
  constructor() {
    /** path -> { type: "file"|"directory"|"symlink", content?, mode } */
    this.entries = new Map();
    this.entries.set("/", { type: "directory", mode: 0o755 });
    this.writes = [];
  }

  #lookup(path) {
    return this.entries.get(path);
  }

  #require(path) {
    const entry = this.#lookup(path);
    if (!entry) {
      const err = new Error(`ENOENT: no such file or directory, stat '${path}'`);
      err.code = "ENOENT";
      throw err;
    }
    return entry;
  }

  async stat(path) {
    const entry = this.#require(path);
    return {
      type: entry.type,
      size: entry.content?.length ?? 0,
      mode: entry.mode ?? 0o644,
      mtimeMs: 1000,
    };
  }

  async listDir(path) {
    this.#require(path);
    const prefix = path === "/" ? "/" : `${path}/`;
    const names = [];
    for (const key of this.entries.keys()) {
      if (key === path) continue;
      if (!key.startsWith(prefix)) continue;
      const rest = key.slice(prefix.length);
      if (!rest.includes("/")) names.push(rest);
    }
    return names;
  }

  async readFile(path) {
    const entry = this.#require(path);
    if (entry.type !== "file") throw new Error(`EISDIR: illegal operation on a directory, read`);
    return Buffer.from(entry.content);
  }

  async writeFile(path, data) {
    this.entries.set(path, { type: "file", content: Buffer.from(data), mode: 0o644 });
    this.writes.push({ path, bytes: data.length });
  }

  async rename(oldPath, newPath) {
    const entry = this.#require(oldPath);
    this.entries.delete(oldPath);
    this.entries.set(newPath, entry);
  }

  async mkdir(path, recursive) {
    const parent = path.split("/").slice(0, -1).join("/") || "/";
    if (!recursive && !this.entries.has(parent)) {
      const err = new Error(`ENOENT: no such file or directory, mkdir '${path}'`);
      err.code = "ENOENT";
      throw err;
    }
    this.entries.set(path, { type: "directory", mode: 0o755 });
  }

  async deleteFile(path, recursive, force) {
    const entry = this.entries.get(path);
    if (!entry) {
      if (force) return;
      const err = new Error(`ENOENT: no such file or directory, rm '${path}'`);
      err.code = "ENOENT";
      throw err;
    }
    if (entry.type === "directory" && !recursive) {
      const hasChildren = [...this.entries.keys()].some(
        (k) => k.startsWith(`${path}/`) && k !== path,
      );
      if (hasChildren) throw new Error(`ENOTEMPTY: directory not empty, rm '${path}'`);
    }
    for (const key of [...this.entries.keys()]) {
      if (key === path || key.startsWith(`${path}/`)) this.entries.delete(key);
    }
  }

  async access(path) {
    this.#require(path);
  }
}

export class FakeExecHandle {
  constructor(spec) {
    this.spec = spec;
    this.output = new EventEmitter();
    this.stdinChunks = [];
    this.stdinEnded = false;
    this.killed = false;
    this._resolve = null;
    this.result = new Promise((resolve) => {
      this._resolve = resolve;
    });
  }

  write(data) {
    this.stdinChunks.push(Buffer.from(data));
  }

  endStdin() {
    this.stdinEnded = true;
  }

  resize() {}

  kill() {
    this.killed = true;
    this._resolve({ exitCode: null, signal: 9 });
  }

  onOutput(listener) {
    this.output.on("chunk", listener);
  }

  /** test driver: emit guest output */
  emitOutput(stream, data) {
    this.output.emit("chunk", stream, Buffer.from(data));
  }

  /** test driver: complete the process */
  finish(exitCode = 0, signal = null) {
    this._resolve({ exitCode, signal });
  }
}

export class FakeVm {
  constructor(id = "fake-vm") {
    this.id = id;
    this.fs = new FakeFs();
    this.execCalls = [];
    this.handles = [];
    this.closed = false;
  }

  hostPid() {
    return null;
  }

  async close() {
    this.closed = true;
  }

  exec(spec) {
    this.execCalls.push(spec);
    const handle = new FakeExecHandle(spec);
    this.handles.push(handle);
    return handle;
  }
}

export class FakeProvider {
  constructor() {
    this.vms = [];
    this.specs = [];
  }

  async createVm(spec) {
    this.specs.push(spec);
    const vm = new FakeVm(`fake-vm-${this.vms.length}`);
    this.vms.push(vm);
    return vm;
  }
}
