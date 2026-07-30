import * as HttpRouter from "@effect/platform/HttpRouter";
import * as HttpServerRequest from "@effect/platform/HttpServerRequest";
import * as HttpServerResponse from "@effect/platform/HttpServerResponse";
import { Effect, Schema, Stream } from "effect";
import {
  ActivateTaskRunRequest,
  BindAuthorityRequest,
  DecideAccessRequest,
  ConsumeTaskRunRequest,
  EnvironmentRef,
  EnsureRequest,
  ExecRequest,
  FileRef,
  ListFileRequest,
  MakeDirectoryRequest,
  ListGrantsRequest,
  MarkWorkspaceHandoffsReclaimableRequest,
  ReadFileRequest,
  ReleaseTaskRunInputsRequest,
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
import {
  CaptureWorkspaceHandoffRequest,
  ReadWorkspaceArtifactRequest,
} from "./workspace-handoff/model.js";
import { PrepareTaskRunInputsRequest } from "./task-run-inputs/model.js";
import { InputPreparations } from "./task-run-inputs/service.js";
import { TaskRunActivations } from "./task-run-activations.js";
import { ProjectWorkspaces } from "./project-workspace/service.js";
import {
  ReadProjectResultRequest,
  ResolveProjectSourceRequest,
} from "./project-workspace/model.js";
import { Authorization } from "./auth.js";
import { BrokerConfig } from "./config.js";
import { Environments } from "./environments.js";
import { asBrokerError, brokerError, publicErrorEvent, publicProblem, statusFor, type BrokerError } from "./errors.js";
import { Executor } from "./exec.js";
import { Files } from "./files.js";
import { AccessGrants } from "./grants.js";
import { Registry } from "./registry.js";
import { HandoffOperations } from "./workspace-handoff/service.js";
import { Workspaces, type WorkspaceRecord } from "./workspaces.js";
import {
  PrepareWorkspaceBranchRequest,
  WorkspaceBranches,
} from "./workspace-branches.js";

const encoder = new TextEncoder();
const requestDecodeOptions = { onExcessProperty: "error" as const };
const encodeFilenameParameter = (fileName: string): string =>
  encodeURIComponent(fileName).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );

