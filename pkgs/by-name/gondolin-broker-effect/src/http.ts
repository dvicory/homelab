import * as HttpRouter from "@effect/platform/HttpRouter";
import * as HttpServerRequest from "@effect/platform/HttpServerRequest";
import * as HttpServerResponse from "@effect/platform/HttpServerResponse";
import { Effect, Schema, Stream } from "effect";
import {
  BindAuthorityRequest,
  DecideAccessRequest,
  EnvironmentRef,
  EnsureRequest,
  ExecRequest,
  FileRef,
  ListFileRequest,
  MakeDirectoryRequest,
  ListGrantsRequest,
  ReadFileRequest,
  RemoveFileRequest,
  PrepareAccessRequest,
  RevokeGrantRequest,
  RevokeEnvironmentGrantsRequest,
  StatusRequest,
  WorkspaceAcquireRequest,
  WorkspaceLeaseRef,
  WorkspaceRef,
  WriteFileRequest,
} from "./domain.js";
import { BrokerConfig } from "./config.js";
import { Environments } from "./environments.js";
import { asBrokerError, brokerError, publicErrorEvent, publicProblem, statusFor, type BrokerError } from "./errors.js";
import { Executor } from "./exec.js";
import { Files } from "./files.js";
import { AccessGrants } from "./grants.js";
import { Registry } from "./registry.js";
import { Workspaces, type WorkspaceRecord } from "./workspaces.js";

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
      HttpServerResponse.unsafeJson({ status: "ok", plane: "execution" }, { headers: { "cache-control": "no-store" } }),
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

