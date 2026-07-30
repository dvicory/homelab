import assert from "node:assert/strict"
import { access, chmod, link, mkdir, mkdtemp, open, readFile, readdir, rename, rm, stat, symlink, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { BrokerDatabase } from "../dist/database.js"
import { Environments } from "../dist/environments.js"
import { Files } from "../dist/files.js"
import { HandoffOperations } from "../dist/workspace-handoff/service.js"
import { InputPreparations } from "../dist/task-run-inputs/service.js"
import { TaskRunActivations } from "../dist/task-run-activations.js"
import { Workspaces } from "../dist/workspaces.js"
import { makePolicyFile, makeTestLayer, testTaskAuthority } from "./fakes.mjs"

const run = async (stateDir, callback, options = {}) => {
  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true, ...options })
  return Effect.runPromise(Effect.scoped(callback.pipe(Effect.provide(harness.layer))))
}
const qtask = (board, task) => `b${board.length}:${board}:t${task.length}:${task}`
const qrun = (board, task, run) => `${qtask(board, task)}:r${run}`

const request = (overrides = {}) => ({
  environmentKey: "input-board",
  board: "input-board",
  taskId: qtask("input-board", "consumer"),
  runId: qrun("input-board", "consumer", 7),
  generation: 1,
  digest: "a".repeat(64),
  lane: "default",
  laneRevision: "b".repeat(64),
  policyRevision: "c".repeat(64),
  limits: { maxInputs: 8, maxInputBytes: 1000, maxInputEntries: 100, maxInputPathBytes: 4096 },
  inputs: [],
  ...overrides,
})
const capture = (board, task, runId, files = {}, authority = {}) => Effect.gen(function* () {
  const environmentKey = `producer-${task}`
  const taskId = qtask(board, task)
  const qualifiedRunId = qrun(board, task, runId)
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
    runId: qualifiedRunId,
    ...testTaskAuthority(authority),
    workspaceId: acquired.workspace.workspaceId,
    workspaceLeaseId: acquired.lease.leaseId,
  })
  for (const [relative, contents] of Object.entries(files)) {
    const destination = path.join(resolved.workspacePath, "output", relative)
    yield* Effect.promise(() => mkdir(path.dirname(destination), { recursive: true }))
    yield* Effect.promise(() => writeFile(destination, contents))
  }
  const handoffs = yield* HandoffOperations
  const captured = yield* handoffs.capture({
    finalizationId: `final-${task}-${runId}`,
    environmentKey,
    taskId,
    runId: qualifiedRunId,
    selectedArtifacts: [],
  })
  return { ...captured, producerWorkspaceId: acquired.workspace.workspaceId }
})

const inputFor = (board, task, runId, handoffId, producerLane = "default") => ({
  producerTaskId: qtask(board, task),
  producerRunId: qrun(board, task, runId),
  producerLane,
  mountName: task,
  handoffId,
})
const materializePrepared = (board, task, runId, boundInputs) => Effect.gen(function* () {
  const environmentKey = `destination-${task}`
  const taskId = qtask(board, task)
  const qualifiedRunId = qrun(board, task, runId)
  const inputPreparations = yield* InputPreparations
  const prepared = yield* inputPreparations.prepare(request({
    environmentKey,
    board,
    taskId,
    runId: qualifiedRunId,
    inputs: boundInputs,
  }))
  const workspaces = yield* Workspaces
  const acquired = yield* workspaces.acquire(environmentKey)
  const resolved = yield* workspaces.resolve(
    environmentKey,
    acquired.workspace.workspaceId,
    acquired.lease.leaseId,
  )
  yield* inputPreparations.materialize({
    environmentKey,
    taskId,
    runId: qualifiedRunId,
    ...testTaskAuthority(),
    workspaceId: acquired.workspace.workspaceId,
    workspaceLeaseId: acquired.lease.leaseId,
    inputPreparationId: prepared.preparationId,
    inputGeneration: 1,
    inputDigest: "a".repeat(64),
  }, resolved.workspacePath)
  return { prepared, workspacePath: resolved.workspacePath }
})

