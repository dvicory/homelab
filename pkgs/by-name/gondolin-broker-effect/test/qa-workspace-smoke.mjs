#!/usr/bin/env node
import assert from "node:assert/strict"
import { request as httpRequest } from "node:http"

const executionSocket = process.env.GONDOLIN_EFFECT_SOCKET ?? "/run/hermes-qa-broker/broker.sock"
const controlSocket = process.env.GONDOLIN_EFFECT_CONTROL_SOCKET ?? "/run/hermes-qa-broker/control.sock"
const environmentKey = `workspace-smoke-${Date.now()}-${process.pid}`

const post = (socketPath, route, body, expected = 200) => new Promise((resolve, reject) => {
  const payload = Buffer.from(JSON.stringify(body))
  const request = httpRequest({
    socketPath,
    path: route,
    method: "POST",
    headers: {
      "content-type": "application/json",
      "content-length": String(payload.byteLength)
    }
  }, (response) => {
    const chunks = []
    response.on("data", (chunk) => chunks.push(chunk))
    response.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8")
      if (response.statusCode !== expected) {
        reject(new Error(`${route}: expected ${expected}, received ${response.statusCode}: ${text}`))
        return
      }
      resolve({ text, contentType: response.headers["content-type"] })
    })
  })
  request.on("error", reject)
  request.end(payload)
})

const jsonPost = async (socketPath, route, body, expected = 200) => {
  const response = await post(socketPath, route, body, expected)
  return response.text ? JSON.parse(response.text) : {}
}

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

const awaitProcess = async (environmentKey, generation, processId) => {
  let cursor = 0
  let output = ""
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const result = await jsonPost(executionSocket, "/v1/processes/poll", {
      environmentKey,
      generation,
      processId,
      cursor
    })
    output += result.output
      .map((event) => Buffer.from(event.dataBase64, "base64").toString("utf8"))
      .join("")
    cursor = result.nextCursor
    if (result.state !== "running") return { ...result, outputText: output }
    await sleep(100)
  }
  throw new Error(`process ${processId} did not reach a terminal state`)
}

const acquired = await jsonPost(controlSocket, "/v1/control/workspaces/acquire", {
  environmentKey
})
assert.equal(acquired.workspace.guestPath, "/workspace")
assert.equal("workspacePath" in acquired.workspace, false)

const first = await jsonPost(executionSocket, "/v1/environments/ensure", { environmentKey })
await jsonPost(executionSocket, "/v1/files/write", {
  environmentKey,
  generation: first.generation,
  path: "/workspace/sentinel.txt",
  dataBase64: Buffer.from("persistent\n").toString("base64"),
  create: true,
  truncate: true
})

const execution = await post(executionSocket, "/v1/exec", {
  environmentKey,
  generation: first.generation,
  argv: ["sh", "-lc", "printf vm-ok >> /workspace/sentinel.txt"]
})
const events = execution.text.trim().split("\n").map(JSON.parse)
assert.equal(events.at(-1)?.type, "exit")
assert.equal(events.at(-1)?.exitCode, 0)

await jsonPost(executionSocket, "/v1/environments/close", {
  environmentKey,
  generation: first.generation
})
const recreated = await jsonPost(executionSocket, "/v1/environments/ensure", { environmentKey })
assert.ok(recreated.generation > first.generation)
const persisted = await jsonPost(executionSocket, "/v1/files/read", {
  environmentKey,
  generation: recreated.generation,
  path: "/workspace/sentinel.txt"
})
assert.equal(Buffer.from(persisted.dataBase64, "base64").toString("utf8"), "persistent\nvm-ok")

const spawnStartedAt = Date.now()
const spawned = await jsonPost(executionSocket, "/v1/processes/spawn", {
  environmentKey,
  generation: recreated.generation,
  argv: ["sh", "-lc", "sleep 2; printf background-ok; exit 7"]
})
assert.equal(spawned.state, "running")
assert.ok(Date.now() - spawnStartedAt < 1500, "background spawn waited for command exit")
const completed = await awaitProcess(
  environmentKey,
  recreated.generation,
  spawned.processId
)
assert.equal(completed.state, "exited")
assert.equal(completed.exitCode, 7)
assert.equal(completed.signal, null)
assert.equal(completed.outputText, "background-ok")

const cancellable = await jsonPost(executionSocket, "/v1/processes/spawn", {
  environmentKey,
  generation: recreated.generation,
  argv: ["sh", "-lc", "sleep 30"]
})
const cancelled = await jsonPost(executionSocket, "/v1/processes/cancel", {
  environmentKey,
  generation: recreated.generation,
  processId: cancellable.processId
})
assert.equal(cancelled.state, "cancelled")
assert.equal(cancelled.exitCode, null)
const afterCancel = await jsonPost(executionSocket, "/v1/environments/ensure", {
  environmentKey
})
assert.ok(afterCancel.generation > recreated.generation)

const foreign = `${environmentKey}-foreign`
const denied = await jsonPost(controlSocket, "/v1/control/workspaces/acquire", {
  environmentKey: foreign,
  workspaceId: acquired.workspace.workspaceId
}, 409)
assert.equal(denied.reason, "workspace.conflict")

await jsonPost(executionSocket, "/v1/environments/close", {
  environmentKey,
  generation: afterCancel.generation
})
await jsonPost(controlSocket, "/v1/control/workspaces/release", {
  environmentKey,
  workspaceId: acquired.workspace.workspaceId,
  leaseId: acquired.lease.leaseId
})
await jsonPost(controlSocket, "/v1/control/workspaces/close", {
  environmentKey,
  workspaceId: acquired.workspace.workspaceId
})
await jsonPost(controlSocket, "/v1/control/workspaces/delete", {
  environmentKey,
  workspaceId: acquired.workspace.workspaceId
})
const missing = await jsonPost(controlSocket, "/v1/control/workspaces/describe", {
  environmentKey,
  workspaceId: acquired.workspace.workspaceId
}, 404)
assert.equal(missing.reason, "workspace.not_found")

console.log(JSON.stringify({
  status: "ok",
  environmentKey,
  generations: [first.generation, recreated.generation, afterCancel.generation],
  processLifecycle: "background-exit-7-and-cancelled",
  isolation: "foreign-owner-denied",
  deletion: "confirmed"
}))
