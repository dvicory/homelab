import * as HttpServer from "@effect/platform/HttpServer"
import * as NodeHttpServer from "@effect/platform-node/NodeHttpServer"
import assert from "node:assert/strict"
import { access, mkdtemp } from "node:fs/promises"
import { createServer, request as httpRequest } from "node:http"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { BrokerDatabase } from "../dist/database.js"
import { BrokerConfig } from "../dist/config.js"
import { contentDispositionFor, makeControlHttpApp, makeHttpApp } from "../dist/http.js"
import { makeTestLayer, testTaskAuthority } from "./fakes.mjs"
test("export content-disposition is ASCII-safe and RFC5987 encoded", () => {
  const header = contentDispositionFor("résumé\"\r\n.txt")
  assert.equal(header.includes("\r"), false)
  assert.equal(header.includes("\n"), false)
  assert.match(header, /filename="r_sum____\.txt"/)
  assert.match(header, /filename\*=UTF-8''r%C3%A9sum%C3%A9%22%0D%0A\.txt$/)
})

const request = (socketPath, route, body) => new Promise((resolve, reject) => {
  const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body))
  const req = httpRequest({
    socketPath,
    path: route,
    method: payload === undefined ? "GET" : "POST",
    headers: payload === undefined ? {} : {
      "content-type": "application/json",
      "content-length": String(payload.byteLength)
    }
  }, (response) => {
    const chunks = []
    response.on("data", (chunk) => chunks.push(chunk))
    response.on("end", () => resolve({
      status: response.statusCode,
      contentType: response.headers["content-type"],
      text: Buffer.concat(chunks).toString("utf8")
    }))
  })
  req.on("error", reject)
  if (payload !== undefined) req.write(payload)
  req.end()
})