test("empty input preparation replays and conflicts on changed facts", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-inputs-empty-"))
  await run(stateDir, Effect.gen(function* () {
    const inputs = yield* InputPreparations
    const first = yield* inputs.prepare(request())
    const replay = yield* inputs.prepare(request())
    assert.equal(replay.preparationId, first.preparationId)
    assert.deepEqual(replay.inputs, [])
    const changedFacts = [
      { environmentKey: "other-environment" },
      { board: "other-board" },
      { generation: 2 },
      { digest: "d".repeat(64) },
      { lane: "other-lane" },
      { laneRevision: "e".repeat(64) },
      { policyRevision: "f".repeat(64) },
      { limits: { ...request().limits, maxInputBytes: request().limits.maxInputBytes + 1 } },
      { inputs: [inputFor("input-board", "producer", 1, "changed-handoff")] },
    ]
    for (const changed of changedFacts) {
      const conflict = yield* Effect.flip(inputs.prepare(request(changed)))
      assert.equal(conflict.reason, "inputs.conflict")
    }
  }))
})

test("activation validates prepared generation and creates read-only inputs plane", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-inputs-activation-"))
  await run(stateDir, Effect.gen(function* () {
    const inputs = yield* InputPreparations
    const workspaces = yield* Workspaces
    const activations = yield* TaskRunActivations
    const prepared = yield* inputs.prepare(request())
    const acquired = yield* workspaces.acquire("input-board")
    const activation = yield* activations.activate({
      environmentKey: "input-board",
      taskId: qtask("input-board", "consumer"),
      runId: qrun("input-board", "consumer", 7),
      ...testTaskAuthority(),
      workspaceId: acquired.workspace.workspaceId,
      workspaceLeaseId: acquired.lease.leaseId,
      inputPreparationId: prepared.preparationId,
      inputGeneration: 1,
      inputDigest: "a".repeat(64),
    })
    assert.equal(activation.activation.taskId, qtask("input-board", "consumer"))
    const resolved = yield* workspaces.resolve("input-board", acquired.workspace.workspaceId, acquired.lease.leaseId)
    yield* inputs.materialize({
      environmentKey: "input-board",
      taskId: qtask("input-board", "consumer"),
      runId: qrun("input-board", "consumer", 7),
      ...testTaskAuthority(),
      workspaceId: acquired.workspace.workspaceId,
      workspaceLeaseId: acquired.lease.leaseId,
      inputPreparationId: prepared.preparationId,
      inputGeneration: 1,
      inputDigest: "a".repeat(64),
    }, resolved.workspacePath)
    const inputsStat = yield* Effect.promise(() => stat(path.join(resolved.workspacePath, "inputs")))
    assert.equal(inputsStat.isDirectory(), true)
    assert.equal(inputsStat.mode & 0o777, 0o550)
    const mismatch = yield* Effect.flip(activations.activate({
      environmentKey: "input-board",
      taskId: qtask("input-board", "other"),
      runId: qrun("input-board", "other", 8),
      ...testTaskAuthority(),
      workspaceId: acquired.workspace.workspaceId,
      workspaceLeaseId: acquired.lease.leaseId,
      inputPreparationId: prepared.preparationId,
      inputGeneration: 1,
      inputDigest: "a".repeat(64),
    }))
    assert.equal(mismatch.reason, "inputs.conflict")
    const staleRun = yield* Effect.flip(activations.activate({
      environmentKey: "input-board",
      taskId: qtask("input-board", "consumer"),
      runId: qrun("input-board", "consumer", 8),
      ...testTaskAuthority(),
      workspaceId: acquired.workspace.workspaceId,
      workspaceLeaseId: acquired.lease.leaseId,
      inputPreparationId: prepared.preparationId,
      inputGeneration: 1,
      inputDigest: "a".repeat(64),
    }))
    assert.equal(staleRun.reason, "inputs.conflict")
  }))
})

