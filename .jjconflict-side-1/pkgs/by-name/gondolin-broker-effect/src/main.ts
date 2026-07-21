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
import { AuthorizationLive, BrokerPolicyKernelLive } from "./authorization-live.js";
import { BrokerConfig, BrokerConfigLive } from "./config.js";
import { EnvironmentsLive } from "./environments.js";
import { ExecutorLive } from "./exec.js";
import { FilesLive } from "./files.js";
import { makeHttpApp } from "./http.js";
import { RegistryLive } from "./registry.js";
import { VmRuntimeLive } from "./runtime.js";

export const BrokerLive = (() => {
  const infrastructure = Layer.mergeAll(BrokerConfigLive, VmRuntimeLive);
  const policy = BrokerPolicyKernelLive.pipe(Layer.provideMerge(infrastructure));
  const authorization = AuthorizationLive.pipe(Layer.provideMerge(policy));
  const registry = RegistryLive.pipe(Layer.provideMerge(authorization));
  const environments = EnvironmentsLive.pipe(Layer.provideMerge(registry));
  const executor = ExecutorLive.pipe(Layer.provideMerge(environments));
  return FilesLive.pipe(Layer.provideMerge(executor));
})();

const activatedSocket = (): { readonly fd: 3 } | null => {
  const listenFds = Number(process.env.LISTEN_FDS ?? "0");
  if (listenFds === 0) return null;
  const listenPid = Number(process.env.LISTEN_PID ?? "0");
  if (listenPid !== process.pid) {
    throw new Error(`LISTEN_PID ${listenPid} does not match broker pid ${process.pid}`);
  }
  if (listenFds !== 1) {
    throw new Error(`expected exactly one systemd activation socket, received ${listenFds}`);
  }
  return { fd: 3 };
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
    const app = yield* makeHttpApp;
    const activation = activatedSocket();
    const activatedListenOptions: Net.ListenOptions & { readonly fd: number } = { fd: 3 };
    const listenOptions: Net.ListenOptions =
      activation === null ? { path: config.socketPath } : activatedListenOptions;
    if (activation === null) {
      yield* Effect.tryPromise({
        try: async () => {
          await fs.mkdir(path.dirname(config.socketPath), { recursive: true, mode: 0o700 });
          try {
            await fs.lstat(config.socketPath);
            throw new Error(`refusing to replace existing socket path: ${config.socketPath}`);
          } catch (error) {
            if (!(error instanceof Error) || !("code" in error) || error.code !== "ENOENT") throw error;
          }
        },
        catch: (error) => error,
      });
    }
    const server = yield* makeNodeServer(config.socketPath, listenOptions);
    if (activation === null) {
      yield* Effect.tryPromise({ try: () => fs.chmod(config.socketPath, 0o600), catch: (error) => error });
      yield* Effect.addFinalizer(() =>
        Effect.tryPromise({ try: () => fs.rm(config.socketPath, { force: true }), catch: () => undefined }).pipe(Effect.ignore),
      );
    }
    yield* Effect.logInfo("Gondolin Effect broker listening", { socketPath: config.socketPath });
    yield* HttpServer.serveEffect(HttpMiddleware.logger(app)).pipe(
      Effect.provideService(HttpServer.HttpServer, server),
    );
    return yield* Effect.never;
  }),
);

NodeRuntime.runMain(serve.pipe(Effect.provide(BrokerLive)));
