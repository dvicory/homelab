#!/usr/bin/env node
import * as HttpServer from "@effect/platform/HttpServer";
import * as HttpMiddleware from "@effect/platform/HttpMiddleware";
import * as NodeHttpServer from "@effect/platform-node/NodeHttpServer";
import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import { createServer } from "node:http";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import type * as Net from "node:net";
import { Effect, Layer } from "effect";
import { TaskRunActivationsLive } from "./task-run-activations.js";
import { AuthorizationLive, BrokerPolicyKernelLive } from "./authorization-live.js";
import { BrokerConfig, BrokerConfigLive } from "./config.js";
import { BrokerDatabaseLive } from "./database.js";
import { EnvironmentsLive } from "./environments.js";
import { ExecutorLive } from "./exec.js";
import { FilesLive } from "./files.js";
import { makeControlHttpApp, makeHttpApp } from "./http.js";
import { AccessGrantsLive } from "./grants.js";
import { HandoffStoreLive } from "./workspace-handoff/repository.js";
import { HandoffOperationsLive } from "./workspace-handoff/service.js";
import { HandoffStorageLive } from "./workspace-handoff/frozen-tree.js";
import { InputPreparationRepositoryLive } from "./task-run-inputs/repository.js";
import { InputPreparationsLive } from "./task-run-inputs/service.js";
import { RegistryLive } from "./registry.js";
import { VmRuntimeLive } from "./runtime.js";
import { WorkspacesLive } from "./workspaces.js";
import { WorkspaceBranchesLive } from "./workspace-branches.js";
import { ProjectWorkspaceStoreLive } from "./project-workspace/store.js";
import { ProjectWorkspacesLive } from "./project-workspace/service.js";

export const BrokerLive = (() => {
  const infrastructure = Layer.mergeAll(BrokerConfigLive, VmRuntimeLive);
  const policy = BrokerPolicyKernelLive.pipe(Layer.provideMerge(infrastructure));
  const authorization = AuthorizationLive.pipe(Layer.provideMerge(policy));
  const database = BrokerDatabaseLive.pipe(Layer.provideMerge(authorization));
  const workspaces = WorkspacesLive.pipe(Layer.provideMerge(database));
  const projectStore = ProjectWorkspaceStoreLive.pipe(Layer.provideMerge(workspaces));
  const projectWorkspaces = ProjectWorkspacesLive.pipe(Layer.provideMerge(projectStore));
  const registry = RegistryLive.pipe(Layer.provideMerge(projectWorkspaces));
  const inputRepository = InputPreparationRepositoryLive.pipe(Layer.provideMerge(database));
  const inputPreparations = InputPreparationsLive.pipe(Layer.provideMerge(inputRepository));
  const runActivations = TaskRunActivationsLive.pipe(Layer.provideMerge(Layer.mergeAll(registry, inputPreparations)));
  const handoffs = HandoffStoreLive.pipe(Layer.provideMerge(runActivations));
  const handoffStorage = HandoffStorageLive.pipe(Layer.provideMerge(handoffs));
  const grants = AccessGrantsLive.pipe(Layer.provideMerge(handoffStorage));
  const environments = EnvironmentsLive.pipe(Layer.provideMerge(grants));
  const workspaceBranches = WorkspaceBranchesLive.pipe(Layer.provideMerge(environments));
  const handoffOperations = HandoffOperationsLive.pipe(Layer.provideMerge(workspaceBranches));
  const executor = ExecutorLive.pipe(Layer.provideMerge(handoffOperations));
  return FilesLive.pipe(Layer.provideMerge(executor));
})();

type ActivatedSockets = {
  readonly execution: { readonly fd: number };
  readonly control: { readonly fd: number };
};

const activatedSockets = (): ActivatedSockets | null => {
  const listenFds = Number(process.env.LISTEN_FDS ?? "0");
  if (listenFds === 0) return null;
  const listenPid = Number(process.env.LISTEN_PID ?? "0");
  if (listenPid !== process.pid) {
    throw new Error(`LISTEN_PID ${listenPid} does not match broker pid ${process.pid}`);
  }
  const names = (process.env.LISTEN_FDNAMES ?? "").split(":");
  if (listenFds !== 2 || names.length !== 2) {
    throw new Error(`expected execution and control activation sockets, received ${listenFds}`);
  }
  const descriptors = Object.fromEntries(names.map((name, index) => [name, { fd: 3 + index }]));
  if (descriptors.execution === undefined || descriptors.control === undefined) {
    throw new Error(`activation sockets must be named execution and control, received ${names.join(",")}`);
  }
  return {
    execution: descriptors.execution,
    control: descriptors.control,
  };
};

