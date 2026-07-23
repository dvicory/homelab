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

const foreign = `${environmentKey}-foreign`
const denied = await jsonPost(controlSocket, "/v1/control/workspaces/acquire", {
  environmentKey: foreign,
  workspaceId: acquired.workspace.workspaceId
}, 409)
assert.equal(denied.reason, "workspace.conflict")

await jsonPost(executionSocket, "/v1/environments/close", {
  environmentKey,
  generation: recreated.generation
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
  workspaceId: acquired.workspace.workspaceId,
  generations: [first.generation, recreated.generation],
  isolation: "foreign-owner-denied",
  deletion: "confirmed"
}))