export const makeControlHttpApp = Effect.gen(function* () {
  const config = yield* BrokerConfig;
  const registry = yield* Registry;
  const grants = yield* AccessGrants;
  const workspaces = yield* Workspaces;

  const bindAuthority = (request: typeof BindAuthorityRequest.Type) =>
    Effect.gen(function* () {
      if (request.profile !== config.profile) {
        return yield* brokerError("authority.conflict", "authority profile does not match this broker", {
          expectedProfile: config.profile,
          requestedProfile: request.profile,
        });
      }
      if (request.policyDigest !== config.policyFile.policyDigest) {
        return yield* brokerError("authority.conflict", "authority policy digest is not active", {
          activePolicyDigest: config.policyFile.policyDigest,
          requestedPolicyDigest: request.policyDigest,
        });
      }
      if (!(request.authorityClass in config.policyFile.worklanes)) {
        return yield* brokerError("request.invalid", "authority class is not installed", {
          authorityClass: request.authorityClass,
        });
      }
      yield* workspaces.resolve(request.environmentKey, request.workspaceId, request.workspaceLeaseId);
      return yield* registry.bindAuthority(request);
    });

  const authorityStatus = ({ environmentKey }: typeof StatusRequest.Type) =>
    Effect.gen(function* () {
      const binding = yield* registry.getAuthority(environmentKey);
      if (binding === undefined) {
        return yield* brokerError("environment.not_found", "authority binding does not exist", {
          environmentKey,
        });
      }
      const environment = yield* registry.get(environmentKey);
      if (environment === undefined) return binding;
      const visibleEnvironment = {
        generation: environment.generation,
        state: environment.state,
        worklane: environment.worklane,
        assetBuildId: environment.assetBuildId,
      };
      return { ...binding, ...visibleEnvironment };
    });

  const publicWorkspace = (workspace: WorkspaceRecord): Record<string, unknown> => ({
    workspaceId: workspace.workspaceId,
    ownerEnvironmentKey: workspace.ownerEnvironmentKey,
    kind: workspace.kind,
    state: workspace.state,
    guestPath: "/workspace",
    retentionExpiresAt: workspace.retentionExpiresAt,
    lastAttachedAt: workspace.lastAttachedAt,
    createdAt: workspace.createdAt,
  });

  const acquireWorkspace = (request: typeof WorkspaceAcquireRequest.Type) =>
    workspaces.acquire(request.environmentKey, request.workspaceId).pipe(
      Effect.map(({ workspace, lease }) => ({ workspace: publicWorkspace(workspace), lease })),
    );
  const describeWorkspace = (request: typeof WorkspaceRef.Type) =>
    workspaces.describe(request.environmentKey, request.workspaceId).pipe(Effect.map(publicWorkspace));
  const listWorkspaces = ({ environmentKey }: typeof StatusRequest.Type) =>
    workspaces.list(environmentKey).pipe(Effect.map((items) => items.map(publicWorkspace)));
  const releaseWorkspace = (request: typeof WorkspaceLeaseRef.Type) =>
    workspaces.release(request.environmentKey, request.workspaceId, request.leaseId).pipe(
      Effect.map((lease) => ({ lease })),
    );
  const closeWorkspace = (request: typeof WorkspaceRef.Type) =>
    workspaces.close(request.environmentKey, request.workspaceId).pipe(Effect.map(publicWorkspace));
  const deleteWorkspace = (request: typeof WorkspaceRef.Type) =>
    workspaces.delete(request.environmentKey, request.workspaceId).pipe(Effect.as({ deleted: true }));

  const unary = <A, I>(
    operationName: string,
    schema: Schema.Schema<A, I>,
    operation: (request: A) => Effect.Effect<unknown, BrokerError>,
  ) => respond(operationName, Effect.flatMap(parseBody(schema), operation));

  return HttpRouter.empty.pipe(
    HttpRouter.get(
      "/v1/health",
      HttpServerResponse.unsafeJson(
        { status: "ok", plane: "control" },
        { headers: { "cache-control": "no-store" } },
      ),
    ),
    HttpRouter.post(
      "/v1/control/workspaces/acquire",
      unary("workspace.acquire", WorkspaceAcquireRequest, acquireWorkspace),
    ),
    HttpRouter.post(
      "/v1/control/workspaces/describe",
      unary("workspace.describe", WorkspaceRef, describeWorkspace),
    ),
    HttpRouter.post(
      "/v1/control/workspaces/list",
      unary("workspace.list", StatusRequest, listWorkspaces),
    ),
    HttpRouter.post(
      "/v1/control/workspaces/release",
      unary("workspace.release", WorkspaceLeaseRef, releaseWorkspace),
    ),
    HttpRouter.post(
      "/v1/control/workspaces/close",
      unary("workspace.close", WorkspaceRef, closeWorkspace),
    ),
    HttpRouter.post(
      "/v1/control/workspaces/delete",
      unary("workspace.delete", WorkspaceRef, deleteWorkspace),
    ),
    HttpRouter.post(
      "/v1/control/authority/bind",
      unary("authority.bind", BindAuthorityRequest, bindAuthority),
    ),
    HttpRouter.post(
      "/v1/control/authority/status",
      unary("authority.status", StatusRequest, authorityStatus),
    ),
    HttpRouter.post(
      "/v1/control/access/prepare",
      unary("access.prepare", PrepareAccessRequest, grants.prepare),
    ),
    HttpRouter.post(
      "/v1/control/access/decide",
      unary("access.decide", DecideAccessRequest, grants.decide),
    ),
    HttpRouter.post(
      "/v1/control/grants/list",
      unary("grants.list", ListGrantsRequest, ({ environmentKey }) => grants.list(environmentKey)),
    ),
    HttpRouter.post(
      "/v1/control/grants/revoke",
      unary("grants.revoke", RevokeGrantRequest, ({ grantId, principal }) => grants.revoke(grantId, principal)),
    ),
    HttpRouter.post(
      "/v1/control/grants/revoke-environment",
      unary(
        "grants.revoke-environment",
        RevokeEnvironmentGrantsRequest,
        ({ environmentKey, scopes, principal }) =>
          grants.revokeEnvironment(environmentKey, scopes, principal).pipe(
            Effect.map((revoked) => ({ revoked })),
          ),
      ),
    ),
    HttpRouter.catchAll(() =>
      Effect.succeed(errorResponse(brokerError("request.invalid", "control route does not exist"))),
    ),
  );
});