test("materialized inputs remain immutable through broker and host mutation paths", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-inputs-read-only-"))
  await run(stateDir, Effect.gen(function* () {
    const handoff = yield* capture("input-board", "producer", 3, {
      "nested/report.txt": "immutable report",
    })
    const inputs = yield* InputPreparations
    const prepared = yield* inputs.prepare(request({
      environmentKey: "destination-environment",
      inputs: [inputFor("input-board", "producer", 3, handoff.handoffId)],
    }))
    assert.deepEqual(prepared.inputs, [{
      producerTaskId: qtask("input-board", "producer"),
      mountName: "producer",
      guestPath: "/workspace/inputs/producer",
    }])

    const workspaces = yield* Workspaces
    const acquired = yield* workspaces.acquire("destination-environment")
    const resolved = yield* workspaces.resolve(
      "destination-environment",
      acquired.workspace.workspaceId,
      acquired.lease.leaseId,
    )
    const activationRequest = {
      environmentKey: "destination-environment",
      taskId: qtask("input-board", "consumer"),
      runId: qrun("input-board", "consumer", 7),
      ...testTaskAuthority(),
      workspaceId: acquired.workspace.workspaceId,
      workspaceLeaseId: acquired.lease.leaseId,
      inputPreparationId: prepared.preparationId,
      inputGeneration: 1,
      inputDigest: "a".repeat(64),
    }
    yield* inputs.materialize(activationRequest, resolved.workspacePath)
    const inputRoot = path.join(resolved.workspacePath, "inputs")
    const producerRoot = path.join(inputRoot, "producer")
    const nestedRoot = path.join(producerRoot, "nested")
    const report = path.join(nestedRoot, "report.txt")
    assert.equal(yield* Effect.promise(() => readFile(report, "utf8")), "immutable report")
    assert.equal((yield* Effect.promise(() => stat(inputRoot))).mode & 0o777, 0o550)
    assert.equal((yield* Effect.promise(() => stat(producerRoot))).mode & 0o777, 0o550)
    assert.equal((yield* Effect.promise(() => stat(nestedRoot))).mode & 0o777, 0o550)
    assert.equal((yield* Effect.promise(() => stat(report))).mode & 0o777, 0o440)

    yield* Effect.promise(() => assert.rejects(writeFile(report, "changed"), { code: "EACCES" }))
    yield* Effect.promise(() => assert.rejects(writeFile(path.join(inputRoot, "new.txt"), "new"), { code: "EACCES" }))
    yield* Effect.promise(() => assert.rejects(mkdir(path.join(inputRoot, "new-dir")), { code: "EACCES" }))
    yield* Effect.promise(() => assert.rejects(rename(report, path.join(nestedRoot, "moved.txt")), { code: "EACCES" }))
    yield* Effect.promise(() => assert.rejects(rm(report), { code: "EACCES" }))
    yield* Effect.promise(() => assert.rejects(link(report, path.join(inputRoot, "hard-link")), { code: "EACCES" }))
    yield* Effect.promise(() => assert.rejects(symlink(report, path.join(inputRoot, "symbolic-link")), { code: "EACCES" }))
    yield* Effect.promise(() => assert.rejects(open(report, "r+"), { code: "EACCES" }))
    const staleReadHandle = yield* Effect.promise(() => open(report, "r"))
    yield* Effect.promise(async () => {
      try {
        await assert.rejects(staleReadHandle.write("changed"), { code: "EBADF" })
      } finally {
        await staleReadHandle.close()
      }
    })

    const activations = yield* TaskRunActivations
    yield* activations.activate(activationRequest)
    const environments = yield* Environments
    const environment = yield* environments.ensure({
      environmentKey: activationRequest.environmentKey,
      taskRun: { taskId: activationRequest.taskId, runId: activationRequest.runId },
    })
    const fileService = yield* Files
    const reference = {
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      taskRun: { taskId: activationRequest.taskId, runId: activationRequest.runId },
    }
    for (const operation of [
      fileService.write({
        ...reference,
        path: "/workspace/inputs/producer/nested/report.txt",
        dataBase64: Buffer.from("changed").toString("base64"),
      }),
      fileService.mkdir({
        ...reference,
        path: "/workspace/inputs/producer/new-dir",
        recursive: true,
      }),
      fileService.remove({
        ...reference,
        path: "/workspace/inputs/producer/nested/report.txt",
        recursive: false,
      }),
    ]) {
      const denied = yield* Effect.flip(operation)
      assert.equal(denied.reason, "policy.denied")
    }
    assert.equal(yield* Effect.promise(() => readFile(report, "utf8")), "immutable report")
  }))
})

