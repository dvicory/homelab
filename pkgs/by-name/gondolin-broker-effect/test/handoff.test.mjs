import assert from "node:assert/strict"
import { chmod, mkdir, mkdtemp, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect, Schema } from "effect"
import {
  CaptureWorkspaceHandoffRequest,
  HandoffRelativePath,
  SelectedArtifactPath,
} from "../dist/workspace-handoff/model.js"
import { Authorization } from "../dist/auth.js"
import { HandoffStore } from "../dist/workspace-handoff/repository.js"
import { HandoffStorage } from "../dist/workspace-handoff/frozen-tree.js"
import { brokerError } from "../dist/errors.js"
import { HandoffOperations } from "../dist/workspace-handoff/service.js"
import { BrokerDatabase } from "../dist/database.js"
import { TaskRunActivations } from "../dist/task-run-activations.js"
import { Environments } from "../dist/environments.js"
import { Workspaces } from "../dist/workspaces.js"
import { makeTestLayer, testTaskAuthority } from "./fakes.mjs"

const run = async (stateDir, callback) => {
  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  return Effect.runPromise(Effect.scoped(callback.pipe(Effect.provide(harness.layer))))
}

const producer = (
  environmentKey = "producer",
  taskId = "task-a",
  runId = "run-a",
  createOutput = true,
) => Effect.gen(function* () {
  const workspaces = yield* Workspaces
  const activations = yield* TaskRunActivations
  const acquired = yield* workspaces.acquire(environmentKey)
  const resolved = yield* workspaces.resolve(
    environmentKey,
    acquired.workspace.workspaceId,
    acquired.lease.leaseId,
  )
  yield* activations.activate({
    environmentKey,
    taskId,
    runId,
    ...testTaskAuthority(),
    workspaceId: acquired.workspace.workspaceId,
    workspaceLeaseId: acquired.lease.leaseId,
  })
  if (createOutput) {
    yield* Effect.promise(() => mkdir(path.join(resolved.workspacePath, "output"), { recursive: true }))
  }
  return { acquired, resolved, environmentKey, taskId, runId }
})

const failureReason = (effect) => Effect.flip(effect).pipe(
  Effect.map((error) => error.reason),
)
const capture = (ops, request) => ops.capture({ selectedArtifacts: [], ...request })
const readBody = (artifact) => Effect.promise(async () => {
  const chunks = []
  for await (const chunk of artifact.body) chunks.push(Buffer.from(chunk))
  return Buffer.concat(chunks)
})

test("freezes output and reads only selected immutable artifacts", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-test-"))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const source = yield* producer()
    yield* Effect.promise(() => mkdir(path.join(source.resolved.workspacePath, "output", "nested"), { recursive: true }))
    yield* Effect.promise(() => writeFile(
      path.join(source.resolved.workspacePath, "output", "nested", "answer.txt"),
      "exact handoff bytes",
    ))
    yield* Effect.promise(() => writeFile(
      path.join(source.resolved.workspacePath, "output", "private.txt"),
      "not selected",
    ))

    const handoff = yield* capture(ops, {
      finalizationId: "nested-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/nested/answer.txt"],
    })
    assert.deepEqual(handoff.selectedArtifacts, ["output/nested/answer.txt"])
    assert.equal(handoff.entryCount, 3)
    assert.equal(handoff.totalBytes, 31)

    const artifact = yield* ops.readArtifact({
      handoffId: handoff.handoffId,
      relativePath: "output/nested/answer.txt",
    })
    assert.equal((yield* readBody(artifact)).toString(), "exact handoff bytes")
    assert.equal(artifact.fileName, "answer.txt")

    const unselected = yield* failureReason(ops.readArtifact({
      handoffId: handoff.handoffId,
      relativePath: "output/private.txt",
    }))
    assert.equal(unselected, "policy.denied")

    const replay = yield* capture(ops, {
      finalizationId: "nested-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/nested/answer.txt"],
    })
    assert.equal(replay.handoffId, handoff.handoffId)
    const conflict = yield* failureReason(capture(ops, {
      finalizationId: "nested-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/private.txt"],
    }))
    assert.equal(conflict, "handoff.conflict")
  }))
})

