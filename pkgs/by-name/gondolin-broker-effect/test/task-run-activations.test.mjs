import assert from "node:assert/strict"
import { mkdtemp } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { DatabaseSync } from "node:sqlite"
import test from "node:test"
import { Effect, Stream } from "effect"
import { BrokerDatabase } from "../dist/database.js"
import { Environments } from "../dist/environments.js"
import { Executor } from "../dist/exec.js"
import { Files } from "../dist/files.js"
import { Registry } from "../dist/registry.js"
import { TaskRunActivations } from "../dist/task-run-activations.js"
import { Workspaces } from "../dist/workspaces.js"
import { makeTestLayer } from "./fakes.mjs"

const policyDigest = "a".repeat(64)

const withHarness = async (run) => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-task-run-test-"))
  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  return Effect.runPromise(Effect.scoped(run(harness).pipe(Effect.provide(harness.layer))))
}

test("workspace handoff migrates a legacy environments table", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-task-run-legacy-"))
  const legacy = new DatabaseSync(path.join(stateDir, "broker.sqlite"))
  legacy.exec(`
    CREATE TABLE environments (
      environment_key TEXT PRIMARY KEY,
      generation INTEGER NOT NULL CHECK (generation > 0),
      state TEXT NOT NULL CHECK (state IN ('creating','active','closing','closed','failed')),
      policy_digest TEXT NOT NULL CHECK (length(policy_digest) = 64),
      worklane TEXT NOT NULL,
      asset_build_id TEXT NOT NULL,
      workspace_id TEXT NOT NULL,
      workspace_lease_id TEXT NOT NULL,
      vm_id TEXT,
      host_pid INTEGER,
      failure_reason TEXT,
      updated_at INTEGER NOT NULL
    ) STRICT;
  `)
  legacy.prepare(`
    INSERT INTO environments (
      environment_key, generation, state, policy_digest, worklane,
      asset_build_id, workspace_id, workspace_lease_id, vm_id,
      host_pid, failure_reason, updated_at
    ) VALUES (?, 1, 'closed', ?, 'default', 'legacy-build', ?, ?, NULL, NULL, NULL, 1)
  `).run(
    "legacy-environment",
    policyDigest,
    "11111111-1111-4111-8111-111111111111",
    "22222222-2222-4222-8222-222222222222",
  )
  legacy.close()

  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    yield* TaskRunActivations
    const database = yield* BrokerDatabase
    const columns = database.connection.prepare(
      "SELECT name FROM pragma_table_info('environments') ORDER BY cid",
    ).all()
    assert.ok(columns.some((column) => column.name === "run_activation_id"))
    const environment = database.connection.prepare(
      "SELECT environment_key, run_activation_id FROM environments WHERE environment_key=?",
    ).get("legacy-environment")
    assert.equal(environment.environment_key, "legacy-environment")
    assert.equal(environment.run_activation_id, null)
  }).pipe(Effect.provide(harness.layer))))
})

test("startup supersedes active task runs from a prior policy", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-task-run-policy-"))
  const firstHarness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const runActivations = yield* TaskRunActivations
    const acquired = yield* bindWorkspace("task-policy-rollover")
    yield* runActivations.activate({
      environmentKey: "task-policy-rollover",
      taskId: "task-policy-rollover",
      runId: "run-policy-rollover",
      workspaceId: acquired.workspace.workspaceId,
      workspaceLeaseId: acquired.lease.leaseId,
      policyDigest
    })
  }).pipe(Effect.provide(firstHarness.layer))))

  const secondHarness = makeTestLayer(stateDir, {
    workspaceHandoffEnabled: true,
    policyFile: {
      ...firstHarness.config.policyFile,
      policyDigest: "b".repeat(64)
    }
  })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    yield* TaskRunActivations
    const database = yield* BrokerDatabase
    const activation = database.connection.prepare(`
      SELECT state, superseded_at
      FROM task_run_activations
      WHERE run_id='run-policy-rollover'
    `).get()
    assert.equal(activation.state, "superseded")
    assert.equal(typeof activation.superseded_at, "number")
  }).pipe(Effect.provide(secondHarness.layer))))
})

const bindWorkspace = (environmentKey) => Effect.gen(function* () {
  const workspaces = yield* Workspaces
  const registry = yield* Registry
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
  return acquired
})

const activationRequest = (acquired, overrides = {}) => ({
  environmentKey: "task-environment",
  taskId: "task-a",
  runId: "run-a",
  workspaceId: acquired.workspace.workspaceId,
  workspaceLeaseId: acquired.lease.leaseId,
  policyDigest,
  ...overrides
})