test("empty, fan-in, and shared-handoff fan-out materialize exact namespaces", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-inputs-graph-"))
  await run(stateDir, Effect.gen(function* () {
    const alpha = yield* capture("input-board", "alpha", 1, { "report.txt": "alpha" })
    const empty = yield* capture("input-board", "empty", 2)
    const shared = yield* capture("input-board", "shared", 3, { "same.txt": "shared" })

    const fanIn = yield* materializePrepared("input-board", "synthesis", 10, [
      inputFor("input-board", "alpha", 1, alpha.handoffId),
      inputFor("input-board", "empty", 2, empty.handoffId),
      inputFor("input-board", "shared", 3, shared.handoffId),
    ])
    assert.equal(
      yield* Effect.promise(() => readFile(path.join(fanIn.workspacePath, "inputs", "alpha", "report.txt"), "utf8")),
      "alpha",
    )
    assert.deepEqual(
      yield* Effect.promise(() => readdir(path.join(fanIn.workspacePath, "inputs", "empty"))),
      [],
    )
    assert.equal(
      yield* Effect.promise(() => readFile(path.join(fanIn.workspacePath, "inputs", "shared", "same.txt"), "utf8")),
      "shared",
    )

    const first = yield* materializePrepared("input-board", "consumer-a", 11, [
      inputFor("input-board", "shared", 3, shared.handoffId),
    ])
    const second = yield* materializePrepared("input-board", "consumer-b", 12, [
      inputFor("input-board", "shared", 3, shared.handoffId),
    ])
    assert.notEqual(first.prepared.preparationId, second.prepared.preparationId)
    assert.equal(
      yield* Effect.promise(() => readFile(path.join(first.workspacePath, "inputs", "shared", "same.txt"), "utf8")),
      "shared",
    )
    assert.equal(
      yield* Effect.promise(() => readFile(path.join(second.workspacePath, "inputs", "shared", "same.txt"), "utf8")),
      "shared",
    )
    assert.equal(
      yield* Effect.promise(() => readFile(
        path.join(stateDir, "workspace-handoffs", "ready", shared.handoffId, "output", "same.txt"),
        "utf8",
      )),
      "shared",
    )
  }))
})
test("cross-lane Project provenance does not transfer producer authority", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-input-cross-lane-"))
  const basePolicy = makePolicyFile()
  const policyFile = {
    worklanes: {
      ...basePolicy.worklanes,
      research: { ...basePolicy.worklanes.default },
      review: { ...basePolicy.worklanes.default },
    },
    laneAuthorities: {
      ...basePolicy.laneAuthorities,
      research: {
        authorityClass: "research",
        workspaceProvider: "broker-scratch",
        maximumPermission: "workspace-write",
      },
      review: {
        authorityClass: "review",
        workspaceProvider: "broker-scratch",
        maximumPermission: "workspace-write",
      },
    },
  }
  await run(stateDir, Effect.gen(function* () {
    const producer = yield* capture(
      "lane-board",
      "research",
      1,
      { "report.txt": "evidence" },
      { lane: "research", laneRevision: "d".repeat(64), authorityClass: "research" },
    )
    const database = yield* BrokerDatabase
    const row = database.connection.prepare(
      "SELECT authority_facts_json FROM workspace_handoffs WHERE handoff_id = ?",
    ).get(producer.handoffId)
    database.connection.prepare(
      "UPDATE workspace_handoffs SET authority_facts_json = ? WHERE handoff_id = ?",
    ).run(JSON.stringify({
      ...JSON.parse(row.authority_facts_json),
      project: "homelab",
      sourceGeneration: "source-generation-1",
    }), producer.handoffId)

    const inputs = yield* InputPreparations
    const taskId = qtask("lane-board", "review")
    const runId = qrun("lane-board", "review", 2)
    const boundInput = {
      ...inputFor("lane-board", "research", 1, producer.handoffId, "research"),
      producerProject: "homelab",
      producerSourceGeneration: "source-generation-1",
    }
    const prepared = yield* inputs.prepare(request({
      environmentKey: "destination-review",
      board: "lane-board",
      taskId,
      runId,
      lane: "review",
      laneRevision: "e".repeat(64),
      inputs: [boundInput],
    }))
    const workspaces = yield* Workspaces
    const acquired = yield* workspaces.acquire("destination-review")
    const resolved = yield* workspaces.resolve(
      "destination-review",
      acquired.workspace.workspaceId,
      acquired.lease.leaseId,
    )
    const activations = yield* TaskRunActivations
    const activated = yield* activations.activate({
      environmentKey: "destination-review",
      taskId,
      runId,
      ...testTaskAuthority({
        lane: "review",
        laneRevision: "e".repeat(64),
        authorityClass: "review",
      }),
      workspaceId: acquired.workspace.workspaceId,
      workspaceLeaseId: acquired.lease.leaseId,
      inputPreparationId: prepared.preparationId,
      inputGeneration: 1,
      inputDigest: "a".repeat(64),
    })
    yield* inputs.materialize({
      environmentKey: "destination-review",
      taskId,
      runId,
      ...activated.activation.authority,
      workspaceId: acquired.workspace.workspaceId,
      workspaceLeaseId: acquired.lease.leaseId,
      inputPreparationId: prepared.preparationId,
      inputGeneration: 1,
      inputDigest: "a".repeat(64),
    }, resolved.workspacePath)
    assert.equal(activated.activation.authority.lane, "review")
    assert.equal(activated.activation.authority.authorityClass, "review")
    assert.equal(activated.activation.authority.workspaceProvider, "broker-scratch")
    assert.equal(activated.activation.authority.project, undefined)
    assert.equal(activated.activation.authority.sourceGeneration, undefined)
    assert.notEqual(activated.activation.workspaceId, producer.producerWorkspaceId)
    assert.equal(
      yield* Effect.promise(() => readFile(
        path.join(resolved.workspacePath, "inputs", "research", "report.txt"),
        "utf8",
      )),
      "evidence",
    )
  }), { policyFile })
})


