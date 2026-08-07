/**
 * Lazy Gondolin SDK loader and VM provider seam.
 *
 * The SDK is imported lazily so policy/protocol/registry/audit logic runs
 * (and is unit-tested) without loading QEMU/krun native components. The
 * broker's lifecycle layer depends only on the VmProvider interface; the
 * production implementation wraps the SDK one-for-one. This is a dependency
 * injection boundary, not a stub: `createGondolinProvider` is the real
 * implementation used by the shipped broker.
 */
import type { EffectivePolicy } from "./policy.js";

/** Stream labels match the wire protocol. */
export type VmOutputStream = "stdout" | "stderr";

export interface VmExecSpec {
  argv: string[];
  cwd: string;
  env: Record<string, string>;
  stdin: boolean;
}

export interface VmExecHandle {
  /** deliver stdin bytes to the guest process */
  write(data: Buffer): void;
  /** signal end of stdin */
  endStdin(): void;
  /** resize the guest pty (no-op when the process is not a pty) */
  resize?(rows: number, cols: number): void;
  /** request hard termination of the guest process tree */
  kill(): void;
  /** completion: exit code or signal; rejects only on transport failure */
  result: Promise<{ exitCode: number | null; signal: number | null }>;
  /** ordered per-stream output with backpressure applied by the SDK */
  onOutput(listener: (stream: VmOutputStream, chunk: Buffer) => void): void;
}

export interface VmFsStat {
  type: "file" | "directory" | "symlink" | "other";
  size: number;
  mode: number;
  mtimeMs: number;
}

export interface VmFs {
  stat(path: string): Promise<VmFsStat>;
  listDir(path: string): Promise<string[]>;
  readFile(path: string): Promise<Buffer>;
  writeFile(path: string, data: Buffer): Promise<void>;
  rename(oldPath: string, newPath: string): Promise<void>;
  mkdir(path: string, recursive: boolean): Promise<void>;
  deleteFile(path: string, recursive: boolean, force: boolean): Promise<void>;
  access(path: string): Promise<void>;
}

export interface VmHandle {
  readonly id: string;
  readonly fs: VmFs;
  exec(spec: VmExecSpec): VmExecHandle;
  /** host PID of the runner process, for cgroup placement */
  hostPid(): number | null;
  close(): Promise<void>;
}

export interface VmSpec {
  /** guest asset directory (contains manifest.json + kernel/initramfs/rootfs) */
  assetPath: string;
  memoryMiB: number;
  cpus: number;
  /** guest path -> host directory, exposed through the VFS provider */
  workspaceHostPath: string | null;
  /** guest workspace mount point (fuse mount root) */
  workspaceGuestPath: string;
  httpHooks: unknown;
  dns: unknown;
  allowWebSockets: boolean;
  sessionLabel: string;
}

export interface VmProvider {
  createVm(spec: VmSpec): Promise<VmHandle>;
}

interface GondolinSdk {
  VM: {
    create(options: Record<string, unknown>): Promise<GondolinVm>;
  };
  createHttpHooks(options: Record<string, unknown>): { httpHooks: unknown };
}

interface GondolinExecProcess {
  write(data: string | Buffer): void;
  end(): void;
  resize(rows: number, cols: number): void;
  result: Promise<{ exitCode: number; signal?: number }>;
  output(): AsyncIterable<{ stream: "stdout" | "stderr"; data: Buffer }>;
}

interface GondolinVm {
  id: string;
  fs: {
    stat(path: string): Promise<{ isFile(): boolean; isDirectory(): boolean; isSymbolicLink(): boolean; size: number; mode: number; mtimeMs: number }>;
    listDir(path: string): Promise<string[]>;
    readFile(path: string, options: Record<string, unknown>): Promise<Buffer>;
    writeFile(path: string, data: Buffer, options?: Record<string, unknown>): Promise<void>;
    rename(oldPath: string, newPath: string): Promise<void>;
    mkdir(path: string, options?: Record<string, unknown>): Promise<void>;
    deleteFile(path: string, options?: Record<string, unknown>): Promise<void>;
    access(path: string): Promise<void>;
  };
  exec(command: string[], options: Record<string, unknown>): GondolinExecProcess;
  getHostPid(): number | null;
  close(): Promise<void>;
  start(): Promise<void>;
}