test("validates paths and selected files before fencing the producer", async () => {
  const decodeCapture = Schema.decodeUnknownSync(
    CaptureWorkspaceHandoffRequest,
    { onExcessProperty: "error" },
  )
  const decodePath = Schema.decodeUnknownSync(HandoffRelativePath)
  assert.throws(() => decodeCapture({
    finalizationId: "f",
    environmentKey: "e",
    taskId: "t",
    runId: "r",
    selectedRoots: ["output"],
  }))
  assert.throws(() => decodePath("../secret"))
  assert.throws(() => decodePath("a/../../secret"))
  assert.throws(() => decodePath("a\u0000b"))
  assert.throws(() => Schema.decodeUnknownSync(SelectedArtifactPath)("output"))
  assert.throws(() => Schema.decodeUnknownSync(SelectedArtifactPath)("output/../secret"))

  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-preflight-"))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const activations = yield* TaskRunActivations
    const source = yield* producer()
    const missing = yield* failureReason(capture(ops, {
      finalizationId: "missing-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/missing.txt"],
    }))
    assert.equal(missing, "handoff.conflict")
    assert.equal(
      (yield* activations.validate(source.environmentKey, {
        taskId: source.taskId,
        runId: source.runId,
      })).state,
      "active",
    )

    yield* Effect.promise(() => chmod(path.join(source.resolved.workspacePath, "output"), 0o000))
    const structural = yield* failureReason(capture(ops, {
      finalizationId: "bad-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
    }))
    assert.equal(structural, "handoff.failed")
    assert.equal(
      (yield* activations.validate(source.environmentKey, {
        taskId: source.taskId,
        runId: source.runId,
      })).state,
      "active",
    )
    yield* Effect.promise(() => chmod(path.join(source.resolved.workspacePath, "output"), 0o755))
  }))
})

test("resumes an interrupted capture in a fresh broker service instance", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-restart-"))
  await run(stateDir, Effect.gen(function* () {
    const authorization = yield* Authorization
    const activations = yield* TaskRunActivations
    const store = yield* HandoffStore
    const workspaces = yield* Workspaces
    const source = yield* producer("restart-env", "restart-task", "restart-run")
    const activation = yield* activations.validate(source.environmentKey, {
      taskId: source.taskId,
      runId: source.runId,
    })
    const authority = yield* authorization.authorize({
      action: "workspace.capture",
      resource: `task-run:${source.taskId}`,
    })
    const staged = yield* Effect.sync(() => store.stageCapture({
      finalizationId: "restart-final",
      policyDecisionDigest: authority.decisionDigest,
      sourceActivationId: activation.activationId,
      selectedArtifacts: [],
    }))
    assert.equal(staged.state, "staging")
    yield* activations.consume({
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
    })
    yield* workspaces.release(
      source.environmentKey,
      source.acquired.workspace.workspaceId,
      source.acquired.lease.leaseId,
    )
  }))

  // Ending the first scoped layer simulates broker process termination: every
  // service and SQLite connection below is reconstructed from durable state.
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const store = yield* HandoffStore
    const captured = yield* capture(ops, {
      finalizationId: "restart-final",
      environmentKey: "restart-env",
      taskId: "restart-task",
      runId: "restart-run",
    })
    assert.equal(captured.entryCount, 0)
    assert.deepEqual(store.phases("restart-final"), [
      "staged", "fenced", "vm_closed", "copied", "validated", "installed", "ready",
    ])
  }))
})

test("does not publish output when source environment drain fails", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-close-failure-"))
  const harness = makeTestLayer(stateDir, {
    workspaceHandoffEnabled: true,
    closeFailure: true,
  })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const environments = yield* Environments
    const database = yield* BrokerDatabase
    const source = yield* producer("close-env", "close-task", "close-run")
    yield* environments.ensure({
      environmentKey: source.environmentKey,
      taskRun: { taskId: source.taskId, runId: source.runId },
    })
    const failure = yield* failureReason(capture(ops, {
      finalizationId: "close-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
    }))
    assert.equal(failure, "runtime.operation_failed")
    const row = database.connection.prepare(
      "SELECT state FROM workspace_handoffs WHERE finalization_id=?",
    ).get("close-final")
    assert.equal(row.state, "staging")
  }).pipe(Effect.provide(harness.layer))))
})

test("replays transient copy and ready-commit failures without reopening the writer", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-transient-"))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const storage = yield* HandoffStorage
    const store = yield* HandoffStore
    const source = yield* producer("transient-env", "transient-task", "transient-run")
    yield* Effect.promise(() => writeFile(
      path.join(source.resolved.workspacePath, "output", "answer.txt"),
      "answer",
    ))

    const originalCapture = storage.captureHandoff
    storage.captureHandoff = (...args) => originalCapture(...args).pipe(
      Effect.flatMap(() => Effect.fail(brokerError(
        "handoff.failed",
        "fault after publication",
        { cause: "transient" },
      ))),
    )
    assert.equal((yield* failureReason(capture(ops, {
      finalizationId: "transient-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/answer.txt"],
    }))), "handoff.failed")
    storage.captureHandoff = originalCapture

    const replayed = yield* capture(ops, {
      finalizationId: "transient-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/answer.txt"],
    })
    assert.equal(replayed.entryCount, 1)

    const source2 = yield* producer("commit-env", "commit-task", "commit-run")
    const originalMark = store.markHandoffReady
    store.markHandoffReady = () => { throw new Error("fault before ready commit") }
    assert.equal((yield* failureReason(capture(ops, {
      finalizationId: "commit-final",
      environmentKey: source2.environmentKey,
      taskId: source2.taskId,
      runId: source2.runId,
    }))), "handoff.failed")
    store.markHandoffReady = originalMark
    assert.equal((yield* capture(ops, {
      finalizationId: "commit-final",
      environmentKey: source2.environmentKey,
      taskId: source2.taskId,
      runId: source2.runId,
    })).entryCount, 0)
  }))
})
