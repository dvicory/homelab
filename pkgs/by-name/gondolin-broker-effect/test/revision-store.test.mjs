import assert from "node:assert/strict"
import { mkdtemp } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect, Schema } from "effect"
import { BrokerDatabase } from "../dist/database.js"
import {
  StageWorkspacePublication,
  WorkspaceRevisionEntry
} from "../dist/revision-domain.js"
import { Registry } from "../dist/registry.js"
import { RevisionStore } from "../dist/revision-store.js"
import { TaskRunActivations } from "../dist/task-run-activations.js"
import { Workspaces } from "../dist/workspaces.js"
import { makeTestLayer } from "./fakes.mjs"

const policyDigest = "a".repeat(64)
const decisionDigest = "b".repeat(64)
const requestDigest = "c".repeat(64)
const relationDigest = "d".repeat(64)
const manifestDigest = "e".repeat(64)

const withHarness = async (run) => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-revision-store-"))
  const harness = makeTestLayer(stateDir)
  return Effect.runPromise(Effect.scoped(run.pipe(Effect.provide(harness.layer))))
}

const bindAndActivate = (environmentKey = "producer-environment") => Effect.gen(function* () {
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
  const activated = yield* activations.activate({
    environmentKey,
    taskId: "producer-task",
    runId: "producer-run",
    workspaceId: acquired.workspace.workspaceId,
    workspaceLeaseId: acquired.lease.leaseId,
    policyDigest,
    epoch: 1
  })
  return { acquired, activation: activated.activation }
})

const publicationRequest = (activation, overrides = {}) => ({
  finalizationId: "finalization-a",
  requestDigest,
  policyDecisionDigest: decisionDigest,
  sourceActivationId: activation.activationId,
  selectedRoots: ["output", "manifest.json"],
  canonicalizationVersion: 1,
  ...overrides
})

const throwsReason = (operation, reason) => assert.throws(
  operation,
  (error) => error?.reason === reason
)

test("revision domain schemas reject unsafe and inexact values", () => {
  const decodePublication = Schema.decodeUnknownSync(StageWorkspacePublication, { onExcessProperty: "error" })
  const decodeEntry = Schema.decodeUnknownSync(WorkspaceRevisionEntry, { onExcessProperty: "error" })
  const valid = {
    finalizationId: "finalization-a",
    requestDigest,
    policyDecisionDigest: decisionDigest,
    sourceActivationId: "00000000-0000-4000-8000-000000000001",
    selectedRoots: ["output", "."],
    canonicalizationVersion: 1
  }
  assert.deepEqual(decodePublication(valid), valid)
  assert.throws(() => decodePublication({ ...valid, selectedRoots: ["../secret"] }))
  assert.throws(() => decodePublication({ ...valid, selectedRoots: ["e\u0301"] }))
  assert.throws(() => decodePublication({ ...valid, unexpected: true }))
  assert.throws(() => decodeEntry({
    path: "directory",
    kind: "directory",
    mode: 0o644,
    byteLength: 0,
    contentDigest: null
  }))
  assert.throws(() => decodeEntry({
    path: "file.txt",
    kind: "file",
    mode: 0o644,
    byteLength: 1,
    contentDigest: null
  }))
})

test("clean broker initialization creates strict revision tables", async () => {
  await withHarness(Effect.gen(function* () {
    const database = yield* BrokerDatabase
    const names = database.connection.prepare(`
      SELECT name FROM sqlite_schema
      WHERE type='table' AND name LIKE 'workspace_revision%'
      ORDER BY name
    `).all().map((row) => row.name)
    assert.deepEqual(names, [
      "workspace_revision_entries",
      "workspace_revision_imports",
      "workspace_revision_operations",
      "workspace_revisions"
    ])
    const revisionColumns = database.connection.prepare("PRAGMA table_info(workspace_revisions)").all()
    assert.equal(revisionColumns.some((column) => column.name === "source_lease_fencing_token"), true)
    assert.equal(revisionColumns.some((column) => column.name === "policy_decision_digest"), true)
  }))
})

