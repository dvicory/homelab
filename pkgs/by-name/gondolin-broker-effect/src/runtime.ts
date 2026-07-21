import { createRequire } from "node:module";
import { Context, Effect, Layer } from "effect";
import { brokerError, type BrokerError } from "./errors.js";

export interface VmCreateSpec {
  readonly assetPath: string;
  readonly memoryMiB: number;
  readonly cpus: number;
  readonly workspaceHostPath: string;
  readonly workspaceGuestPath: string;
  readonly sessionLabel: string;
}

export interface VmStat {
  readonly type: "file" | "directory" | "symlink" | "other";
  readonly size: number;
  readonly mode: number;
  readonly mtimeMs: number;
}

export interface VmOutput {
  readonly stream: "stdout" | "stderr";
  readonly data: Uint8Array;
}

export interface VmProcess {
  readonly output: AsyncIterable<VmOutput>;
  readonly result: Promise<{ readonly exitCode: number | null; readonly signal: number | null }>;
  readonly write: (data: Uint8Array) => void;
  readonly end: () => void;
}

export interface VmFileSystem {
  readonly stat: (path: string) => Promise<VmStat>;
  readonly list: (path: string) => Promise<ReadonlyArray<string>>;
  readonly read: (path: string) => Promise<Uint8Array>;
  readonly write: (path: string, data: Uint8Array, options: { readonly create: boolean; readonly truncate: boolean }) => Promise<void>;
  readonly mkdir: (path: string, recursive: boolean) => Promise<void>;
  readonly remove: (path: string, recursive: boolean) => Promise<void>;
}

export interface VmHandle {
  readonly id: string;
  readonly hostPid: () => number | null;
  readonly fs: VmFileSystem;
  readonly exec: (spec: {
    readonly argv: ReadonlyArray<string>;
    readonly cwd?: string;
    readonly env?: Readonly<Record<string, string>>;
  }) => Promise<VmProcess>;
  readonly close: () => Promise<void>;
}

export interface VmRuntimeService {
  readonly create: (spec: VmCreateSpec) => Effect.Effect<VmHandle, BrokerError>;
}

export class VmRuntime extends Context.Tag("@agent-x/gondolin-broker-effect/VmRuntime")<
  VmRuntime,
  VmRuntimeService
>() {}

interface GondolinProcess {
  readonly result: Promise<{ readonly exitCode?: number; readonly signal?: number }>;
  output(): AsyncIterable<{ readonly stream: "stdout" | "stderr"; readonly data: Buffer }>;
  write(data: string | Buffer): void;
  end(): void;
}

interface GondolinVm {
  readonly id: string;
  readonly fs: {
    stat(path: string): Promise<{ isFile(): boolean; isDirectory(): boolean; isSymbolicLink(): boolean; size: number; mode: number; mtimeMs: number }>;
    listDir(path: string): Promise<string[]>;
    readFile(path: string, options: Record<string, unknown>): Promise<Buffer>;
    writeFile(path: string, data: Buffer, options?: Record<string, unknown>): Promise<void>;
    mkdir(path: string, options?: Record<string, unknown>): Promise<void>;
    deleteFile(path: string, options?: Record<string, unknown>): Promise<void>;
  };
  exec(argv: string[], options: Record<string, unknown>): GondolinProcess;
  getHostPid(): number | null;
  close(): Promise<void>;
}

interface GondolinSdk {
  readonly VM: {
    create(options: Record<string, unknown>): Promise<GondolinVm>;
  };
  readonly RealFSProvider: new (rootPath: string) => unknown;
}

const require = createRequire(import.meta.url);
let sdkPromise: Promise<GondolinSdk> | undefined;

const isGondolinSdk = (value: unknown): value is GondolinSdk =>
  typeof value === "object" &&
  value !== null &&
  "VM" in value &&
  typeof value.VM === "object" &&
  value.VM !== null &&
  "create" in value.VM &&
  typeof value.VM.create === "function" &&
  "RealFSProvider" in value &&
  typeof value.RealFSProvider === "function";

const loadSdk = (): Promise<GondolinSdk> => {
  if (sdkPromise === undefined) {
    const loaded: unknown = require("@earendil-works/gondolin");
    if (!isGondolinSdk(loaded)) {
      return Promise.reject(new Error("Gondolin SDK exports do not match the broker adapter"));
    }
    sdkPromise = Promise.resolve(loaded);
  }
  return sdkPromise;
};

const runtimeFailure = (operation: string, error: unknown): BrokerError =>
  brokerError(
    operation === "create" ? "runtime.start_failed" : "runtime.operation_failed",
    `Gondolin ${operation} failed`,
    { cause: error instanceof Error ? error.message : String(error) },
  );

const createVm = (spec: VmCreateSpec): Effect.Effect<VmHandle, BrokerError> =>
  Effect.tryPromise({
    try: async () => {
      const sdk = await loadSdk();
      const vm = await sdk.VM.create({
        sandbox: {
          ...(process.platform === "linux" ? { vmm: "qemu", accel: "kvm" } : {}),
          imagePath: spec.assetPath,
          netEnabled: false,
        },
        rootfs: { mode: "cow" },
        memory: `${spec.memoryMiB}M`,
        cpus: spec.cpus,
        autoStart: true,
        sessionLabel: spec.sessionLabel,
        vfs: {
          fuseMount: spec.workspaceGuestPath,
          mounts: { "/": new sdk.RealFSProvider(spec.workspaceHostPath) },
        },
      });

      const fs: VmFileSystem = {
        stat: async (path) => {
          const value = await vm.fs.stat(path);
          return {
            type: value.isFile()
              ? "file"
              : value.isDirectory()
                ? "directory"
                : value.isSymbolicLink()
                  ? "symlink"
                  : "other",
            size: value.size,
            mode: value.mode,
            mtimeMs: value.mtimeMs,
          };
        },
        list: (path) => vm.fs.listDir(path),
        read: (path) => vm.fs.readFile(path, {}),
        write: (path, data, options) => vm.fs.writeFile(path, Buffer.from(data), options),
        mkdir: (path, recursive) => vm.fs.mkdir(path, { recursive }),
        remove: (path, recursive) => vm.fs.deleteFile(path, { recursive, force: false }),
      };

      return {
        id: vm.id,
        hostPid: () => vm.getHostPid(),
        fs,
        exec: async (request) => {
          const proc = vm.exec([...request.argv], {
            ...(request.cwd === undefined ? {} : { cwd: request.cwd }),
            ...(request.env === undefined ? {} : { env: request.env }),
            stdout: "pipe",
            stderr: "pipe",
          });
          return {
            output: proc.output(),
            result: proc.result.then((result) => ({
              exitCode: result.exitCode ?? null,
              signal: result.signal ?? null,
            })),
            write: (data) => proc.write(Buffer.from(data)),
            end: () => proc.end(),
          };
        },
        close: () => vm.close(),
      } satisfies VmHandle;
    },
    catch: (error) => runtimeFailure("create", error),
  });

export const VmRuntimeLive = Layer.succeed(VmRuntime, { create: createVm });