test("preparation enforces count, byte, entry, and path ceilings", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-input-limits-"))
  await run(stateDir, Effect.gen(function* () {
    const first = yield* capture("limit-board", "first", 1, {
      "one.txt": "12",
    })
    const second = yield* capture("limit-board", "second", 2, {
      "nested/long-name.txt": "345",
    })
    const inputs = yield* InputPreparations
    const bound = [
      inputFor("limit-board", "first", 1, first.handoffId),
      inputFor("limit-board", "second", 2, second.handoffId),
    ]
    const base = request({
      environmentKey: "limit-environment",
      board: "limit-board",
      taskId: qtask("limit-board", "consumer"),
      runId: qrun("limit-board", "consumer", 3),
      inputs: bound,
    })
    const ceilings = [
      { ...base.limits, maxInputs: 1 },
      { ...base.limits, maxInputBytes: 4 },
      { ...base.limits, maxInputEntries: 1 },
      { ...base.limits, maxInputPathBytes: 4 },
    ]
    for (const limits of ceilings) {
      const denied = yield* Effect.flip(inputs.prepare({ ...base, limits }))
      assert.equal(denied.reason, "inputs.limit")
    }
  }))
})

test("materialization cleans partial copies and identical preparation survives broker restart", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-input-restart-"))
  let preparationId
  const boundInputs = []
  await run(stateDir, Effect.gen(function* () {
    const first = yield* capture("restart-board", "first", 1, { "first.txt": "first" })
    const second = yield* capture("restart-board", "second", 2, { "second.txt": "second" })
    boundInputs.push(
      inputFor("restart-board", "first", 1, first.handoffId),
      inputFor("restart-board", "second", 2, second.handoffId),
    )
    const inputs = yield* InputPreparations
    const prepared = yield* inputs.prepare(request({
      environmentKey: "restart-environment",
      board: "restart-board",
      taskId: qtask("restart-board", "consumer"),
      runId: qrun("restart-board", "consumer", 3),
      inputs: boundInputs,
    }))
    preparationId = prepared.preparationId
  }))
  await run(stateDir, Effect.gen(function* () {
    const inputs = yield* InputPreparations
    const workspaces = yield* Workspaces
    const replay = yield* inputs.prepare(request({
      environmentKey: "restart-environment",
      board: "restart-board",
      taskId: qtask("restart-board", "consumer"),
      runId: qrun("restart-board", "consumer", 3),
      inputs: boundInputs,
    }))
    assert.equal(replay.preparationId, preparationId)
    const acquired = yield* workspaces.acquire("restart-environment")
    const resolved = yield* workspaces.resolve(
      "restart-environment",
      acquired.workspace.workspaceId,
      acquired.lease.leaseId,
    )
    const missingOutput = path.join(
      stateDir,
      "workspace-handoffs",
      "ready",
      boundInputs[1].handoffId,
      "output",
    )
    yield* Effect.promise(() => chmod(missingOutput, 0o750))
    yield* Effect.promise(() => chmod(path.join(missingOutput, "second.txt"), 0o640))
    yield* Effect.promise(() => rm(missingOutput, { recursive: true }))
    const failed = yield* Effect.flip(inputs.materialize({
      environmentKey: "restart-environment",
      taskId: qtask("restart-board", "consumer"),
      runId: qrun("restart-board", "consumer", 3),
      ...testTaskAuthority(),
      workspaceId: acquired.workspace.workspaceId,
      workspaceLeaseId: acquired.lease.leaseId,
      inputPreparationId: replay.preparationId,
      inputGeneration: 1,
      inputDigest: "a".repeat(64),
    }, resolved.workspacePath))
    assert.equal(failed.reason, "handoff.failed")
    const inputsRoot = path.join(resolved.workspacePath, "inputs")
    assert.deepEqual(yield* Effect.promise(() => readdir(inputsRoot)), [])
    assert.equal((yield* Effect.promise(() => stat(inputsRoot))).mode & 0o777, 0o550)
  }))
})
