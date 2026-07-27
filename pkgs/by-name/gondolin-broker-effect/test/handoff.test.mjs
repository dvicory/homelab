import assert from "node:assert/strict"
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect, Schema } from "effect"
import { CaptureWorkspaceHandoffRequest, HandoffRelativePath, SelectedArtifactPath } from "../dist/workspace-handoff/model.js"
import { Authorization } from "../dist/auth.js"
import { HandoffStore } from "../dist/workspace-handoff/repository.js"
import { HandoffStorage } from "../dist/workspace-handoff/frozen-tree.js"
import { brokerError } from "../dist/errors.js"
import { HandoffOperations } from "../dist/workspace-handoff/service.js"
import { BrokerDatabase } from "../dist/database.js"
import { TaskRunActivations } from "../dist/task-run-activations.js"
import { Environments } from "../dist/environments.js"
import { Workspaces } from "../dist/workspaces.js"
import { Registry } from "../dist/registry.js"
import { makeTestLayer } from "./fakes.mjs"

const policyDigest = "a".repeat(64)
const run = async (stateDir, callback) => {
  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  return Effect.runPromise(Effect.scoped(callback.pipe(Effect.provide(harness.layer))))
}

const producer = (environmentKey = "producer", taskId = "task-a", runId = "run-a", createOutput = true) => Effect.gen(function* () {
  const workspaces = yield* Workspaces
  const registry = yield* Registry
  const activations = yield* TaskRunActivations
  const acquired = yield* workspaces.acquire(environmentKey)
  const resolved = yield* workspaces.resolve(environmentKey, acquired.workspace.workspaceId, acquired.lease.leaseId)
  yield* registry.bindAuthority({ environmentKey, profile: "test", executor: "hermes-gateway", authorityClass: "default", policyDigest, workspaceId: acquired.workspace.workspaceId, workspaceLeaseId: acquired.lease.leaseId })
  yield* activations.activate({ environmentKey, taskId, runId, workspaceId: acquired.workspace.workspaceId, workspaceLeaseId: acquired.lease.leaseId, policyDigest })
  if (createOutput) yield* Effect.promise(() => mkdir(path.join(resolved.workspacePath, "output")))
  return { acquired, resolved, environmentKey, taskId, runId }
})
const failureReason = (effect) => Effect.flip(effect).pipe(Effect.map((error) => error.reason))
const capture = (ops, request) => ops.capture({ selectedArtifacts: [], ...request })