export const contentDispositionFor = (fileName: string): string => {
  const asciiFallback =
    fileName.replace(/[^\x20-\x7e]/g, "_").replace(/[/"\\]/g, "_") || "download";
  return `attachment; filename="${asciiFallback}"; filename*=UTF-8''${encodeFilenameParameter(fileName)}`;
};

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
  const runActivations = yield* TaskRunActivations;
  const inputPreparations = yield* InputPreparations;
  const environments = yield* Environments;
  const handoffOperations = yield* HandoffOperations;
  const workspaceBranches = yield* WorkspaceBranches;
  const projectWorkspaces = yield* ProjectWorkspaces;
  const authorization = yield* Authorization;



  const bindAuthority = (request: typeof BindAuthorityRequest.Type) =>
    Effect.gen(function* () {
      yield* workspaces.resolve(
        request.environmentKey,
        request.workspaceId,
        request.workspaceLeaseId,
      );
      if (!(request.authorityClass in config.policyFile.worklanes)) {
        return yield* brokerError("authority.conflict", "authority class is not configured", {
          authorityClass: request.authorityClass,
        });
      }
      const binding = {
        ...request,
        profile: config.profile,
        executor: config.policyFile.defaultExecutor,
        policyDigest: config.policyFile.policyDigest,
      };
      const existing = yield* registry.getAuthority(request.environmentKey);
      return yield* (
        existing !== undefined && existing.policyDigest !== binding.policyDigest
          ? registry.rotateAuthorityPolicy(binding)
          : registry.bindAuthority(binding)
      );
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
  const activateTaskRun = (request: typeof ActivateTaskRunRequest.Type) =>
    Effect.gen(function* () {
      const workspace = yield* workspaces.resolve(
        request.environmentKey,
        request.workspaceId,
        request.workspaceLeaseId,
      );
      yield* inputPreparations.materialize(request, workspace.workspacePath);
      // Project materialization is staged, journaled, and committed to the
      // task workspace before activation publishes the sandbox authority.
      if (request.workspaceProvider === "broker-project") {
        const binding = yield* workspaces.resolve(
          request.environmentKey,
          request.workspaceId,
          request.workspaceLeaseId,
        );
        yield* projectWorkspaces.ensureMaterialized(
          request,
          binding.workspacePath,
          binding.lease.fencingToken,
        );
      }
      return yield* runActivations.activate(request).pipe(
        Effect.tap(({ generationsToClose }) =>
          Effect.forEach(generationsToClose, environments.closeForFence, {
            concurrency: 1,
            discard: true,
          }),
        ),
        Effect.map(({ activation }) => ({ activation })),
      );
    });
  const consumeTaskRun = (request: typeof ConsumeTaskRunRequest.Type) =>
    runActivations.consume(request).pipe(
      Effect.tap(({ generationToClose }) =>
        generationToClose === null ? Effect.void : environments.closeForFence(generationToClose),
      ),
      Effect.map(({ activation }) => ({ activation })),
    );
  const readProjectResult = (request: typeof ReadProjectResultRequest.Type) =>
    Effect.gen(function* () {
      yield* authorization.authorize({
        action: "project.result.read",
        resource: `task-run:${request.taskId}/${request.runId}`,
      });
      return yield* projectWorkspaces.readResult(request.taskId, request.runId);
    });
  const resolveProjectSource = (request: typeof ResolveProjectSourceRequest.Type) =>
    Effect.gen(function* () {
      yield* authorization.authorize({
        action: "project.source.resolve",
        resource: `project-source:${request.repositoryId}`,
      });
      return yield* projectWorkspaces.resolveSource(request);
    });
  const unary = <A, I>(
    operationName: string,
    schema: Schema.Schema<A, I>,
    operation: (request: A) => Effect.Effect<unknown, BrokerError>,
  ) => respond(operationName, Effect.flatMap(parseBody(schema), operation));

  const readArtifact = parseBody(ReadWorkspaceArtifactRequest).pipe(
    Effect.flatMap(handoffOperations.readArtifact),
    Effect.match({
      onFailure: errorResponse,
      onSuccess: (artifact) => HttpServerResponse.stream(
        Stream.fromAsyncIterable(artifact.body, (error) => asBrokerError(error)),
        {
          status: 200,
          contentType: "application/octet-stream",
          headers: {
            "cache-control": "no-store",
            "content-length": String(artifact.byteSize),
            "content-disposition": contentDispositionFor(artifact.fileName),
            "x-content-type-options": "nosniff",
          },
        },
      ),
    }),
  );

  const routes = HttpRouter.empty.pipe(
    HttpRouter.get(
      "/v1/health",
      HttpServerResponse.unsafeJson(
        { status: "ok", plane: "control" },
        { headers: { "cache-control": "no-store" } },
      ),
    ),
    HttpRouter.get(
      "/v1/control/environments/live",
      environments.listLive.pipe(
        Effect.map((items) =>
          HttpServerResponse.unsafeJson(
            { environments: items },
            { headers: { "cache-control": "no-store" } },
          ),
        ),
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
      "/v1/control/workspace-branches/prepare",
      unary(
        "workspace.branch.prepare",
        PrepareWorkspaceBranchRequest,
        workspaceBranches.prepare,
      ),
    ),
    HttpRouter.post(
      "/v1/control/project-sources/resolve",
      unary("project.source.resolve", ResolveProjectSourceRequest, resolveProjectSource),
    ),
    HttpRouter.post(
      "/v1/control/project-workspaces/results/read",
      unary("project.result.read", ReadProjectResultRequest, readProjectResult),
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
  );

  const configuredRoutes = config.workspaceHandoffEnabled
    ? routes.pipe(
        HttpRouter.post(
          "/v1/control/task-runs/activate",
          unary("run_activation.activate", ActivateTaskRunRequest, activateTaskRun),
        ),
        HttpRouter.post(
          "/v1/control/task-runs/consume",
          unary("run_activation.consume", ConsumeTaskRunRequest, consumeTaskRun),
        ),
        HttpRouter.post(
          "/v1/control/task-run-inputs/prepare",
          unary("task_run_inputs.prepare", PrepareTaskRunInputsRequest, inputPreparations.prepare),
        ),
        HttpRouter.post(
          "/v1/control/task-run-inputs/release",
          unary(
            "task_run_inputs.release",
            ReleaseTaskRunInputsRequest,
            ({ environmentKey, taskId }) => inputPreparations.releaseTask(environmentKey, taskId),
          ),
        ),
        HttpRouter.post(
          "/v1/control/workspace-handoffs/mark-reclaimable",
          unary(
            "workspace_handoffs.mark_reclaimable",
            MarkWorkspaceHandoffsReclaimableRequest,
            ({ handoffIds }) => inputPreparations.markReclaimable(handoffIds),
          ),
        ),
        HttpRouter.post(
          "/v1/control/workspace-handoffs/capture",
          unary("workspace.capture", CaptureWorkspaceHandoffRequest, handoffOperations.capture),
        ),
        HttpRouter.post(
          "/v1/control/workspace-handoffs/artifacts/read",
          readArtifact,
        ),
      )
    : routes;
  return configuredRoutes.pipe(
    HttpRouter.catchAll(() =>
      Effect.succeed(errorResponse(brokerError("request.invalid", "control route does not exist"))),
    ),
  );
});
