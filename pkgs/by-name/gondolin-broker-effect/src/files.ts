import * as path from "node:path";
import { Context, Effect, Layer } from "effect";
import { Authorization, type BrokerAction } from "./auth.js";
import type {
  FileRef,
  ListFileRequest,
  MakeDirectoryRequest,
  ReadFileRequest,
  RemoveFileRequest,
  WriteFileRequest,
} from "./domain.js";
import { Environments, type LiveEnvironment } from "./environments.js";
import { brokerError, type BrokerError } from "./errors.js";

export interface FileStatResult {
  readonly path: string;
  readonly type: "file" | "directory" | "symlink" | "other";
  readonly size: number;
  readonly mode: number;
  readonly mtimeMs: number;
}

export interface FilesService {
  readonly stat: (request: FileRef) => Effect.Effect<FileStatResult, BrokerError>;
  readonly list: (request: ListFileRequest) => Effect.Effect<{ readonly entries: ReadonlyArray<string> }, BrokerError>;
  readonly read: (request: ReadFileRequest) => Effect.Effect<{ readonly dataBase64: string; readonly size: number }, BrokerError>;
  readonly write: (request: WriteFileRequest) => Effect.Effect<{ readonly size: number }, BrokerError>;
  readonly mkdir: (request: MakeDirectoryRequest) => Effect.Effect<void, BrokerError>;
  readonly remove: (request: RemoveFileRequest) => Effect.Effect<void, BrokerError>;
}

export class Files extends Context.Tag("@agent-x/gondolin-broker-effect/Files")<Files, FilesService>() {}

const normalizeGuestPath = (environment: LiveEnvironment, requested: string): Effect.Effect<string, BrokerError> =>
  Effect.gen(function* () {
    if (requested.includes("\0")) {
      return yield* brokerError("fs.path_forbidden", "file path contains a NUL byte");
    }
    const root = path.posix.normalize(environment.workspaceGuestPath);
    const resolved = requested.startsWith("/")
      ? path.posix.normalize(requested)
      : path.posix.resolve(root, requested);
    if (resolved !== root && !resolved.startsWith(`${root}/`)) {
      return yield* brokerError("fs.path_forbidden", "file path escapes the workspace", {
        requested,
        workspace: root,
      });
    }
    return resolved;
  });

const mapFileFailure = (operation: string, filePath: string, error: unknown): BrokerError => {
  const code = typeof error === "object" && error !== null && "code" in error
    ? String((error as { readonly code: unknown }).code)
    : undefined;
  if (code === "ENOENT") return brokerError("fs.not_found", `${operation} target does not exist`, { path: filePath });
  if (code === "EEXIST") return brokerError("fs.exists", `${operation} target already exists`, { path: filePath });
  return brokerError("runtime.operation_failed", `guest filesystem ${operation} failed`, {
    path: filePath,
    cause: error instanceof Error ? error.message : String(error),
  });
};

const decodeBase64 = (encoded: string): Effect.Effect<Buffer, BrokerError> =>
  Effect.gen(function* () {
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
      return yield* brokerError("request.invalid", "dataBase64 is not canonical base64");
    }
    return Buffer.from(encoded, "base64");
  });

