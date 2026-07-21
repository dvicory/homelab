import * as HttpRouter from "@effect/platform/HttpRouter";
import * as HttpServerRequest from "@effect/platform/HttpServerRequest";
import * as HttpServerResponse from "@effect/platform/HttpServerResponse";
import { Effect, Schema, Stream } from "effect";
import {
  EnvironmentRef,
  EnsureRequest,
  ExecRequest,
  FileRef,
  ListFileRequest,
  MakeDirectoryRequest,
  ReadFileRequest,
  RemoveFileRequest,
  StatusRequest,
  WriteFileRequest,
} from "./domain.js";
import { Environments } from "./environments.js";
import { asBrokerError, brokerError, publicErrorEvent, publicProblem, statusFor, type BrokerError } from "./errors.js";
import { Executor } from "./exec.js";
import { Files } from "./files.js";

const encoder = new TextEncoder();
const requestDecodeOptions = { onExcessProperty: "error" as const };

const errorResponse = (error: BrokerError) =>
  HttpServerResponse.unsafeJson(publicProblem(error), {
    status: statusFor(error),
    contentType: "application/problem+json",
    headers: {
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });

const logFailure = (operation: string, error: BrokerError) =>
  Effect.logError("Gondolin broker operation failed", {
    operation,
    reason: error.reason,
    status: statusFor(error),
    errorMessage: error.message,
    ...(error.details === undefined ? {} : { details: error.details }),
  });

const parseBody = <A, I>(schema: Schema.Schema<A, I>) =>
  HttpServerRequest.schemaBodyJson(schema, requestDecodeOptions).pipe(
    Effect.mapError((error) =>
      brokerError("request.invalid", "request body does not match the endpoint schema", {
        cause: String(error),
      }),
    ),
  );

const respond = <A, R>(operation: string, effect: Effect.Effect<A, BrokerError, R>) =>
  effect.pipe(
    Effect.tapError((error) => logFailure(operation, error)),
    Effect.match({
      onFailure: errorResponse,
      onSuccess: (body) =>
        HttpServerResponse.unsafeJson(body, {
          status: 200,
          headers: { "cache-control": "no-store" },
        }),
    }),
  );

export const makeHttpApp = Effect.gen(function* () {
  const environments = yield* Environments;
  const executor = yield* Executor;
  const files = yield* Files;

  const unary = <A, I>(
    operationName: string,
    schema: Schema.Schema<A, I>,
    operation: (request: A) => Effect.Effect<unknown, BrokerError>,
  ) => respond(operationName, Effect.flatMap(parseBody(schema), operation));

  const exec = parseBody(ExecRequest).pipe(
    Effect.tapError((error) => logFailure("exec.foreground", error)),
    Effect.match({
      onFailure: errorResponse,
      onSuccess: (request) => {
        const body = executor.execute(request).pipe(
          Stream.map((event) => encoder.encode(`${JSON.stringify(event)}\n`)),
          Stream.catchAll((error) => {
            const brokerFailure = asBrokerError(error);
            return Stream.fromEffect(logFailure("exec.foreground", brokerFailure)).pipe(
              Stream.flatMap(() =>
                Stream.succeed(encoder.encode(`${JSON.stringify(publicErrorEvent(brokerFailure))}\n`)),
              ),
            );
          }),
        );
        return HttpServerResponse.stream(body, {
          status: 200,
          contentType: "application/x-ndjson",
          headers: {
            "cache-control": "no-store",
            "x-content-type-options": "nosniff",
          },
        });
      },
    }),
  );

  return HttpRouter.empty.pipe(
    HttpRouter.get(
      "/v1/health",
      HttpServerResponse.unsafeJson({ status: "ok" }, { headers: { "cache-control": "no-store" } }),
    ),
    HttpRouter.post("/v1/environments/ensure", unary("environment.ensure", EnsureRequest, environments.ensure)),
    HttpRouter.post("/v1/environments/status", unary("environment.status", StatusRequest, ({ environmentKey }) => environments.status(environmentKey))),
    HttpRouter.post(
      "/v1/environments/close",
      unary("environment.close", EnvironmentRef, (request) => environments.close(request).pipe(Effect.as({ closed: true }))),
    ),
    HttpRouter.post("/v1/exec", exec),
    HttpRouter.post("/v1/files/stat", unary("fs.stat", FileRef, files.stat)),
    HttpRouter.post("/v1/files/list", unary("fs.list", ListFileRequest, files.list)),
    HttpRouter.post("/v1/files/read", unary("fs.read", ReadFileRequest, files.read)),
    HttpRouter.post("/v1/files/write", unary("fs.write", WriteFileRequest, files.write)),
    HttpRouter.post(
      "/v1/files/mkdir",
      unary("fs.mkdir", MakeDirectoryRequest, (request) => files.mkdir(request).pipe(Effect.as({ created: true }))),
    ),
    HttpRouter.post(
      "/v1/files/remove",
      unary("fs.remove", RemoveFileRequest, (request) => files.remove(request).pipe(Effect.as({ removed: true }))),
    ),
    HttpRouter.catchAll(() =>
      Effect.succeed(errorResponse(brokerError("request.invalid", "route does not exist"))),
    ),
  );
});
