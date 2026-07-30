import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { HandoffOperations } from "../dist/workspace-handoff/service.js"
import { InputPreparations } from "../dist/task-run-inputs/service.js"
import { ProjectWorkspaces } from "../dist/project-workspace/service.js"
import { TaskRunActivations } from "../dist/task-run-activations.js"
import { Workspaces } from "../dist/workspaces.js"
import { makePolicyFile, makeTestLayer, testTaskAuthority } from "./fakes.mjs"

const qtask = (board, task) => `b${board.length}:${board}:t${task.length}:${task}`
const qrun = (board, task, run) => `${qtask(board, task)}:r${run}`

const git = (repository, ...args) => execFileSync("git", args, {
  cwd: repository,
  encoding: "utf8",
  stdio: ["ignore", "pipe", "pipe"],
}).trim()

test("pre-created Project implementation, review, and revision consume frozen outputs", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-project-input-smoke-"))
  const repository = path.join(stateDir, "upstream")
  await mkdir(repository)
  git(repository, "init", "-q")
  git(repository, "config", "user.email", "smoke@example.invalid")
  git(repository, "config", "user.name", "Smoke Test")
  await writeFile(path.join(repository, "README.txt"), "canonical\n")
  git(repository, "add", "README.txt")
  git(repository, "commit", "-q", "-m", "canonical source")

  const basePolicy = makePolicyFile()
  const defaultRef = git(repository, "branch", "--show-current")
  const projectRevision = "2".repeat(64)
  const sourceRevision = "3".repeat(64)
  const providerRevision = "4".repeat(64)
  const policyFile = {
    worklanes: {
      ...basePolicy.worklanes,
      project: { ...basePolicy.worklanes.default },
    },
    laneAuthorities: {
      ...basePolicy.laneAuthorities,
      project: {
        authorityClass: "project",
        workspaceProvider: "broker-project",
        maximumPermission: "workspace-write",
      },
    },
    projectWorkspace: {
      provider: "broker-project",
      sourceRevisions: { local: sourceRevision },
      providerRevisions: { "broker-project": providerRevision },
      limits: {
        maxSourceBytes: 8 * 1024 * 1024,
        maxEntries: 1000,
        maxFileBytes: 1024 * 1024,
        maxPathBytes: 512,
        deadlineMs: 30_000,
        maxProjectWorkspaces: 8,
        maxStorageBytes: 64 * 1024 * 1024,
        retentionMs: 60_000,
      },
      sources: {
        local: { type: "git", upstream: repository, defaultRef },
      },
    },
  }
  const harness = makeTestLayer(stateDir, { workspaceHandoffEnabled: true, policyFile })

  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const projects = yield* ProjectWorkspaces
    const workspaces = yield* Workspaces
    const inputs = yield* InputPreparations
    const activations = yield* TaskRunActivations
    const handoffs = yield* HandoffOperations
    const source = yield* projects.resolveSource({
      project: "homelab",
      projectRevision,
      repositoryId: "local",
      sourceRevision,
    })

    const startTask = (task, run, boundInputs = []) => Effect.gen(function* () {
      const environmentKey = `project-${task}`
      const taskId = qtask("project-board", task)
      const runId = qrun("project-board", task, run)
      const acquired = yield* workspaces.acquire(environmentKey)
      const resolved = yield* workspaces.resolve(
        environmentKey,
        acquired.workspace.workspaceId,
        acquired.lease.leaseId,
      )
      const authority = testTaskAuthority({
        lane: "project",
        laneRevision: "5".repeat(64),
        project: "homelab",
        projectRevision,
        sourceGeneration: source.sourceGeneration,
        workspaceProvider: "broker-project",
        authorityClass: "project",
      })
      yield* projects.ensureMaterialized({
        environmentKey,
        taskId,
        runId,
        ...authority,
        workspaceId: acquired.workspace.workspaceId,
        workspaceLeaseId: acquired.lease.leaseId,
      }, resolved.workspacePath, acquired.lease.fencingToken)
      const prepared = yield* inputs.prepare({
        environmentKey,
        board: "project-board",
        taskId,
        runId,
        generation: 1,
        digest: "6".repeat(64),
        lane: "project",
        laneRevision: "5".repeat(64),
        policyRevision: "c".repeat(64),
        limits: {
          maxInputs: 8,
          maxInputBytes: 1024 * 1024,
          maxInputEntries: 1000,
          maxInputPathBytes: 512,
        },
        inputs: boundInputs,
      })
      yield* activations.activate({
        environmentKey,
        taskId,
        runId,
        ...authority,
        workspaceId: acquired.workspace.workspaceId,
        workspaceLeaseId: acquired.lease.leaseId,
        inputPreparationId: prepared.preparationId,
        inputGeneration: 1,
        inputDigest: "6".repeat(64),
      })
      yield* inputs.materialize({
        environmentKey,
        taskId,
        runId,
        ...authority,
        workspaceId: acquired.workspace.workspaceId,
        workspaceLeaseId: acquired.lease.leaseId,
        inputPreparationId: prepared.preparationId,
        inputGeneration: 1,
        inputDigest: "6".repeat(64),
      }, resolved.workspacePath)
      return { environmentKey, taskId, runId, resolved }
    })

    const finishTask = (task, artifactName, contents) => Effect.gen(function* () {
      yield* Effect.promise(() => writeFile(path.join(task.resolved.workspacePath, "output", artifactName), contents))
      return yield* handoffs.capture({
        finalizationId: `final-${task.taskId}`,
        environmentKey: task.environmentKey,
        taskId: task.taskId,
        runId: task.runId,
        selectedArtifacts: [],
      })
    })

    const implementation = yield* startTask("implementation", 1)
    assert.equal(
      yield* Effect.promise(() => readFile(path.join(implementation.resolved.workspacePath, "work", "README.txt"), "utf8")),
      "canonical\n",
    )
    const implementationOutput = yield* finishTask(implementation, "candidate.patch", "candidate\n")

    const implementationInput = {
      producerTaskId: implementation.taskId,
      producerRunId: implementation.runId,
      producerLane: "project",
      producerProject: "homelab",
      producerSourceGeneration: source.sourceGeneration,
      mountName: "implementation",
      handoffId: implementationOutput.handoffId,
    }
    const review = yield* startTask("review", 2, [implementationInput])
    assert.equal(
      yield* Effect.promise(() => readFile(path.join(review.resolved.workspacePath, "inputs", "implementation", "candidate.patch"), "utf8")),
      "candidate\n",
    )
    const reviewOutput = yield* finishTask(review, "review.txt", "changes-requested\n")

    const revision = yield* startTask("revision", 3, [{
      producerTaskId: review.taskId,
      producerRunId: review.runId,
      producerLane: "project",
      producerProject: "homelab",
      producerSourceGeneration: source.sourceGeneration,
      mountName: "review",
      handoffId: reviewOutput.handoffId,
    }])
    assert.equal(
      yield* Effect.promise(() => readFile(path.join(revision.resolved.workspacePath, "work", "README.txt"), "utf8")),
      "canonical\n",
    )
    assert.equal(
      yield* Effect.promise(() => readFile(path.join(revision.resolved.workspacePath, "inputs", "review", "review.txt"), "utf8")),
      "changes-requested\n",
    )
  }).pipe(Effect.provide(harness.layer))))
})
