import {
  RealFSProvider,
  VM as GondolinVM,
  type DebugComponent,
  type DebugConfig,
  type DebugFlag,
} from "@earendil-works/gondolin";
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

const isDebugFlag = (value: string): value is DebugFlag =>
  value === "net" || value === "exec" || value === "vfs" || value === "protocol";

export const parseGondolinDebug = (
  value: string | undefined = process.env.GONDOLIN_DEBUG,
): DebugConfig => {
  if (value === undefined || value === "") return false;
  if (value === "all") return true;
  const components = value.split(",").map((component) => component.trim()).filter(Boolean);
  const invalid = components.find((component) => !isDebugFlag(component));
  if (invalid !== undefined) {
    throw new Error(`Unknown Gondolin debug component: ${invalid}`);
  }
  return components.filter(isDebugFlag);
};

const runtimeFailure = (operation: string, error: unknown): BrokerError =>
  brokerError(
    operation === "create" ? "runtime.start_failed" : "runtime.operation_failed",
    `Gondolin ${operation} failed`,
    { cause: error instanceof Error ? error.message : String(error) },
  );

export const makeCreateVm = (createGondolinVm: typeof GondolinVM.create) =>
  (spec: VmCreateSpec): Effect.Effect<VmHandle, BrokerError> =>
  Effect.tryPromise({
    try: async (signal) => {
      let vm: GondolinVM | undefined;
      const closeVm = async () => {
        if (vm !== undefined) await vm.close().catch(() => undefined);
      };
      const closeOnInterrupt = () => {
        void closeVm();
      };
      signal.addEventListener("abort", closeOnInterrupt, { once: true });

      try {
        const debug = parseGondolinDebug();
        const debugLog =
          debug === false
            ? undefined
            : (component: DebugComponent, message: string) => {
                process.stderr.write(`[gondolin:${component}] ${message.replace(/\n$/, "")}\n`);
              };
        vm = await createGondolinVm({
          sandbox: {
            ...(process.platform === "linux" ? { vmm: "qemu", accel: "kvm" } : {}),
            imagePath: spec.assetPath,
            netEnabled: false,
            ...(debug === false ? {} : { debug }),
          },
          rootfs: { mode: "cow" },
          memory: `${spec.memoryMiB}M`,
          cpus: spec.cpus,
          autoStart: false,
          sessionLabel: spec.sessionLabel,
          ...(debugLog === undefined ? {} : { debugLog }),
          vfs: {
            fuseMount: spec.workspaceGuestPath,
            mounts: { "/": new RealFSProvider(spec.workspaceHostPath) },
          },
        });
        const startedVm = vm;
        if (signal.aborted) throw new Error("VM creation was interrupted");
        await startedVm.start();
        if (signal.aborted) throw new Error("VM startup was interrupted");

        const fs: VmFileSystem = {
          stat: async (path) => {
            const value = await startedVm.fs.stat(path);
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
          list: (path) => startedVm.fs.listDir(path),
          read: (path) => startedVm.fs.readFile(path, {}),
          write: (path, data) => startedVm.fs.writeFile(path, data),
          mkdir: (path, recursive) => startedVm.fs.mkdir(path, { recursive }),
          remove: (path, recursive) => startedVm.fs.deleteFile(path, { recursive, force: false }),
        };

        return {
          id: startedVm.id,
          hostPid: () => startedVm.getHostPid(),
          fs,
          exec: async (request) => {
            const proc = startedVm.exec([...request.argv], {
              ...(request.cwd === undefined ? {} : { cwd: request.cwd }),
              ...(request.env === undefined ? {} : { env: request.env }),
              stdout: "pipe",
              stderr: "pipe",
            });
            const result = proc.result.then((value) => ({
              exitCode: value.exitCode ?? null,
              signal: value.signal ?? null,
            }));
            // Output failure can terminate the HTTP stream before it reaches
            // the exit event. Keep the result rejection observed regardless.
            void result.catch(() => undefined);
            return {
              output: proc.output(),
              result,
              write: (data) => proc.write(Buffer.from(data)),
              end: () => proc.end(),
            };
          },
          close: () => startedVm.close(),
        } satisfies VmHandle;
      } catch (error) {
        await closeVm();
        throw error;
      } finally {
        signal.removeEventListener("abort", closeOnInterrupt);
      }
    },
    catch: (error) => runtimeFailure("create", error),
  });
const createVm = makeCreateVm((options) => GondolinVM.create(options));


export const VmRuntimeLive = Layer.succeed(VmRuntime, { create: createVm });
