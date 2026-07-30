import assert from "node:assert/strict"
import { chmod, mkdtemp, mkdir, stat, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { applyWorkPlanePermission } from "../dist/project-workspace/git-adapter.js"
import { Workspaces } from "../dist/workspaces.js"
import { makeTestLayer } from "./fakes.mjs"

// The setgid bit is load-bearing on the Linux deployment, but restricted
// sandboxes (Darwin nixbld) silently strip it from chmod. Probe once and
// assert the full mode only where the filesystem preserves it.
const probeSetgid = async () => {
  const probe = await mkdtemp(path.join(os.tmpdir(), "gondolin-setgid-probe-"))
  await chmod(probe, 0o2770)
  return ((await stat(probe)).mode & 0o2000) !== 0
}
const hasSetgid = await probeSetgid()
const expectMode = (actual, wanted) => {
  const masked = hasSetgid ? 0o7777 : 0o777
  assert.equal(actual & masked, wanted & masked)
}

const withHarness = async (run) => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-workspace-modes-test-"))
  const harness = makeTestLayer(stateDir)
  return Effect.runPromise(Effect.scoped(run(stateDir).pipe(Effect.provide(harness.layer))))
}

test("workspace data is group-shared for trusted external workers", async () => {
  const modes = async (target) => (await stat(target)).mode & 0o7777
  await withHarness((stateDir) => Effect.gen(function* () {
    const workspaces = yield* Workspaces
    const acquired = yield* workspaces.acquire("conversation-modes")
    const workspacePath = path.join(stateDir, "workspaces", "data", acquired.workspace.workspaceId)

    expectMode(yield* Effect.promise(() => modes(path.join(stateDir, "workspaces", "data"))), 0o750)
    expectMode(yield* Effect.promise(() => modes(workspacePath)), 0o2770)
    expectMode(yield* Effect.promise(() => modes(path.join(workspacePath, "work"))), 0o2770)
    expectMode(yield* Effect.promise(() => modes(path.join(workspacePath, "output"))), 0o2770)
    expectMode(yield* Effect.promise(() => modes(path.join(workspacePath, "inputs"))), 0o2750)
    // The layout marker stays broker-private metadata.
    expectMode(yield* Effect.promise(() => modes(path.join(workspacePath, ".broker-workspace-layout"))), 0o400)
  }))
})

test("work plane permission applies uniformly to installed trees", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "gondolin-permission-test-"))
  const workPlane = path.join(root, "work")
  await mkdir(path.join(workPlane, "src"), { recursive: true })
  await writeFile(path.join(workPlane, "README.md"), "readme")
  await writeFile(path.join(workPlane, "src", "run.sh"), "#!/bin/sh\n", { mode: 0o700 })

  const modes = async (target) => (await stat(target)).mode & 0o7777

  await applyWorkPlanePermission(workPlane, "workspace-write")
  expectMode(await modes(workPlane), 0o2770)
  expectMode(await modes(path.join(workPlane, "src")), 0o2770)
  expectMode(await modes(path.join(workPlane, "README.md")), 0o660)
  expectMode(await modes(path.join(workPlane, "src", "run.sh")), 0o770)

  await applyWorkPlanePermission(workPlane, "read-only")
  expectMode(await modes(workPlane), 0o2750)
  expectMode(await modes(path.join(workPlane, "src")), 0o2750)
  expectMode(await modes(path.join(workPlane, "README.md")), 0o640)
  expectMode(await modes(path.join(workPlane, "src", "run.sh")), 0o750)
})