test("HTTP API serves unary and streamed operations over a Unix socket", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-http-"))
  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const config = yield* BrokerConfig
    const app = yield* makeHttpApp
    const server = yield* NodeHttpServer.make(() => createServer(), { path: config.socketPath })
    yield* HttpServer.serveEffect(app).pipe(Effect.provideService(HttpServer.HttpServer, server))
    const controlApp = yield* makeControlHttpApp
    const controlServer = yield* NodeHttpServer.make(() => createServer(), { path: config.controlSocketPath })
    yield* HttpServer.serveEffect(controlApp).pipe(
      Effect.provideService(HttpServer.HttpServer, controlServer)
    )

    const health = yield* Effect.promise(() => request(config.socketPath, "/v1/health"))
    assert.equal(health.status, 200)
    assert.deepEqual(JSON.parse(health.text), { status: "ok", plane: "execution" })

    const conversationWorkspaceResponse = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspaces/acquire", {
        environmentKey: "conversation-http"
      })
    )
    assert.equal(conversationWorkspaceResponse.status, 200)
    const conversationWorkspace = JSON.parse(conversationWorkspaceResponse.text)
    const conversationAuthority = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/authority/bind", {
        environmentKey: "conversation-http",
        authorityClass: "default",
        workspaceId: conversationWorkspace.workspace.workspaceId,
        workspaceLeaseId: conversationWorkspace.lease.leaseId
      })
    )
    assert.equal(conversationAuthority.status, 200)

    const ensure = yield* Effect.promise(() => request(config.socketPath, "/v1/environments/ensure", {
      environmentKey: "conversation-http"
    }))
    assert.equal(ensure.status, 200)
    const environment = JSON.parse(ensure.text)
    assert.equal(environment.state, "created")

    const liveStatus = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/environments/live")
    )
    assert.equal(liveStatus.status, 200)
    const liveEnvironments = JSON.parse(liveStatus.text).environments
    assert.equal(liveEnvironments.length, 1)
    assert.equal(liveEnvironments[0].environmentKey, environment.environmentKey)
    assert.equal(liveEnvironments[0].generation, environment.generation)
    assert.equal(typeof liveEnvironments[0].idleForMs, "number")

    const executionHidesLiveStatus = yield* Effect.promise(() =>
      request(config.socketPath, "/v1/control/environments/live")
    )
    assert.equal(executionHidesLiveStatus.status, 404)

    const exec = yield* Effect.promise(() => request(config.socketPath, "/v1/exec", {
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["printf", "hello"]
    }))
    assert.equal(exec.status, 200)
    assert.equal(exec.contentType, "application/x-ndjson")
    const events = exec.text.trim().split("\n").map(JSON.parse)
    assert.deepEqual(events.map((event) => event.type), ["start", "output", "exit"])
    assert.equal(Buffer.from(events[1].dataBase64, "base64").toString(), "printf hello")

    const executionRejectsControl = yield* Effect.promise(() =>
      request(config.socketPath, "/v1/control/authority/status", {
        environmentKey: "conversation-http"
      })
    )
    assert.equal(executionRejectsControl.status, 404)

    const controlRejectsExecution = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/environments/ensure", {
        environmentKey: "conversation-control"
      })
    )
    assert.equal(controlRejectsExecution.status, 404)

    const executionRejectsBranchPreparation = yield* Effect.promise(() =>
      request(config.socketPath, "/v1/control/workspace-branches/prepare", {
        operationId: "c303d62f-f6df-428f-8f27-206b9e17f5c8",
        sourceEnvironmentKey: "branch-source-http",
        destinationEnvironmentKey: "branch-destination-http",
      })
    )
    assert.equal(executionRejectsBranchPreparation.status, 404)
    const branchSourceWorkspaceResponse = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspaces/acquire", {
        environmentKey: "branch-source-http"
      })
    )
    const branchSourceWorkspace = JSON.parse(branchSourceWorkspaceResponse.text)
    const branchSourceAuthority = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/authority/bind", {
        environmentKey: "branch-source-http",
        authorityClass: "default",
        workspaceId: branchSourceWorkspace.workspace.workspaceId,
        workspaceLeaseId: branchSourceWorkspace.lease.leaseId
      })
    )
    assert.equal(branchSourceAuthority.status, 200)


    const preparedBranch = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspace-branches/prepare", {
        operationId: "c303d62f-f6df-428f-8f27-206b9e17f5c8",
        sourceEnvironmentKey: "branch-source-http",
        destinationEnvironmentKey: "branch-destination-http",
      })
    )
    assert.equal(preparedBranch.status, 200)
    const branch = JSON.parse(preparedBranch.text)
    assert.notEqual(branch.sourceWorkspaceId, branch.destinationWorkspaceId)

    const acquiredResponse = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspaces/acquire", {
        environmentKey: "conversation-control"
      })
    )
    assert.equal(acquiredResponse.status, 200)
    const acquired = JSON.parse(acquiredResponse.text)
    assert.equal(acquired.workspace.guestPath, "/workspace")
    assert.equal("workspacePath" in acquired.workspace, false)


    const described = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspaces/describe", {
        environmentKey: "conversation-control",
        workspaceId: acquired.workspace.workspaceId
      })
    )
    assert.equal(described.status, 200)
    assert.equal(JSON.parse(described.text).workspaceId, acquired.workspace.workspaceId)
    const workspaceList = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspaces/list", {
        environmentKey: "conversation-control"
      })
    )
    assert.deepEqual(JSON.parse(workspaceList.text).map((item) => item.workspaceId), [acquired.workspace.workspaceId])

    const activated = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/task-runs/activate", {
        environmentKey: "conversation-control",
        taskId: "task-http",
        runId: "run-http",
        ...testTaskAuthority(),
        workspaceId: acquired.workspace.workspaceId,
        workspaceLeaseId: acquired.lease.leaseId,
      })
    )
    assert.equal(activated.status, 200)
    assert.equal(JSON.parse(activated.text).activation.state, "active")

    const controlledEnsure = yield* Effect.promise(() =>
      request(config.socketPath, "/v1/environments/ensure", {
        environmentKey: "conversation-control",
        taskRun: { taskId: "task-http", runId: "run-http" }
      })
    )
    assert.equal(controlledEnsure.status, 200)

    const authority = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/authority/status", {
        environmentKey: "conversation-control"
      })
    )
    assert.equal(authority.status, 200)
    assert.equal(JSON.parse(authority.text).executor, "hermes-gateway")
    assert.equal(JSON.parse(authority.text).policyDigest, "a".repeat(64))
    assert.equal(JSON.parse(authority.text).generation, 1)
    assert.equal(JSON.parse(authority.text).state, "active")

    const prepared = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/access/prepare", {
        environmentKey: "conversation-control",
        capabilities: [{
          version: 1,
          kind: "network-origin",
          scheme: "https",
          host: "8.8.8.8",
          addressMode: "public"
        }],
        requestedScope: "task"
      })
    )
    assert.equal(prepared.status, 200)
    const accessRequest = JSON.parse(prepared.text)
    assert.equal(accessRequest.state, "pending")

    const decided = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/access/decide", {
        requestId: accessRequest.requestId,
        decision: "approve",
        principal: "operator"
      })
    )
    assert.equal(decided.status, 200)
    const grantId = JSON.parse(decided.text).grantIds[0]

    const listed = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/grants/list", {
        environmentKey: "conversation-control"
      })
    )
    assert.equal(listed.status, 200)
    assert.equal(JSON.parse(listed.text)[0].grantId, grantId)

    const revoked = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/grants/revoke", {
        grantId,
        principal: "operator"
      })
    )
    assert.equal(revoked.status, 200)
    assert.equal(JSON.parse(revoked.text).state, "revoked")

    const consumedRun = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/task-runs/consume", {
        environmentKey: "conversation-control",
        taskId: "task-http",
        runId: "run-http"
      })
    )
    assert.equal(consumedRun.status, 200)
    assert.equal(JSON.parse(consumedRun.text).activation.state, "consumed")
    const released = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspaces/release", {
        environmentKey: "conversation-control",
        workspaceId: acquired.workspace.workspaceId,
        leaseId: acquired.lease.leaseId
      })
    )
    assert.equal(released.status, 200)
    assert.equal(JSON.parse(released.text).lease.state, "released")
    const closedWorkspace = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspaces/close", {
        environmentKey: "conversation-control",
        workspaceId: acquired.workspace.workspaceId
      })
    )
    assert.equal(closedWorkspace.status, 200)
    assert.equal(JSON.parse(closedWorkspace.text).state, "closed")
    const deletedWorkspace = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspaces/delete", {
        environmentKey: "conversation-control",
        workspaceId: acquired.workspace.workspaceId
      })
    )
    assert.equal(deletedWorkspace.status, 200)
    assert.deepEqual(JSON.parse(deletedWorkspace.text), { deleted: true })

    const recognizedControlHandoffRoute = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspace-handoffs/capture", {})
    )
    assert.equal(recognizedControlHandoffRoute.status, 400)
    assert.equal(
      JSON.parse(recognizedControlHandoffRoute.text).detail,
      "request body does not match the endpoint schema"
    )
    const hiddenHandoffRoute = yield* Effect.promise(() =>
      request(config.socketPath, "/v1/control/workspace-handoffs/capture", {})
    )
    assert.equal(hiddenHandoffRoute.status, 404)
    const invalid = yield* Effect.promise(() => request(config.socketPath, "/v1/environments/ensure", {
      environmentKey: "conversation-http",
      unexpected: true
    }))
    assert.equal(invalid.status, 400)
    assert.equal(invalid.contentType, "application/problem+json")
    const problem = JSON.parse(invalid.text)
    assert.equal(problem.type, "urn:agent-x:gondolin-broker:error:request.invalid")
    assert.equal(problem.status, 400)
    assert.equal(problem.reason, "request.invalid")
  }).pipe(Effect.provide(harness.layer))))
})

test("disabled handoff exposes no routes, tables, or handoff root", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-disabled-handoff-"))
  const harness = makeTestLayer(stateDir)
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const config = yield* BrokerConfig
    const database = yield* BrokerDatabase
    const controlApp = yield* makeControlHttpApp
    const server = yield* NodeHttpServer.make(() => createServer(), { path: config.controlSocketPath })
    yield* HttpServer.serveEffect(controlApp).pipe(Effect.provideService(HttpServer.HttpServer, server))

    const activate = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/task-runs/activate", {})
    )
    const capture = yield* Effect.promise(() =>
      request(config.controlSocketPath, "/v1/control/workspace-handoffs/capture", {})
    )
    assert.equal(activate.status, 404)
    assert.equal(capture.status, 404)
    const handoffTables = database.connection.prepare(`
      SELECT count(*) AS count FROM sqlite_schema
      WHERE type='table' AND (
        name='task_run_activations' OR name LIKE 'workspace_handoff%'
      )
    `).get().count
    assert.equal(handoffTables, 0)
    yield* Effect.promise(() => assert.rejects(access(config.workspaceHandoffRoot)))
  }).pipe(Effect.provide(harness.layer))))
})
