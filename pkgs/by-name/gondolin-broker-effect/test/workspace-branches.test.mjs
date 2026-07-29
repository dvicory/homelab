import assert from "node:assert/strict"
import {
  chmod,
  lstat,
  mkdtemp,
  readFile,
  readdir,
  readlink,
  symlink,
  writeFile,
} from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Deferred, Effect, Fiber } from "effect"
import { Environments } from "../dist/environments.js"
import { Registry } from "../dist/registry.js"
import { WorkspaceBranches } from "../dist/workspace-branches.js"
import { Workspaces } from "../dist/workspaces.js"
import { bindTestAuthority, makeTestLayer } from "./fakes.mjs"

const operationId = "8f66f7f4-7a14-4eb9-92ea-e7f1f516f821"

const withHarness = async (run) => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-branch-test-"))
  const harness = makeTestLayer(stateDir)
  return Effect.runPromise(Effect.scoped(run(harness).pipe(Effect.provide(harness.layer))))
}

test("branch creates a private byte copy, stops the source VM, and replays idempotently", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const workspaces = yield* Workspaces
    const registry = yield* Registry
    const environments = yield* Environments
    const branches = yield* WorkspaceBranches
    const source = yield* bindTestAuthority("source-key")
    const sourceWorkspace = yield* workspaces.resolve(
      "source-key",
      source.workspaceId,
      source.workspaceLeaseId,
    )
    yield* Effect.promise(async () => {
      const script = path.join(sourceWorkspace.workspacePath, "script.sh")
      await writeFile(script, "#!/bin/sh\n")
      await chmod(script, 0o755)
      await symlink("project.txt", path.join(sourceWorkspace.workspacePath, "project-link"))
    })
    yield* Effect.promise(() => writeFile(path.join(sourceWorkspace.workspacePath, "project.txt"), "parent"))
    yield* environments.ensure({ environmentKey: "source-key" })

    const request = {
      operationId,
      sourceEnvironmentKey: "source-key",
      destinationEnvironmentKey: "branch-key",
    }
    const prepared = yield* branches.prepare(request)
    assert.equal(harness.fake.state.closed.length, 1)
    assert.notEqual(prepared.sourceWorkspaceId, prepared.destinationWorkspaceId)

    const destinationAuthority = yield* registry.getAuthority("branch-key")
    assert.ok(destinationAuthority)
    assert.notEqual(source.workspaceLeaseId, destinationAuthority.workspaceLeaseId)
    const destination = yield* workspaces.resolve(
      "branch-key",
      destinationAuthority.workspaceId,
      destinationAuthority.workspaceLeaseId,
    )
    const scriptMode = yield* Effect.promise(
      () => lstat(path.join(destination.workspacePath, "script.sh")),
    )
    assert.equal(scriptMode.mode & 0o777, 0o755)
    assert.equal(
      yield* Effect.promise(
        () => readlink(path.join(destination.workspacePath, "project-link")),
      ),
      "project.txt",
    )
    assert.equal(yield* Effect.promise(() => readFile(path.join(destination.workspacePath, "project.txt"), "utf8")), "parent")

    yield* Effect.promise(() => writeFile(path.join(destination.workspacePath, "project.txt"), "branch"))
    assert.equal(yield* Effect.promise(() => readFile(path.join(sourceWorkspace.workspacePath, "project.txt"), "utf8")), "parent")
    assert.deepEqual(yield* branches.prepare(request), prepared)

    const changed = yield* Effect.flip(branches.prepare({ ...request, sourceEnvironmentKey: "other-source" }))
    assert.equal(changed.reason, "workspace.conflict")
    const reusedDestination = yield* Effect.flip(branches.prepare({
      ...request,
      operationId: "3da0f9ea-a5f6-4ab6-b5ef-b33d10584bc6",
    }))
    assert.equal(reusedDestination.reason, "workspace.conflict")
  }))
})

test("branching an unused source creates an independent empty workspace", async () => {
  await withHarness(() => Effect.gen(function* () {
    const registry = yield* Registry
    const workspaces = yield* Workspaces
    const branches = yield* WorkspaceBranches
    yield* bindTestAuthority("empty-source")
    const prepared = yield* branches.prepare({
      operationId,
      sourceEnvironmentKey: "empty-source",
      destinationEnvironmentKey: "empty-branch",
    })
    const destinationAuthority = yield* registry.getAuthority("empty-branch")
    assert.ok(destinationAuthority)
    const destination = yield* workspaces.resolve(
      "empty-branch",
      destinationAuthority.workspaceId,
      destinationAuthority.workspaceLeaseId,
    )
    assert.deepEqual(yield* Effect.promise(() => readdir(destination.workspacePath)), [])
    assert.notEqual(prepared.sourceWorkspaceId, prepared.destinationWorkspaceId)
  }))
})

test("branch copy does not start when the source VM cannot stop", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-branch-close-"))
  const harness = makeTestLayer(stateDir, { closeFailure: true })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const environments = yield* Environments
    const registry = yield* Registry
    const branches = yield* WorkspaceBranches
    yield* bindTestAuthority("close-failure-source")
    yield* environments.ensure({ environmentKey: "close-failure-source" })
    const failure = yield* Effect.flip(branches.prepare({
      operationId,
      sourceEnvironmentKey: "close-failure-source",
      destinationEnvironmentKey: "close-failure-branch",
    }))
    assert.equal(failure.reason, "runtime.operation_failed")
    assert.equal(yield* registry.getAuthority("close-failure-branch"), undefined)
  }).pipe(Effect.provide(harness.layer))))
})

test("ready branch replay survives broker restart", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-branch-restart-"))
  const request = {
    operationId,
    sourceEnvironmentKey: "restart-source",
    destinationEnvironmentKey: "restart-branch",
  }
  const firstHarness = makeTestLayer(stateDir)
  const first = await Effect.runPromise(Effect.scoped(
    Effect.gen(function* () {
      const branches = yield* WorkspaceBranches
      yield* bindTestAuthority(request.sourceEnvironmentKey)
      return yield* branches.prepare(request)
    }).pipe(Effect.provide(firstHarness.layer)),
  ))
  const secondHarness = makeTestLayer(stateDir)
  const replayed = await Effect.runPromise(Effect.scoped(
    Effect.gen(function* () {
      const branches = yield* WorkspaceBranches
      yield* bindTestAuthority(request.sourceEnvironmentKey)
      return yield* branches.prepare(request)
    }).pipe(Effect.provide(secondHarness.layer)),
  ))
  assert.deepEqual(replayed, first)
})



test("environment restart remains blocked while stopped workspace work is running", async () => {
  await withHarness(() => Effect.gen(function* () {
    const environments = yield* Environments
    yield* bindTestAuthority("locked-source")
    yield* environments.ensure({ environmentKey: "locked-source" })
    const entered = yield* Deferred.make()
    const release = yield* Deferred.make()
    const stopped = yield* Effect.fork(
      environments.runWithEnvironmentStopped(
        "locked-source",
        Effect.zipRight(Deferred.succeed(entered, undefined), Deferred.await(release)),
      ),
    )
    yield* Deferred.await(entered)
    let restarted = false
    const restart = yield* Effect.fork(
      environments.ensure({ environmentKey: "locked-source" }).pipe(
        Effect.tap(() => Effect.sync(() => {
          restarted = true
        })),
      ),
    )
    yield* Effect.sleep("20 millis")
    assert.equal(restarted, false)
    yield* Deferred.succeed(release, undefined)
    yield* Fiber.join(stopped)
    const result = yield* Fiber.join(restart)
    assert.equal(result.state, "created")
  }))
})