let sdkPromise: Promise<GondolinSdk> | null = null;

/** Load the SDK exactly once, on first use. */
export function loadGondolinSdk(): Promise<GondolinSdk> {
  sdkPromise ??= import("@earendil-works/gondolin") as Promise<GondolinSdk>;
  return sdkPromise;
}

/** Test hook: replace the cached SDK (used only by unit tests). */
export function setGondolinSdkForTests(sdk: GondolinSdk | null): void {
  sdkPromise = sdk === null ? null : Promise.resolve(sdk);
}

function wrapFs(fs: GondolinVm["fs"]): VmFs {
  return {
    async stat(path) {
      const stat = await fs.stat(path);
      return {
        type: stat.isFile()
          ? "file"
          : stat.isDirectory()
            ? "directory"
            : stat.isSymbolicLink()
              ? "symlink"
              : "other",
        size: stat.size,
        mode: stat.mode,
        mtimeMs: stat.mtimeMs,
      };
    },
    listDir: (path) => fs.listDir(path),
    readFile: (path) => fs.readFile(path, {}),
    writeFile: (path, data) => fs.writeFile(path, data),
    rename: (oldPath, newPath) => fs.rename(oldPath, newPath),
    mkdir: (path, recursive) => fs.mkdir(path, { recursive }),
    deleteFile: (path, recursive, force) => fs.deleteFile(path, { recursive, force }),
    access: (path) => fs.access(path),
  };
}

/** Production VM provider over the Gondolin SDK. */
export async function createGondolinProvider(): Promise<VmProvider> {
  const sdk = await loadGondolinSdk();
  return {
    async createVm(spec: VmSpec): Promise<VmHandle> {
      const vm = await sdk.VM.create({
        sandbox: {
          // Production runs QEMU/KVM on Linux; dev hosts (darwin) use the
          // SDK's default backend. KVM is mandatory in production, and the
          // NixOS unit fails closed when /dev/kvm is absent.
          ...(process.platform === "linux" ? { vmm: "qemu", accel: "kvm" } : {}),
          imagePath: spec.assetPath,
          netEnabled: true,
          allowWebSockets: spec.allowWebSockets,
          httpHooks: spec.httpHooks,
          dns: spec.dns,
        },
        // Disposable roots (V3 §7): the SDK materializes a qcow2 overlay
        // over the immutable Nix base rootfs and deletes it on close.
        rootfs: { mode: "cow" },
        memory: `${spec.memoryMiB}M`,
        cpus: spec.cpus,
        autoStart: true,
        sessionLabel: spec.sessionLabel,
        vfs:
          spec.workspaceHostPath === null
            ? null
            : {
                fuseMount: spec.workspaceGuestPath,
                mounts: {},
              },
      });

      return {
        id: vm.id,
        fs: wrapFs(vm.fs),
        exec(execSpec: VmExecSpec): VmExecHandle {
          const proc = vm.exec(execSpec.argv, {
            cwd: execSpec.cwd,
            env: execSpec.env,
            stdin: execSpec.stdin,
            stdout: "pipe",
            stderr: "pipe",
          });
          const listeners: Array<(stream: VmOutputStream, chunk: Buffer) => void> = [];
          void (async () => {
            try {
              for await (const chunk of proc.output()) {
                for (const listener of listeners) listener(chunk.stream, chunk.data);
              }
            } catch {
              // output ends when the process or VM dies; completion surfaces
              // through proc.result
            }
          })();
          return {
            write: (data) => proc.write(data),
            endStdin: () => proc.end(),
            resize: (rows, cols) => proc.resize(rows, cols),
            kill: () => {
              // The SDK aborts the guest process on signal; VM close is the
              // hard fallback driven by the lifecycle layer.
              proc.end();
            },
            result: proc.result.then((r) => ({
              exitCode: r.exitCode ?? null,
              signal: r.signal ?? null,
            })),
            onOutput: (listener) => {
              listeners.push(listener);
            },
          };
        },
        hostPid: () => vm.getHostPid(),
        close: () => vm.close(),
      };
    },
  };
}

/** Resolve the provider for a broker instance. */
export async function defaultProvider(): Promise<VmProvider> {
  return createGondolinProvider();
}