test("captures empty and nested output, imports privately, and streams exact frozen bytes", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-test-"))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const source = yield* producer()
    const empty = yield* capture(ops, { finalizationId: "empty-final", environmentKey: source.environmentKey, taskId: source.taskId, runId: source.runId })
    assert.deepEqual({ entryCount: empty.entryCount, totalBytes: empty.totalBytes }, { entryCount: 0, totalBytes: 0 })
    const replay = yield* capture(ops, { finalizationId: "empty-final", environmentKey: source.environmentKey, taskId: source.taskId, runId: source.runId })
    assert.equal(replay.handoffId, empty.handoffId)
    const conflict = yield* failureReason(capture(ops, { finalizationId: "empty-final", environmentKey: source.environmentKey, taskId: "different-task", runId: "different-run" }))
    assert.equal(conflict, "handoff.conflict")

    const source2 = yield* producer("producer-2", "task-b", "run-b")
    yield* Effect.promise(() => mkdir(path.join(source2.resolved.workspacePath, "output", "nested")))
    yield* Effect.promise(() => writeFile(path.join(source2.resolved.workspacePath, "output", "nested", "answer.txt"), "exact handoff bytes"))
    const handoff = yield* capture(ops, { finalizationId: "nested-final", environmentKey: source2.environmentKey, taskId: source2.taskId, runId: source2.runId, selectedArtifacts: ["output/nested/answer.txt"] })
    assert.equal(handoff.entryCount, 2)
    assert.equal(handoff.totalBytes, 19)

    const imported = yield* ops.importHandoff({ preparationId: "prep-1", sourceHandoffId: handoff.handoffId, sourceTaskId: source2.taskId, destinationTaskId: "child-task", destinationRunId: "child-run", destinationEnvironmentKey: "child-env" })
    const workspaces = yield* Workspaces
    const child = yield* workspaces.resolve("child-env", imported.workspace.workspaceId, imported.lease.leaseId)
    const copied = yield* Effect.promise(() => readFile(path.join(child.workspacePath, "output", "nested", "answer.txt"), "utf8"))
    assert.equal(copied, "exact handoff bytes")
    const childEntries = yield* Effect.promise(() => readdir(child.workspacePath))
    assert.deepEqual(childEntries.sort(), ["output"])

    const prepared = yield* ops.prepareExport({ deliveryId: "delivery-1", handoffId: handoff.handoffId, relativePath: "nested/answer.txt" })
    const replayedExport = yield* ops.prepareExport({ deliveryId: "delivery-1", handoffId: handoff.handoffId, relativePath: "nested/answer.txt" })
    assert.equal(replayedExport.exportToken, prepared.exportToken)
    const exportConflict = yield* failureReason(ops.prepareExport({ deliveryId: "delivery-1", handoffId: handoff.handoffId, relativePath: "other.txt" }))
    assert.equal(exportConflict, "handoff.conflict")
    const stream = yield* ops.readExport({ exportToken: prepared.exportToken })
    const chunks = yield* Effect.promise(async () => { const all = []; for await (const chunk of stream.body) all.push(Buffer.from(chunk)); return Buffer.concat(all).toString() })
    assert.equal(chunks, "exact handoff bytes")
    yield* ops.releaseExport({ exportToken: prepared.exportToken })
    const releasedPrepareFailure = yield* failureReason(ops.prepareExport({ deliveryId: "delivery-1", handoffId: handoff.handoffId, relativePath: "nested/answer.txt" }))
    const releasedAgain = yield* ops.releaseExport({ exportToken: prepared.exportToken })
    assert.deepEqual(releasedAgain, { released: true })
    assert.equal(releasedPrepareFailure, "handoff.invalid_state")
    const releasedFailure = yield* failureReason(ops.readExport({ exportToken: prepared.exportToken }))
    assert.equal(releasedFailure, "handoff.invalid_state")
    const largeSource = yield* producer("producer-large", "task-large", "run-large")
    const largeBytes = Buffer.allocUnsafe(150_000)
    for (let index = 0; index < largeBytes.length; index += 1) largeBytes[index] = index % 251
    yield* Effect.promise(() => writeFile(path.join(largeSource.resolved.workspacePath, "output", "large.bin"), largeBytes))
    const largeHandoff = yield* capture(ops, { finalizationId: "large-final", environmentKey: largeSource.environmentKey, taskId: largeSource.taskId, runId: largeSource.runId, selectedArtifacts: ["output/large.bin"] })
    const largePrepared = yield* ops.prepareExport({ deliveryId: "delivery-large", handoffId: largeHandoff.handoffId, relativePath: "large.bin" })
    const largeStream = yield* ops.readExport({ exportToken: largePrepared.exportToken })
    const largeCopied = yield* Effect.promise(async () => {
      const largeChunks = []
      for await (const chunk of largeStream.body) {
        await new Promise((resolve) => setTimeout(resolve, 1))
        largeChunks.push(Buffer.from(chunk))
      }
      return Buffer.concat(largeChunks)
    })
    assert.deepEqual(largeCopied, largeBytes)
    const database = yield* BrokerDatabase
    database.connection.prepare("UPDATE workspace_handoff_exports SET expires_at=? WHERE export_token=?").run(Date.now() - 1, largePrepared.exportToken)
    const expiredReadFailure = yield* failureReason(ops.readExport({ exportToken: largePrepared.exportToken }))
    assert.equal(expiredReadFailure, "handoff.invalid_state")
    const expiredRow = database.connection.prepare("SELECT state FROM workspace_handoff_exports WHERE export_token=?").get(largePrepared.exportToken)
    assert.equal(expiredRow.state, "expired")
    yield* workspaces.acquire("occupied-env")
    const blockedSource = yield* producer("producer-blocked", "task-blocked", "run-blocked")
    yield* Effect.promise(() => writeFile(path.join(blockedSource.resolved.workspacePath, "output", "answer.txt"), "blocked"))
    const blockedHandoff = yield* capture(ops, { finalizationId: "blocked-final", environmentKey: blockedSource.environmentKey, taskId: blockedSource.taskId, runId: blockedSource.runId, selectedArtifacts: ["output/answer.txt"] })
    const occupiedFailure = yield* failureReason(ops.importHandoff({
      preparationId: "blocked-prep",
      sourceHandoffId: blockedHandoff.handoffId,
      sourceTaskId: blockedSource.taskId,
      destinationTaskId: "occupied-task",
      destinationRunId: "occupied-run",
      destinationEnvironmentKey: "occupied-env",
    }))
    assert.equal(occupiedFailure, "workspace.conflict")
  }))
})
test("rejects traversal and preserves activation on structural preflight failure", async () => {
  const decodeCapture = Schema.decodeUnknownSync(CaptureWorkspaceHandoffRequest, { onExcessProperty: "error" })
  const decodePath = Schema.decodeUnknownSync(HandoffRelativePath, { onExcessProperty: "error" })
  assert.throws(() => decodeCapture({ finalizationId: "f", environmentKey: "e", taskId: "t", runId: "r", selectedRoots: ["output"] }))
  assert.throws(() => decodePath("../secret"))
  assert.throws(() => decodePath("a/../../secret"))
  assert.throws(() => decodePath("a\u0000b"))

  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-preflight-"))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const activations = yield* TaskRunActivations
    const source = yield* producer()
    yield* Effect.promise(() => chmod(path.join(source.resolved.workspacePath, "output"), 0o000))
    const preflightFailure = yield* failureReason(capture(ops, { finalizationId: "bad-final", environmentKey: source.environmentKey, taskId: source.taskId, runId: source.runId }))
    assert.equal(preflightFailure, "handoff.failed")
    const stillActive = yield* activations.validate(source.environmentKey, { taskId: source.taskId, runId: source.runId })
    assert.equal(stillActive.state, "active")
    yield* Effect.promise(() => chmod(path.join(source.resolved.workspacePath, "output"), 0o755))
  }))
})
test("replays a staged capture after activation fencing and broker restart", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-restart-"))
  await run(stateDir, Effect.gen(function* () {
    const authorization = yield* Authorization
    const activations = yield* TaskRunActivations
    const store = yield* HandoffStore
    const workspaces = yield* Workspaces
    const source = yield* producer("restart-env", "restart-task", "restart-run")
    const activation = yield* activations.validate(source.environmentKey, { taskId: source.taskId, runId: source.runId })
    const authority = yield* authorization.authorize({ action: "workspace.capture", resource: `task-run:${source.taskId}` })
    const staged = yield* Effect.sync(() => store.stageCapture({
      finalizationId: "restart-final",
      policyDecisionDigest: authority.decisionDigest,
      sourceActivationId: activation.activationId,
      selectedArtifacts: [],
    }))
    assert.equal(staged.state, "staging")
    const consumed = yield* activations.consume({ environmentKey: source.environmentKey, taskId: source.taskId, runId: source.runId })
    assert.equal(consumed.activation.state, "consumed")
    yield* workspaces.release(source.environmentKey, source.acquired.workspace.workspaceId, source.acquired.lease.leaseId)
  }))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const database = yield* BrokerDatabase
    const captured = yield* capture(ops, { finalizationId: "restart-final", environmentKey: "restart-env", taskId: "restart-task", runId: "restart-run" })
    assert.equal(captured.entryCount, 0)
    const row = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE handoff_id=?").get(captured.handoffId)
    assert.equal(row.state, "ready")
  }))
})
test("rejects staged recovery when a newer active writer lease exists", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-newer-lease-"))
  await run(stateDir, Effect.gen(function* () {
    const authorization = yield* Authorization
    const activations = yield* TaskRunActivations
    const store = yield* HandoffStore
    const workspaces = yield* Workspaces
    const ops = yield* HandoffOperations
    const database = yield* BrokerDatabase
    const source = yield* producer("newer-env", "newer-task", "newer-run")
    const activation = yield* activations.validate(source.environmentKey, { taskId: source.taskId, runId: source.runId })
    const authority = yield* authorization.authorize({ action: "workspace.capture", resource: `task-run:${source.taskId}` })
    const staged = yield* Effect.sync(() => store.stageCapture({
      finalizationId: "newer-final",
      policyDecisionDigest: authority.decisionDigest,
      selectedArtifacts: [],
      sourceActivationId: activation.activationId,
    }))
    yield* activations.consume({ environmentKey: source.environmentKey, taskId: source.taskId, runId: source.runId })
    yield* workspaces.release(source.environmentKey, source.acquired.workspace.workspaceId, source.acquired.lease.leaseId)
    const newer = yield* workspaces.acquire(source.environmentKey, source.acquired.workspace.workspaceId)
    const failure = yield* failureReason(capture(ops, {
      finalizationId: "newer-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
    }))
    assert.equal(failure, "workspace.conflict")
    const row = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE handoff_id=?").get(staged.handoffId)
    assert.equal(row.state, "staging")
    assert.equal(newer.lease.state, "active")
  }))
})
test("does not copy staged output when environment drain fails", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-close-failure-"))
  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true, closeFailure: true })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const authorization = yield* Authorization
    const activations = yield* TaskRunActivations
    const store = yield* HandoffStore
    const database = yield* BrokerDatabase
    const environments = yield* Environments
    const ops = yield* HandoffOperations;
    const source = yield* producer("close-failure-env", "close-failure-task", "close-failure-run")
    yield* environments.ensure({
      environmentKey: source.environmentKey,
      taskRun: { taskId: source.taskId, runId: source.runId },
    })
    const activation = yield* activations.validate(source.environmentKey, { taskId: source.taskId, runId: source.runId })
    const authority = yield* authorization.authorize({ action: "workspace.capture", resource: `task-run:${source.taskId}` })
    const staged = yield* Effect.sync(() => store.stageCapture({
      finalizationId: "close-failure-final",
      policyDecisionDigest: authority.decisionDigest,
      selectedArtifacts: [],
      sourceActivationId: activation.activationId,
    }))
    const failure = yield* failureReason(capture(ops, {
      finalizationId: "close-failure-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
    }))
    assert.equal(failure, "runtime.operation_failed")
    const row = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE handoff_id=?").get(staged.handoffId)
    assert.equal(row.state, "staging")
  }).pipe(Effect.provide(harness.layer))))
  const restarted = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const database = yield* BrokerDatabase
    const failure = yield* failureReason(capture(ops, {
      finalizationId: "close-failure-final",
      environmentKey: "close-failure-env",
      taskId: "close-failure-task",
      runId: "close-failure-run",
    }))
    assert.equal(failure, "runtime.operation_failed")
    const row = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE finalization_id=?").get("close-failure-final")
    assert.equal(row.state, "staging")
  }).pipe(Effect.provide(restarted.layer))))
})
test("captures an empty handoff when output root is absent", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-missing-output-"))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const source = yield* producer("missing-output-env", "missing-output-task", "missing-output-run", false)
    const handoff = yield* capture(ops, {
      finalizationId: "missing-output-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
    })
    assert.deepEqual({ entryCount: handoff.entryCount, totalBytes: handoff.totalBytes }, { entryCount: 0, totalBytes: 0 })
  }))
})
test("selected artifact validation is pre-fence and replay tuple is exact", async () => {
  assert.throws(() => Schema.decodeUnknownSync(SelectedArtifactPath)("output"))
  assert.throws(() => Schema.decodeUnknownSync(SelectedArtifactPath)("output/../secret"))
  assert.throws(() => Schema.decodeUnknownSync(SelectedArtifactPath)("output/a\u0000b"))
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-selected-"))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const activations = yield* TaskRunActivations
    const source = yield* producer("selected-env", "selected-task", "selected-run")
    const missing = yield* failureReason(capture(ops, {
      finalizationId: "selected-missing-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/missing.txt"],
    }))
    assert.equal(missing, "handoff.conflict")
    const stillActive = yield* activations.validate(source.environmentKey, { taskId: source.taskId, runId: source.runId })
    assert.equal(stillActive.state, "active")
    yield* Effect.promise(() => writeFile(path.join(source.resolved.workspacePath, "output", "answer.txt"), "answer"))
    const handoff = yield* capture(ops, {
      finalizationId: "selected-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/answer.txt"],
    })
    assert.equal(handoff.entryCount, 1)
    const conflict = yield* failureReason(capture(ops, {
      finalizationId: "selected-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/other.txt"],
    }))
    assert.equal(conflict, "handoff.conflict")
  }))
})
test("replays staging after transient publication and ready-commit faults", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-transient-"))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const storage = yield* HandoffStorage
    const store = yield* HandoffStore
    const database = yield* BrokerDatabase
    const source = yield* producer("transient-copy-env", "transient-copy-task", "transient-copy-run")
    yield* Effect.promise(() => writeFile(path.join(source.resolved.workspacePath, "output", "answer.txt"), "answer"))
    const originalCapture = storage.captureHandoff
    storage.captureHandoff = (...args) => originalCapture(...args).pipe(
      Effect.flatMap(() => Effect.fail(brokerError("handoff.failed", "fault after publication", { cause: "transient" }))),
    )
    assert.notEqual(storage.captureHandoff, originalCapture)
    const firstFailure = yield* failureReason(capture(ops, {
      finalizationId: "transient-copy-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/answer.txt"],
    }))
    storage.captureHandoff = originalCapture
    assert.equal(firstFailure, "handoff.failed")
    const stagedRow = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE finalization_id=?").get("transient-copy-final")
    assert.equal(stagedRow.state, "staging")
    const replayed = yield* capture(ops, {
      finalizationId: "transient-copy-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/answer.txt"],
    })
    assert.equal(replayed.entryCount, 1)
    const readyRow = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE finalization_id=?").get("transient-copy-final")
    assert.equal(readyRow.state, "ready")

    const source2 = yield* producer("transient-commit-env", "transient-commit-task", "transient-commit-run")
    const originalMark = store.markHandoffReady
    store.markHandoffReady = () => { throw new Error("fault before ready commit") }
    const commitFailure = yield* failureReason(capture(ops, {
      finalizationId: "transient-commit-final",
      environmentKey: source2.environmentKey,
      taskId: source2.taskId,
      runId: source2.runId,
    }))
    store.markHandoffReady = originalMark
    assert.equal(commitFailure, "handoff.failed")
    const commitStaged = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE finalization_id=?").get("transient-commit-final")
    assert.equal(commitStaged.state, "staging")
    const commitReplay = yield* capture(ops, {
      finalizationId: "transient-commit-final",
      environmentKey: source2.environmentKey,
      taskId: source2.taskId,
      runId: source2.runId,
    })
    assert.equal(commitReplay.entryCount, 0)
  }))
})
test("terminalizes selected deletion race and recovery after restart", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-handoff-selected-delete-"))
  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const storage = yield* HandoffStorage
    const database = yield* BrokerDatabase
    const source = yield* producer("delete-race-env", "delete-race-task", "delete-race-run")
    const selectedPath = path.join(source.resolved.workspacePath, "output", "answer.txt")
    yield* Effect.promise(() => writeFile(selectedPath, "answer"))
    const originalCapture = storage.captureHandoff
    storage.captureHandoff = (...args) => Effect.promise(() => rm(path.dirname(selectedPath), { recursive: true, force: true })).pipe(
      Effect.flatMap(() => originalCapture(...args)),
    )
    const raceFailure = yield* failureReason(capture(ops, {
      finalizationId: "delete-race-final",
      environmentKey: source.environmentKey,
      taskId: source.taskId,
      runId: source.runId,
      selectedArtifacts: ["output/answer.txt"],
    }))
    storage.captureHandoff = originalCapture
    assert.equal(raceFailure, "handoff.conflict")
    const raceRow = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE finalization_id=?").get("delete-race-final")
    assert.equal(raceRow.state, "publication_failed")

    const activations = yield* TaskRunActivations
    const workspaces = yield* Workspaces
    const store = yield* HandoffStore
    const authorization = yield* Authorization
    const recovery = yield* producer("delete-recovery-env", "delete-recovery-task", "delete-recovery-run")
    const recoveryPath = path.join(recovery.resolved.workspacePath, "output", "answer.txt")
    yield* Effect.promise(() => writeFile(recoveryPath, "answer"))
    const activation = yield* activations.validate(recovery.environmentKey, { taskId: recovery.taskId, runId: recovery.runId })
    const authority = yield* authorization.authorize({ action: "workspace.capture", resource: `task-run:${recovery.taskId}` })
    yield* Effect.sync(() => store.stageCapture({
      finalizationId: "delete-recovery-final",
      policyDecisionDigest: authority.decisionDigest,
      sourceActivationId: activation.activationId,
      selectedArtifacts: ["output/answer.txt"],
    }))
    yield* activations.consume({ environmentKey: recovery.environmentKey, taskId: recovery.taskId, runId: recovery.runId })
    yield* workspaces.release(recovery.environmentKey, recovery.acquired.workspace.workspaceId, recovery.acquired.lease.leaseId)
    yield* Effect.promise(() => rm(path.dirname(recoveryPath), { recursive: true, force: true }))
  }))

  await run(stateDir, Effect.gen(function* () {
    const ops = yield* HandoffOperations
    const database = yield* BrokerDatabase
    const recoveryFailure = yield* failureReason(capture(ops, {
      finalizationId: "delete-recovery-final",
      environmentKey: "delete-recovery-env",
      taskId: "delete-recovery-task",
      runId: "delete-recovery-run",
      selectedArtifacts: ["output/answer.txt"],
    }))
    assert.equal(recoveryFailure, "handoff.conflict")
    const recoveryRow = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE finalization_id=?").get("delete-recovery-final")
    assert.equal(recoveryRow.state, "publication_failed")
    const raceRow = database.connection.prepare("SELECT state FROM workspace_handoffs WHERE finalization_id=?").get("delete-race-final")
    assert.equal(raceRow.state, "publication_failed")
  }))
})
