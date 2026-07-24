import assert from "node:assert/strict"
import * as fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { Environments } from "../dist/environments.js"
import { Registry } from "../dist/registry.js"
import { RevisionOperations } from "../dist/revision-operations.js"
import { RevisionStorage } from "../dist/revision-storage.js"
import { TaskRunActivations } from "../dist/task-run-activations.js"
import { Workspaces } from "../dist/workspaces.js"
import { makeTestLayer } from "./fakes.mjs"

const policyDigest = "a".repeat(64)
const relationDigest = "d".repeat(64)

const withHarness = async (run, options = {}) => {
  const stateDir = await fs.mkdtemp(path.join(os.tmpdir(), "gondolin-revision-operations-"))
  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true, ...options })
  return Effect.runPromise(Effect.scoped(run(stateDir).pipe(Effect.provide(harness.layer))))
}

const bindProducer = (environmentKey = "producer-environment") => Effect.gen(function* () {
  const workspaces = yield* Workspaces
  const registry = yield* Registry
  const activations = yield* TaskRunActivations
  const acquired = yield* workspaces.acquire(environmentKey)
  yield* registry.bindAuthority({
    environmentKey,
    profile: "test",
    executor: "hermes-gateway",
    authorityClass: "default",
    policyDigest,
    workspaceId: acquired.workspace.workspaceId,
    workspaceLeaseId: acquired.lease.leaseId
  })
  const taskId = `task-${environmentKey}`
  const runId = `run-${environmentKey}`
  yield* activations.activate({
    environmentKey,
    taskId,
    runId,
    workspaceId: acquired.workspace.workspaceId,
    workspaceLeaseId: acquired.lease.leaseId,
    policyDigest
  })
  const resolved = yield* workspaces.resolve(
    environmentKey,
    acquired.workspace.workspaceId,
    acquired.lease.leaseId
  )
  return { acquired, resolved, environmentKey, taskId, runId }
})

const publishRequest = (producer, overrides = {}) => ({
  finalizationId: `finalization-${producer.environmentKey}`,
  environmentKey: producer.environmentKey,
  taskId: producer.taskId,
  runId: producer.runId,
  selectedRoots: ["output"],
  ...overrides
})

const importRequest = (published, producer, overrides = {}) => ({
  preparationId: "preparation-consumer",
  sourceRevisionId: published.revisionId,
  sourceTaskId: producer.taskId,
  destinationTaskId: "consumer-task",
  destinationRunId: "consumer-run",
  destinationEnvironmentKey: "consumer-environment",
  relationDigest,
  ...overrides
})

const failureReason = (effect) => Effect.flip(effect).pipe(
  Effect.map((error) => error.reason)
)

test("publication fences once and replays the same verified revision", async () => {
  await withHarness(() => Effect.gen(function* () {
    const operations = yield* RevisionOperations
    const activations = yield* TaskRunActivations
    const producer = yield* bindProducer()
    yield* Effect.promise(async () => {
      await fs.mkdir(path.join(producer.resolved.workspacePath, "output"))
      await fs.writeFile(path.join(producer.resolved.workspacePath, "output", "answer.txt"), "answer")
      await fs.writeFile(path.join(producer.resolved.workspacePath, "ignored.txt"), "ignore")
    })
    const request = publishRequest(producer)
    const published = yield* operations.publish(request)
    assert.equal(published.sourceTaskId, producer.taskId)
    assert.equal(published.logicalBytes, 6)
    assert.equal((yield* operations.publish(request)).revisionId, published.revisionId)
    assert.equal(yield* failureReason(operations.publish({ ...request, selectedRoots: ["ignored.txt"] })), "revision.conflict")
    assert.equal(yield* failureReason(activations.validate(producer.environmentKey, {
      taskId: producer.taskId,
      runId: producer.runId
    })), "run_activation.stale")
  }))
})

test("private import replays one destination and remains independently mutable", async () => {
  await withHarness(() => Effect.gen(function* () {
    const operations = yield* RevisionOperations
    const storage = yield* RevisionStorage
    const workspaces = yield* Workspaces
    const producer = yield* bindProducer("import-producer")
    yield* Effect.promise(async () => {
      await fs.mkdir(path.join(producer.resolved.workspacePath, "output"))
      await fs.writeFile(path.join(producer.resolved.workspacePath, "output", "answer.txt"), "parent")
    })
    const published = yield* operations.publish(publishRequest(producer))
    const request = importRequest(published, producer)
    const imported = yield* operations.importRevision(request)
    const replay = yield* operations.importRevision(request)
    assert.equal(replay.workspace.workspaceId, imported.workspace.workspaceId)
    assert.equal(replay.lease.leaseId, imported.lease.leaseId)

    const destination = yield* workspaces.resolve(
      request.destinationEnvironmentKey,
      imported.workspace.workspaceId,
      imported.lease.leaseId
    )
    yield* Effect.promise(() => fs.writeFile(
      path.join(destination.workspacePath, "output", "answer.txt"),
      "child"
    ))
    assert.equal(yield* Effect.promise(() => fs.readFile(
      path.join(producer.resolved.workspacePath, "output", "answer.txt"),
      "utf8"
    )), "parent")
    yield* storage.verifyRevision(published.revisionId)
    assert.equal((yield* operations.importRevision(request)).workspace.workspaceId, imported.workspace.workspaceId)
  }))
})

test("import binds every identity and rejects tampered sources", async () => {
  await withHarness((stateDir) => Effect.gen(function* () {
    const operations = yield* RevisionOperations
    const producer = yield* bindProducer("conflict-producer")
    yield* Effect.promise(() => fs.writeFile(path.join(producer.resolved.workspacePath, "output"), "safe"))
    const published = yield* operations.publish(publishRequest(producer))
    const request = importRequest(published, producer)
    assert.equal(yield* failureReason(operations.importRevision({
      ...request,
      sourceTaskId: "unrelated-task"
    })), "revision.conflict")

    const stored = path.join(
      stateDir,
      "workspace-revisions",
      "ready",
      published.revisionId,
      "tree",
      "output"
    )
    yield* Effect.promise(async () => {
      await fs.chmod(stored, 0o644)
      await fs.writeFile(stored, "tampered")
    })
    assert.equal(yield* failureReason(operations.importRevision(request)), "revision.failed")
  }))
})

test("publication is denied when policy has no matching action", async () => {
  await withHarness(() => Effect.gen(function* () {
    const operations = yield* RevisionOperations
    const producer = yield* bindProducer("denied-producer")
    yield* Effect.promise(() => fs.writeFile(path.join(producer.resolved.workspacePath, "output"), "safe"))
    assert.equal(yield* failureReason(operations.publish(publishRequest(producer))), "policy.denied")
  }), {
    policyFile: {
      policy: {
        version: 1,
        statements: [{ effect: "deny", actions: ["workspace.publish"], resources: ["*"] }]
      }
    }
  })
})