// @effect/platform-node's stock constructor calls server.address() after
// listen(). Node returns null when adopting an inherited Unix listener, so
// build the small HttpServer service explicitly for systemd activation.
const makeNodeServer = (socketPath: string, options: Net.ListenOptions) =>
  Effect.gen(function* () {
    const nodeServer = yield* Effect.acquireRelease(
      Effect.sync(() => createServer()),
      (server) =>
        Effect.async<void>((resume) => {
          if (!server.listening) {
            resume(Effect.void);
            return;
          }
          server.close((error) => resume(error ? Effect.die(error) : Effect.void));
        }),
    );
    yield* Effect.async<void, Error>((resume) => {
      const onError = (error: Error) => {
        nodeServer.off("error", onError);
        resume(Effect.fail(error));
      };
      nodeServer.once("error", onError);
      nodeServer.listen(options, () => {
        nodeServer.off("error", onError);
        resume(Effect.void);
      });
    });
    return HttpServer.make({
      address: { _tag: "UnixAddress", path: socketPath },
      serve: (httpApp, middleware) =>
        Effect.gen(function* () {
          const handler =
            middleware === undefined
              ? yield* NodeHttpServer.makeHandler(httpApp)
              : yield* NodeHttpServer.makeHandler(httpApp, middleware);
          nodeServer.on("request", handler);
          yield* Effect.addFinalizer(() =>
            Effect.sync(() => {
              nodeServer.off("request", handler);
            }),
          );
        }),
    });
  });


const serve = Effect.scoped(
  Effect.gen(function* () {
    const config = yield* BrokerConfig;
    const executionApp = yield* makeHttpApp;
    const controlApp = yield* makeControlHttpApp;
    const activation = activatedSockets();

    const planes = [
      {
        name: "execution",
        socketPath: config.socketPath,
        app: executionApp,
        activation: activation?.execution,
      },
      {
        name: "control",
        socketPath: config.controlSocketPath,
        app: controlApp,
        activation: activation?.control,
      },
    ] as const;

    for (const plane of planes) {
      if (plane.activation === undefined) {
        yield* Effect.tryPromise({
          try: async () => {
            await fs.mkdir(path.dirname(plane.socketPath), { recursive: true, mode: 0o700 });
            try {
              await fs.lstat(plane.socketPath);
              throw new Error(`refusing to replace existing socket path: ${plane.socketPath}`);
            } catch (error) {
              if (!(error instanceof Error) || !("code" in error) || error.code !== "ENOENT") throw error;
            }
          },
          catch: (error) => error,
        });
      }

      const activatedListenOptions: Net.ListenOptions & { readonly fd: number } = {
        fd: plane.activation?.fd ?? -1,
      };
      const listenOptions: Net.ListenOptions =
        plane.activation === undefined ? { path: plane.socketPath } : activatedListenOptions;
      const server = yield* makeNodeServer(plane.socketPath, listenOptions);
      if (plane.activation === undefined) {
        yield* Effect.tryPromise({ try: () => fs.chmod(plane.socketPath, 0o600), catch: (error) => error });
        yield* Effect.addFinalizer(() =>
          Effect.tryPromise({
            try: () => fs.rm(plane.socketPath, { force: true }),
            catch: () => undefined,
          }).pipe(Effect.ignore),
        );
      }
      yield* Effect.logInfo("Gondolin Effect broker listening", {
        plane: plane.name,
        socketPath: plane.socketPath,
      });
      yield* HttpServer.serveEffect(HttpMiddleware.logger(plane.app)).pipe(
        Effect.provideService(HttpServer.HttpServer, server),
      );
    }
    return yield* Effect.never;
  }),
);

NodeRuntime.runMain(serve.pipe(Effect.provide(BrokerLive)));