test("task-run activation fences ensure, execution, and files after consumption", async () => {
  await withHarness(() => Effect.gen(function* () {
    const runActivations = yield* TaskRunActivations
    const environments = yield* Environments
    const executor = yield* Executor
    const files = yield* Files
    const acquired = yield* bindWorkspace("task-environment")
    const firstRequest = activationRequest(acquired)
    const firstActivation = yield* runActivations.activate(firstRequest)
    assert.equal(firstActivation.activation.state, "active")
    assert.deepEqual(firstActivation.generationsToClose, [])

    const taskRun = { taskId: firstRequest.taskId, runId: firstRequest.runId }
    const first = yield* environments.ensure({ environmentKey: firstRequest.environmentKey, taskRun })
    yield* files.write({
      environmentKey: first.environmentKey,
      generation: first.generation,
      taskRun,
      path: "/workspace/retained.txt",
      dataBase64: Buffer.from("retained").toString("base64")
    })

    const consumed = yield* runActivations.consume({
      environmentKey: firstRequest.environmentKey,
      ...taskRun
    })
    assert.equal(consumed.activation.state, "consumed")
    assert.deepEqual(consumed.generationToClose, {
      environmentKey: first.environmentKey,
      generation: first.generation
    })
    yield* environments.closeForFence(consumed.generationToClose)

    const staleEnsure = yield* Effect.flip(environments.ensure({
      environmentKey: firstRequest.environmentKey,
      taskRun
    }))
    assert.equal(staleEnsure.reason, "run_activation.stale")

    const staleFile = yield* Effect.flip(files.read({
      environmentKey: first.environmentKey,
      generation: first.generation,
      taskRun,
      path: "/workspace/retained.txt"
    }))
    assert.equal(staleFile.reason, "run_activation.stale")

    const staleExec = yield* Effect.flip(Stream.runCollect(executor.execute({
      environmentKey: first.environmentKey,
      generation: first.generation,
      taskRun,
      argv: ["true"]
    })))
    assert.equal(staleExec.reason, "run_activation.stale")
  }))
})

test("newer task-run activation recreates the VM and supersedes older runs", async () => {
  await withHarness(() => Effect.gen(function* () {
    const runActivations = yield* TaskRunActivations
    const environments = yield* Environments
    const executor = yield* Executor
    const files = yield* Files
    const acquired = yield* bindWorkspace("task-environment")
    const firstRequest = activationRequest(acquired)
    yield* runActivations.activate(firstRequest)
    const firstTaskRun = { taskId: firstRequest.taskId, runId: firstRequest.runId }
    const first = yield* environments.ensure({ environmentKey: firstRequest.environmentKey, taskRun: firstTaskRun })
    const repeatedActivation = yield* runActivations.activate(firstRequest)
    assert.equal(repeatedActivation.activation.activationId, (yield* runActivations.validate(
      firstRequest.environmentKey,
      firstTaskRun
    )).activationId)
    assert.deepEqual(repeatedActivation.generationsToClose, [])
    const reused = yield* environments.ensure({ environmentKey: firstRequest.environmentKey, taskRun: firstTaskRun })
    assert.equal(reused.generation, first.generation)

    const secondRequest = activationRequest(acquired, { runId: "run-b" })
    const secondActivation = yield* runActivations.activate(secondRequest)
    assert.equal(secondActivation.activation.state, "active")
    assert.deepEqual(secondActivation.generationsToClose, [{
      environmentKey: first.environmentKey,
      generation: first.generation
    }])
    yield* environments.closeForFence(secondActivation.generationsToClose[0])

    const oldRun = yield* Effect.flip(environments.ensure({
      environmentKey: first.environmentKey,
      taskRun: firstTaskRun
    }))
    assert.equal(oldRun.reason, "run_activation.stale")

    const missingIdentity = yield* Effect.flip(environments.ensure({ environmentKey: first.environmentKey }))
    assert.equal(missingIdentity.reason, "run_activation.stale")

    const secondTaskRun = { taskId: secondRequest.taskId, runId: secondRequest.runId }
    const second = yield* environments.ensure({ environmentKey: secondRequest.environmentKey, taskRun: secondTaskRun })
    assert.ok(second.generation > first.generation)
    assert.equal(second.workspaceId, first.workspaceId)
    assert.equal(second.workspaceLeaseId, first.workspaceLeaseId)

    yield* files.write({
      environmentKey: second.environmentKey,
      generation: second.generation,
      taskRun: secondTaskRun,
      path: "/workspace/newer.txt",
      dataBase64: Buffer.from("newer").toString("base64")
    })
    const borrowedFile = yield* Effect.flip(files.read({
      environmentKey: second.environmentKey,
      generation: second.generation,
      taskRun: firstTaskRun,
      path: "/workspace/newer.txt"
    }))
    assert.equal(borrowedFile.reason, "run_activation.stale")
    const borrowedExec = yield* Effect.flip(Stream.runCollect(executor.execute({
      environmentKey: second.environmentKey,
      generation: second.generation,
      taskRun: firstTaskRun,
      argv: ["true"]
    })))
    assert.equal(borrowedExec.reason, "run_activation.stale")

    const thirdActivation = yield* runActivations.activate(
      activationRequest(acquired, { runId: "run-c" })
    )
    assert.equal(thirdActivation.activation.state, "active")
    assert.equal(thirdActivation.generationsToClose.length <= 1, true)
    const supersededSecond = yield* Effect.flip(runActivations.validate(
      second.environmentKey,
      secondTaskRun
    ))
    assert.equal(supersededSecond.reason, "run_activation.stale")
  }))
})

test("task-run activations persist across broker restart", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-task-run-persist-"))
  let request

  const firstHarness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const runActivations = yield* TaskRunActivations
    const acquired = yield* bindWorkspace("task-environment")
    request = activationRequest(acquired)
    yield* runActivations.activate(request)
  }).pipe(Effect.provide(firstHarness.layer))))

  const secondHarness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const runActivations = yield* TaskRunActivations
    const activation = yield* runActivations.validate(request.environmentKey, {
      taskId: request.taskId,
      runId: request.runId
    })
    assert.equal(activation.runId, request.runId)
    assert.equal(activation.state, "active")
  }).pipe(Effect.provide(secondHarness.layer))))
})
