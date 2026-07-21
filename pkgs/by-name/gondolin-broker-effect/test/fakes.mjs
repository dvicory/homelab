import path from "node:path"
import { Effect, Layer } from "effect"
import { BrokerActions } from "../dist/auth.js"
import { AuthorizationLive, BrokerPolicyKernelLive } from "../dist/authorization-live.js"
import { BrokerConfig } from "../dist/config.js"
import { EnvironmentsLive } from "../dist/environments.js"
import { ExecutorLive } from "../dist/exec.js"
import { FilesLive } from "../dist/files.js"
import { RegistryLive } from "../dist/registry.js"
import { VmRuntime } from "../dist/runtime.js"

const errno = (code, message) => Object.assign(new Error(message), { code })

const makeFileSystem = () => {
  const entries = new Map([["/workspace", { type: "directory", data: Buffer.alloc(0) }]])
  return {
    entries,
    service: {
      async stat(filePath) {
        const entry = entries.get(filePath)
        if (entry === undefined) throw errno("ENOENT", filePath)
        return { type: entry.type, size: entry.data.byteLength, mode: entry.type === "directory" ? 0o755 : 0o644, mtimeMs: 0 }
      },
      async list(directory) {
        const entry = entries.get(directory)
        if (entry === undefined) throw errno("ENOENT", directory)
        if (entry.type !== "directory") throw errno("ENOTDIR", directory)
        const prefix = directory === "/" ? "/" : `${directory}/`
        return [...new Set([...entries.keys()]
          .filter((candidate) => candidate.startsWith(prefix) && candidate !== directory)
          .map((candidate) => candidate.slice(prefix.length).split("/")[0]))]
      },
      async read(filePath) {
        const entry = entries.get(filePath)
        if (entry === undefined) throw errno("ENOENT", filePath)
        return entry.data
      },
      async write(filePath, data, options) {
        if (!options.create && !entries.has(filePath)) throw errno("ENOENT", filePath)
        entries.set(filePath, { type: "file", data: Buffer.from(data) })
      },
      async mkdir(directory) {
        if (entries.has(directory)) throw errno("EEXIST", directory)
        entries.set(directory, { type: "directory", data: Buffer.alloc(0) })
      },
      async remove(filePath) {
        if (!entries.delete(filePath)) throw errno("ENOENT", filePath)
      }
    }
  }
}

export const makeFakeRuntime = () => {
  const state = { created: [], closed: [], execs: [] }
  const runtime = {
    create: (spec) => Effect.sync(() => {
      const id = `fake-${state.created.length + 1}`
      const fs = makeFileSystem()
      let closed = false
      const vm = {
        id,
        hostPid: () => 1000 + state.created.length,
        fs: fs.service,
        exec: async ({ argv }) => {
          state.execs.push([...argv])
          let ended = false
          const hanging = argv[0] === "hang"
          return {
            output: {
              async *[Symbol.asyncIterator]() {
                if (hanging) {
                  await new Promise((resolve) => {
                    const timer = setInterval(() => {
                      if (closed) {
                        clearInterval(timer)
                        resolve()
                      }
                    }, 2)
                  })
                  return
                }
                yield { stream: "stdout", data: Buffer.from(argv.join(" ")) }
              }
            },
            result: hanging
              ? new Promise((resolve) => {
                  const timer = setInterval(() => {
                    if (closed) {
                      clearInterval(timer)
                      resolve({ exitCode: null, signal: 9 })
                    }
                  }, 2)
                })
              : Promise.resolve({ exitCode: 0, signal: null }),
            write: () => undefined,
            end: () => {
              if (argv[0] === "stdin-disabled") throw new Error("stdin was not enabled for this exec")
              ended = true
            },
            get ended() { return ended }
          }
        },
        close: async () => {
          if (!closed) state.closed.push(id)
          closed = true
        }
      }
      state.created.push({ id, spec, vm, entries: fs.entries })
      return vm
    })
  }
  return { state, layer: Layer.succeed(VmRuntime, runtime) }
}

export const makePolicyFile = (overrides = {}) => ({
  version: 1,
  policyGeneration: 1,
  policy: {
    version: 1,
    statements: [
      {
        effect: "allow",
        actions: BrokerActions.filter((action) => action !== "environment.ensure"),
        resources: ["*"],
        limits: {
          memoryMiB: 512,
          cpus: 2,
          maxCommandMs: 1000,
          maxOutputBytes: 4096,
          maxInputBytes: 1024,
          maxFileBytes: 1024,
          maxListEntries: 32,
          maxConcurrentExecs: 2,
          timeoutMs: 1000,
          outputBytes: 4096,
          inputBytes: 1024,
          bytes: 1024,
          entries: 32
        }
      },
      {
        effect: "allow",
        actions: ["environment.ensure"],
        resources: ["worklane:default:environment:*"],
        obligations: [{ kind: "network", bundleId: "worklane:default" }],
        limits: {
          memoryMiB: 512,
          cpus: 2,
          maxCommandMs: 1000,
          maxOutputBytes: 4096,
          maxInputBytes: 1024,
          maxFileBytes: 1024,
          maxListEntries: 32,
          maxConcurrentExecs: 2,
          timeoutMs: 1000,
          outputBytes: 4096,
          inputBytes: 1024,
          bytes: 1024,
          entries: 32
        }
      }
    ]
  },
  defaultExecutor: "hermes-gateway",
  defaultAuthorityClass: "default",
  maxEnvironments: 4,
  assets: { default: { path: "/fake/root.qcow2", buildId: "fake-build" } },
  networkPolicies: {
    "worklane:default": { mode: "deny-all", destinations: [] }
  },
  worklanes: {
    default: {
      asset: "default",
      memoryMiB: 512,
      cpus: 2,
      workspaceGuestPath: "/workspace",
      limits: {
        maxCommandMs: 1000,
        maxOutputBytes: 4096,
        maxInputBytes: 1024,
        maxFileBytes: 1024,
        maxListEntries: 32,
        maxConcurrentExecs: 2
      }
    }
  },
  ...overrides
})

export const makeTestLayer = (stateDir, options = {}) => {
  const fake = makeFakeRuntime()
  const config = {
    policyPath: path.join(stateDir, "policy.json"),
    stateDir,
    workspaceRoot: path.join(stateDir, "workspaces"),
    databasePath: path.join(stateDir, "broker.sqlite"),
    socketPath: path.join(stateDir, "broker.sock"),
    profile: "test",
    policyFile: makePolicyFile(options.policyFile)
  }
  const configLayer = Layer.succeed(BrokerConfig, config)
  const infrastructure = Layer.mergeAll(configLayer, fake.layer)
  const policy = BrokerPolicyKernelLive.pipe(Layer.provideMerge(infrastructure))
  const authorization = AuthorizationLive.pipe(Layer.provideMerge(policy))
  const registry = RegistryLive.pipe(Layer.provideMerge(authorization))
  const environments = EnvironmentsLive.pipe(Layer.provideMerge(registry))
  const executor = ExecutorLive.pipe(Layer.provideMerge(environments))
  const layer = FilesLive.pipe(Layer.provideMerge(executor))
  return { config, fake, layer }
}
