import * as HttpServer from "@effect/platform/HttpServer"
import * as NodeHttpServer from "@effect/platform-node/NodeHttpServer"
import assert from "node:assert/strict"
import { mkdtemp } from "node:fs/promises"
import { createServer, request as httpRequest } from "node:http"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { BrokerConfig } from "../dist/config.js"
import { makeHttpApp } from "../dist/http.js"
import { makeTestLayer } from "./fakes.mjs"

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
  const harness = makeTestLayer(stateDir)
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const config = yield* BrokerConfig
    const app = yield* makeHttpApp
    const server = yield* NodeHttpServer.make(() => createServer(), { path: config.socketPath })
    yield* HttpServer.serveEffect(app).pipe(Effect.provideService(HttpServer.HttpServer, server))

    const health = yield* Effect.promise(() => request(config.socketPath, "/v1/health"))
    assert.equal(health.status, 200)
    assert.deepEqual(JSON.parse(health.text), { status: "ok" })

    const ensure = yield* Effect.promise(() => request(config.socketPath, "/v1/environments/ensure", {
      environmentKey: "conversation-http"
    }))
    assert.equal(ensure.status, 200)
    const environment = JSON.parse(ensure.text)
    assert.equal(environment.state, "created")

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