test("publication persistence is idempotent and transition checked", async () => {
  await withHarness(Effect.gen(function* () {
    const store = yield* RevisionStore
    const database = yield* BrokerDatabase
    const { activation } = yield* bindAndActivate()
    const request = publicationRequest(activation)
    const staged = store.stagePublication(request)
    assert.equal(staged.state, "staging")
    assert.equal(staged.sourceTaskId, "producer-task")
    assert.equal(staged.sourceRunId, "producer-run")
    assert.equal(staged.sourceEpoch, 1)
    assert.deepEqual(staged.selectedRoots, ["manifest.json", "output"])

    const replay = store.stagePublication({
      ...request,
      selectedRoots: ["manifest.json", "output"]
    })
    assert.equal(replay.revisionId, staged.revisionId)
    throwsReason(
      () => store.stagePublication({ ...request, requestDigest: "f".repeat(64) }),
      "revision.conflict"
    )
    throwsReason(
      () => store.stagePublication({ ...request, finalizationId: "finalization-b" }),
      "revision.conflict"
    )

    const ready = store.markRevisionReady(staged.revisionId, manifestDigest, 2, 11, 11)
    assert.equal(ready.state, "ready")
    assert.equal(ready.manifestDigest, manifestDigest)
    assert.equal(store.markRevisionReady(staged.revisionId, manifestDigest, 2, 11, 11).state, "ready")
    throwsReason(
      () => store.markRevisionReady(staged.revisionId, manifestDigest, 3, 11, 11),
      "revision.conflict"
    )
    throwsReason(() => store.failRevision(staged.revisionId, "failed", "late failure"), "revision.invalid_state")

    const quarantined = store.failRevision(staged.revisionId, "quarantined", "verification mismatch")
    assert.equal(quarantined.state, "quarantined")
    assert.equal(quarantined.failureReason, "verification mismatch")
    const operation = database.connection.prepare(
      "SELECT state, failure_reason FROM workspace_revision_operations WHERE operation_id=?"
    ).get(request.finalizationId)
    assert.equal(operation.state, "failed")
    assert.equal(operation.failure_reason, "verification mismatch")
  }))
})

test("private import binds request identity and one destination run", async () => {
  await withHarness(Effect.gen(function* () {
    const store = yield* RevisionStore
    const workspaces = yield* Workspaces
    const { activation } = yield* bindAndActivate()
    const revision = store.stagePublication(publicationRequest(activation))
    store.markRevisionReady(revision.revisionId, manifestDigest, 0, 0, 0)
    const request = {
      preparationId: "preparation-a",
      requestDigest,
      policyDecisionDigest: decisionDigest,
      sourceRevisionId: revision.revisionId,
      destinationTaskId: "consumer-task",
      destinationRunId: "consumer-run",
      destinationEnvironmentKey: "consumer-environment",
      sourcePolicyDigest: policyDigest,
      destinationPolicyDigest: policyDigest,
      relationDigest
    }
    const staged = store.stageImport(request)
    assert.equal(staged.state, "staging")
    assert.equal(staged.sourceTaskId, "producer-task")
    assert.equal(staged.sourceRunId, "producer-run")
    assert.equal(store.stageImport(request).preparationId, request.preparationId)
    throwsReason(
      () => store.stageImport({ ...request, relationDigest: "f".repeat(64) }),
      "revision.conflict"
    )
    throwsReason(
      () => store.stageImport({ ...request, preparationId: "preparation-b" }),
      "revision.conflict"
    )

    const destination = yield* workspaces.acquire(request.destinationEnvironmentKey)
    const completed = store.completeImport({
      preparationId: request.preparationId,
      destinationWorkspaceId: destination.workspace.workspaceId,
      destinationWorkspaceLeaseId: destination.lease.leaseId
    })
    assert.equal(completed.state, "ready")
    assert.equal(completed.destinationLeaseFencingToken, destination.lease.fencingToken)
    assert.equal(store.completeImport({
      preparationId: request.preparationId,
      destinationWorkspaceId: destination.workspace.workspaceId,
      destinationWorkspaceLeaseId: destination.lease.leaseId
    }).state, "ready")
    throwsReason(() => store.failImport(request.preparationId, "late failure"), "revision.invalid_state")
  }))
})