const make = Effect.gen(function* () {
  const authorization = yield* Authorization;
  const environments = yield* Environments;

  const withFile = <A>(
    request: FileRef,
    action: BrokerAction,
    operation: (environment: LiveEnvironment, guestPath: string, limits: Readonly<Record<string, number>>) => Effect.Effect<A, BrokerError>,
    requestedLimits?: Readonly<Record<string, number>>,
  ): Effect.Effect<A, BrokerError> =>
    Effect.scoped(
      Effect.gen(function* () {
        const environment = yield* environments.lease({
          environmentKey: request.environmentKey,
          generation: request.generation,
          ...(request.taskRun === undefined ? {} : { taskRun: request.taskRun }),
        });
        const guestPath = yield* normalizeGuestPath(environment, request.path);
        const decision = yield* authorization.authorize({
          action,
          resource: `environment:${request.environmentKey}/file:${guestPath}`,
          ...(requestedLimits === undefined ? {} : { requestedLimits }),
        });
        return yield* operation(environment, guestPath, decision.limits);
      }),
    );

  const stat = (request: FileRef) =>
    withFile(request, "fs.stat", (environment, guestPath) =>
      Effect.tryPromise({
        try: () => environment.vm.fs.stat(guestPath),
        catch: (error) => mapFileFailure("stat", guestPath, error),
      }).pipe(Effect.map((value) => ({ path: guestPath, ...value }))),
    );

  const list = (request: ListFileRequest) => {
    const requestedLimit = request.limit ?? Number.MAX_SAFE_INTEGER;
    return withFile(
      request,
      "fs.list",
      (environment, guestPath, limits) =>
        Effect.gen(function* () {
          const cap = Math.min(
            requestedLimit,
            environment.limits.maxListEntries,
            limits.entries ?? Number.POSITIVE_INFINITY,
          );
          const value = yield* Effect.tryPromise({
            try: () => environment.vm.fs.list(guestPath),
            catch: (error) => mapFileFailure("list", guestPath, error),
          });
          if (value.length > cap) {
            return yield* brokerError("fs.size_limit", "directory exceeds its entry limit", {
              path: guestPath,
              entryLimit: cap,
              observedEntries: value.length,
            });
          }
          return { entries: [...value].sort() };
        }),
      { entries: Math.min(requestedLimit, request.limit ?? Number.MAX_SAFE_INTEGER) },
    );
  };

  const read = (request: ReadFileRequest) => {
    const requestedMax = request.maxBytes ?? Number.MAX_SAFE_INTEGER;
    return withFile(
      request,
      "fs.read",
      (environment, guestPath, limits) =>
        Effect.gen(function* () {
          const cap = Math.min(
            requestedMax,
            environment.limits.maxFileBytes,
            limits.bytes ?? Number.POSITIVE_INFINITY,
          );
          const metadata = yield* Effect.tryPromise({
            try: () => environment.vm.fs.stat(guestPath),
            catch: (error) => mapFileFailure("read", guestPath, error),
          });
          if (metadata.type !== "file") {
            return yield* brokerError("fs.unsafe_type", "read target is not a regular file", {
              path: guestPath,
              type: metadata.type,
            });
          }
          if (metadata.size > cap) {
            return yield* brokerError("fs.size_limit", "file exceeds its read byte limit", {
              path: guestPath,
              byteLimit: cap,
              observedBytes: metadata.size,
            });
          }
          const data = yield* Effect.tryPromise({
            try: () => environment.vm.fs.read(guestPath),
            catch: (error) => mapFileFailure("read", guestPath, error),
          });
          if (data.byteLength > cap) {
            return yield* brokerError("fs.size_limit", "file grew beyond its read byte limit", {
              path: guestPath,
              byteLimit: cap,
              observedBytes: data.byteLength,
            });
          }
          return { dataBase64: Buffer.from(data).toString("base64"), size: data.byteLength };
        }),
      { bytes: Math.min(requestedMax, request.maxBytes ?? Number.MAX_SAFE_INTEGER) },
    );
  };

  const write = (request: WriteFileRequest) =>
    Effect.flatMap(decodeBase64(request.dataBase64), (data) =>
      withFile(
        request,
        "fs.write",
        (environment, guestPath, limits) =>
          Effect.gen(function* () {
            const cap = Math.min(environment.limits.maxFileBytes, limits.bytes ?? Number.POSITIVE_INFINITY);
            if (data.byteLength > cap) {
              return yield* brokerError("fs.size_limit", "write exceeds its byte limit", {
                path: guestPath,
                byteLimit: cap,
                receivedBytes: data.byteLength,
              });
            }
            yield* Effect.tryPromise({
              try: () => environment.vm.fs.write(guestPath, data, {
                create: request.create ?? true,
                truncate: request.truncate ?? true,
              }),
              catch: (error) => mapFileFailure("write", guestPath, error),
            });
            return { size: data.byteLength };
          }),
        { bytes: data.byteLength },
      ),
    );

  const mkdir = (request: MakeDirectoryRequest) =>
    withFile(request, "fs.mkdir", (environment, guestPath) =>
      Effect.tryPromise({
        try: () => environment.vm.fs.mkdir(guestPath, request.recursive ?? false),
        catch: (error) => mapFileFailure("mkdir", guestPath, error),
      }),
    );

  const remove = (request: RemoveFileRequest) =>
    withFile(request, "fs.remove", (environment, guestPath) => {
      if (guestPath === path.posix.normalize(environment.workspaceGuestPath)) {
        return brokerError("fs.path_forbidden", "cannot remove the workspace root", { path: guestPath });
      }
      return Effect.tryPromise({
        try: () => environment.vm.fs.remove(guestPath, request.recursive ?? false),
        catch: (error) => mapFileFailure("remove", guestPath, error),
      });
    });

  return { stat, list, read, write, mkdir, remove } satisfies FilesService;
});

export const FilesLive = Layer.effect(Files, make);
