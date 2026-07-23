import assert from "node:assert/strict"
import { access, mkdtemp } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { Workspaces } from "../dist/workspaces.js"
import { makeTestLayer } from "./fakes.mjs"

const withHarness = async (run) => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-workspace-test-"))
  const harness = makeTestLayer(stateDir)
  return Effect.runPromise(Effect.scoped(run(stateDir).pipe(Effect.provide(harness.layer))))
}

test("acquire reuses one opaque private workspace and active writer lease", async () => {
  await withHarness((stateDir) => Effect.gen(function* () {
    const workspaces = yield* Workspaces
    const first = yield* workspaces.acquire("conversation-a")
    const repeated = yield* workspaces.acquire("conversation-a")
    const resolved = yield* workspaces.resolve("conversation-a", first.workspace.workspaceId, first.lease.leaseId)

    assert.match(first.workspace.workspaceId, /^[0-9a-f-]{36}$/)
    assert.equal(resolved.workspacePath, path.join(stateDir, "workspaces", "data", first.workspace.workspaceId))
    assert.equal(first.workspace.state, "active")
    assert.equal(first.lease.state, "active")
    assert.equal(repeated.workspace.workspaceId, first.workspace.workspaceId)
    assert.equal(repeated.lease.leaseId, first.lease.leaseId)
    assert.deepEqual((yield* workspaces.list("conversation-a")).map((item) => item.workspaceId), [first.workspace.workspaceId])
    yield* Effect.promise(() => access(resolved.workspacePath))
  }))
})

test("workspace ownership, lease fencing, close, and explicit deletion fail closed", async () => {
  await withHarness(() => Effect.gen(function* () {
    const workspaces = yield* Workspaces
    const first = yield* workspaces.acquire("conversation-owner")
    const resolved = yield* workspaces.resolve("conversation-owner", first.workspace.workspaceId, first.lease.leaseId)

    const foreign = yield* Effect.flip(workspaces.acquire("conversation-other", first.workspace.workspaceId))
    assert.equal(foreign.reason, "workspace.conflict")

    const closeWhileLeased = yield* Effect.flip(workspaces.close("conversation-owner", first.workspace.workspaceId))
    assert.equal(closeWhileLeased.reason, "workspace.conflict")

    yield* workspaces.release("conversation-owner", first.workspace.workspaceId, first.lease.leaseId)
    const stale = yield* Effect.flip(workspaces.resolve("conversation-owner", first.workspace.workspaceId, first.lease.leaseId))
    assert.equal(stale.reason, "workspace.stale_lease")

    const reacquired = yield* workspaces.acquire("conversation-owner", first.workspace.workspaceId)
    assert.notEqual(reacquired.lease.leaseId, first.lease.leaseId)
    yield* workspaces.release("conversation-owner", reacquired.workspace.workspaceId, reacquired.lease.leaseId)
    const closed = yield* workspaces.close("conversation-owner", first.workspace.workspaceId)
    assert.equal(closed.state, "closed")
    assert.equal(closed.retentionExpiresAt, null)

    yield* workspaces.delete("conversation-owner", first.workspace.workspaceId)
    const missing = yield* Effect.flip(workspaces.describe("conversation-owner", first.workspace.workspaceId))
    assert.equal(missing.reason, "workspace.not_found")
    yield* Effect.promise(() => assert.rejects(access(resolved.workspacePath)))
  }))
})
