import assert from "node:assert/strict"
import { access, mkdir, mkdtemp, readFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { HandoffOperations } from "../dist/workspace-handoff/service.js"
import { HandoffStore } from "../dist/workspace-handoff/repository.js"
import { InputPreparations } from "../dist/task-run-inputs/service.js"
import { TaskRunActivations } from "../dist/task-run-activations.js"
import { Workspaces } from "../dist/workspaces.js"
import { makeTestLayer, testTaskAuthority } from "./fakes.mjs"

const run = async (stateDir, callback) => {
  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  return Effect.runPromise(Effect.scoped(callback.pipe(Effect.provide(harness.layer))))
}
const qtask = (board, task) => `b${board.length}:${board}:t${task.length}:${task}`
const qrun = (board, task, run) => `${qtask(board, task)}:r${run}`

const capture = (environmentKey, taskId, runId) => Effect.gen(function* () {
  const workspaces = yield* Workspaces
  const activations = yield* TaskRunActivations
  const acquired = yield* workspaces.acquire(environmentKey)
  const resolved = yield* workspaces.resolve(environmentKey, acquired.workspace.workspaceId, acquired.lease.leaseId)
  yield* activations.activate({
    environmentKey,
    taskId,
    runId,
    ...testTaskAuthority(),
    workspaceId: acquired.workspace.workspaceId,
    workspaceLeaseId: acquired.lease.leaseId,
  })
  yield* Effect.promise(() => mkdir(path.join(resolved.workspacePath, "output"), { recursive: true }))
  const operations = yield* HandoffOperations
  return yield* operations.capture({
    finalizationId: `final-${taskId}-${runId}`,
    environmentKey,
    taskId,
    runId,
    selectedArtifacts: [],
  })
})

const prepare = (handoffId, task = "consumer", runId = "run-1") => ({
  environmentKey: "board",
  board: "board",
  taskId: qtask("board", task),
  runId: qrun("board", task, runId),
  generation: 1,
  digest: "a".repeat(64),
  lane: "default",
  laneRevision: "b".repeat(64),
  policyRevision: "c".repeat(64),
  limits: { maxInputs: 8, maxInputBytes: 1000, maxInputEntries: 100, maxInputPathBytes: 4096 },
  inputs: [{
    producerTaskId: qtask("board", "producer"),
    producerRunId: qrun("board", "producer", "producer-run"),
    mountName: "producer",
    producerLane: "default",
    handoffId,
  }],
})

const exists = async (candidate) => access(candidate).then(() => true, () => false)

test("mark reclaimable is idempotent and deletes an unreferenced ready handoff", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-reclaim-mark-"))
  await run(stateDir, Effect.gen(function* () {
    const handoff = yield* capture("board", qtask("board", "producer"), qrun("board", "producer", "producer-run"))
    const inputs = yield* InputPreparations
    const first = yield* inputs.markReclaimable([handoff.handoffId])
    assert.deepEqual(first.results, [{ handoffId: handoff.handoffId, status: "deleted" }])
    const replay = yield* inputs.markReclaimable([handoff.handoffId])
    assert.deepEqual(replay.results, [{ handoffId: handoff.handoffId, status: "skipped" }])
    assert.equal(yield* Effect.promise(() => exists(path.join(stateDir, "workspace-handoffs", "ready", handoff.handoffId))), false)
  }))
})

test("referenced handoffs retain bytes until release, and release replays cleanly", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-reclaim-release-"))
  await run(stateDir, Effect.gen(function* () {
    const handoff = yield* capture("board", qtask("board", "producer"), qrun("board", "producer", "producer-run"))
    const inputs = yield* InputPreparations
    yield* inputs.prepare(prepare(handoff.handoffId))
    const marked = yield* inputs.markReclaimable([handoff.handoffId])
    assert.deepEqual(marked.results, [{ handoffId: handoff.handoffId, status: "retained" }])
    const released = yield* inputs.releaseTask("board", qtask("board", "consumer"))
    assert.deepEqual(released, { released: 1, deleted: [handoff.handoffId] })
    const replay = yield* inputs.releaseTask("board", qtask("board", "consumer"))
    assert.deepEqual(replay, { released: 0, deleted: [] })
    assert.equal(yield* Effect.promise(() => exists(path.join(stateDir, "workspace-handoffs", "ready", handoff.handoffId))), false)
  }))
})

test("unknown reclaim ids are tolerated and finalization releases a run", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-reclaim-finalize-"))
  await run(stateDir, Effect.gen(function* () {
    const inputs = yield* InputPreparations
    assert.deepEqual((yield* inputs.markReclaimable(["unknown-handoff"])).results, [
      { handoffId: "unknown-handoff", status: "skipped" },
    ])
    const source = yield* capture("board", qtask("board", "producer"), qrun("board", "producer", "producer-run"))
    yield* inputs.prepare(prepare(source.handoffId, "producer", "producer-run"))
    assert.deepEqual((yield* inputs.markReclaimable([source.handoffId])).results, [
      { handoffId: source.handoffId, status: "retained" },
    ])
    const operations = yield* HandoffOperations
    yield* operations.capture({
      finalizationId: `final-${qtask("board", "producer")}-${qrun("board", "producer", "producer-run")}`,
      environmentKey: "board",
      taskId: qtask("board", "producer"),
      runId: qrun("board", "producer", "producer-run"),
      selectedArtifacts: [],
    })
    const store = yield* HandoffStore
    assert.throws(() => store.getHandoff(source.handoffId), /does not exist/)
  }))
})

test("reclaim has no timer or background sweep implementation", async () => {
  const source = await readFile(path.join(import.meta.dirname, "../src/task-run-inputs/service.ts"), "utf8")
  assert.doesNotMatch(source, /setInterval|setTimeout|sweep/i)
})
