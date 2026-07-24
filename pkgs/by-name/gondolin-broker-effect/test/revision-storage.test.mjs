import assert from "node:assert/strict"
import * as fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect, Exit, Layer } from "effect"
import { BrokerDatabase } from "../dist/database.js"
import { makeRevisionManifest } from "../dist/revision-manifest.js"
import { RevisionStorage, RevisionStorageLive } from "../dist/revision-storage.js"
import { RevisionStore } from "../dist/revision-store.js"
import { Registry } from "../dist/registry.js"
import { TaskRunActivations } from "../dist/task-run-activations.js"
import { Workspaces } from "../dist/workspaces.js"
import { makeTestLayer } from "./fakes.mjs"

const policyDigest = "a".repeat(64)
const decisionDigest = "b".repeat(64)
const defaultLimits = {
  maxLogicalBytes: 1024 * 1024,
  maxEntries: 100,
  maxFileBytes: 1024 * 1024,
  maxPathBytes: 256
}

const withStorage = async (run) => {
  const stateDir = await fs.mkdtemp(path.join(os.tmpdir(), "gondolin-revision-storage-"))
  const harness = makeTestLayer(stateDir)
  const layer = RevisionStorageLive.pipe(Layer.provideMerge(harness.layer))
  return Effect.runPromise(Effect.scoped(run(stateDir).pipe(Effect.provide(layer))))
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
    taskId: `task-${environmentKey}`,
    runId: `run-${environmentKey}`,
    workspaceId: acquired.workspace.workspaceId,
    workspaceLeaseId: acquired.lease.leaseId,
    policyDigest
  })
  const resolved = yield* workspaces.resolve(
    environmentKey,
    acquired.workspace.workspaceId,
    acquired.lease.leaseId
  )
  return { acquired: { ...acquired, workspacePath: resolved.workspacePath }, activation: activated.activation }
})

const stageRecord = (store, activation, selectedRoots, suffix = "a") => store.stagePublication({
  finalizationId: `finalization-${suffix}`,
  policyDecisionDigest: decisionDigest,
  sourceActivationId: activation.activationId,
  selectedRoots
})

const expectStorageFailure = (effect) => Effect.gen(function* () {
  const exit = yield* Effect.exit(effect)
  assert.equal(Exit.isFailure(exit), true)
})

test("manifest JSON has a stable domain-separated digest vector", () => {
  const entries = [
    { path: "readme.txt", kind: "file", mode: 0o644, byteLength: 5, contentDigest: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" },
    { path: "empty", kind: "directory", mode: 0o755, byteLength: 0, contentDigest: null },
    { path: "bin/run", kind: "file", mode: 0o755, byteLength: 3, contentDigest: "acba25512100f80b56c4550b8de3260d0cefc69c6462908337d8d1bda6f6f8d4" }
  ]
  assert.equal(
    makeRevisionManifest(entries).manifestDigest,
    "d596214fbba4e18c22f3a439d063155c95eaa1aab793d54ffed7f481c899f6ca"
  )
})

test("selected files become one verified revision under concurrent replay", async () => {
  await withStorage(() => Effect.gen(function* () {
    const store = yield* RevisionStore
    const storage = yield* RevisionStorage
    const { acquired, activation } = yield* bindAndActivate()
    yield* Effect.promise(() => fs.mkdir(path.join(acquired.workspacePath, "bin")))
    yield* Effect.promise(() => fs.writeFile(path.join(acquired.workspacePath, "bin", "run"), "run"))
    yield* Effect.promise(() => fs.chmod(path.join(acquired.workspacePath, "bin", "run"), 0o700))
    yield* Effect.promise(() => fs.writeFile(path.join(acquired.workspacePath, "ignored"), "secret"))
    const staged = stageRecord(store, activation, ["bin/run"])

    const [left, right] = yield* Effect.all([
      storage.stageRevision(staged.revisionId, acquired.workspacePath, defaultLimits),
      storage.stageRevision(staged.revisionId, acquired.workspacePath, defaultLimits)
    ], { concurrency: "unbounded" })
    assert.equal(left.revisionId, right.revisionId)
    assert.equal(left.state, "ready")
    const verified = yield* storage.verifyRevision(left.revisionId)
    assert.deepEqual(verified.entries.map((entry) => entry.path), ["bin", "bin/run"])
    assert.equal(verified.entries[1].mode, 0o755)
  }))
})

test("publication and imports are independent byte copies", async () => {
  await withStorage(() => Effect.gen(function* () {
    const store = yield* RevisionStore
    const storage = yield* RevisionStorage
    const { acquired, activation } = yield* bindAndActivate("copies")
    const source = path.join(acquired.workspacePath, "source")
    const linked = path.join(acquired.workspacePath, "linked")
    yield* Effect.promise(async () => {
      await fs.writeFile(source, "original")
      await fs.link(source, linked)
    })
    const ready = yield* storage.stageRevision(
      stageRecord(store, activation, ["source", "linked"], "copies").revisionId,
      acquired.workspacePath,
      defaultLimits
    )
    yield* Effect.promise(() => fs.writeFile(source, "changed"))

    const first = path.join(acquired.workspacePath, "..", "first-copy")
    const second = path.join(acquired.workspacePath, "..", "second-copy")
    yield* Effect.promise(() => Promise.all([fs.mkdir(first), fs.mkdir(second)]))
    yield* storage.materializeRevision(ready.revisionId, first)
    yield* storage.materializeRevision(ready.revisionId, second)
    assert.equal(yield* Effect.promise(() => fs.readFile(path.join(first, "source"), "utf8")), "original")
    assert.equal((yield* Effect.promise(() => fs.stat(path.join(first, "source")))).nlink, 1)
    yield* Effect.promise(() => fs.writeFile(path.join(first, "source"), "private"))
    assert.equal(yield* Effect.promise(() => fs.readFile(path.join(second, "source"), "utf8")), "original")
  }))
})

test("unsafe nodes and every broker-enforced limit fail closed", async (t) => {
  const cases = [
    ["symbolic link", async (root) => {
      await fs.writeFile(path.join(root, "target"), "data")
      await fs.symlink("target", path.join(root, "selected"))
    }, ["selected"], {}],
    ["overlapping roots", async (root) => {
      await fs.mkdir(path.join(root, "dir"))
      await fs.writeFile(path.join(root, "dir", "file"), "x")
    }, ["dir", "dir/file"], {}],
    ["file bytes", async (root) => fs.writeFile(path.join(root, "file"), "four"), ["file"], { maxFileBytes: 3 }],
    ["logical bytes", async (root) => {
      await fs.writeFile(path.join(root, "a"), "aa")
      await fs.writeFile(path.join(root, "b"), "bb")
    }, ["."], { maxLogicalBytes: 3 }],
    ["entries", async (root) => {
      await fs.mkdir(path.join(root, "dir"))
      await fs.writeFile(path.join(root, "dir", "file"), "x")
    }, ["dir"], { maxEntries: 1 }],
    ["path bytes", async (root) => fs.writeFile(path.join(root, "lengthy"), "x"), ["lengthy"], { maxPathBytes: 3 }]
  ]
  for (const [name, arrange, roots, override] of cases) {
    await t.test(name, async () => {
      await withStorage(() => Effect.gen(function* () {
        const store = yield* RevisionStore
        const storage = yield* RevisionStorage
        const key = name.replaceAll(" ", "-")
        const { acquired, activation } = yield* bindAndActivate(key)
        yield* Effect.promise(() => arrange(acquired.workspacePath))
        const staged = stageRecord(store, activation, roots, key)
        yield* expectStorageFailure(storage.stageRevision(
          staged.revisionId,
          acquired.workspacePath,
          { ...defaultLimits, ...override }
        ))
        assert.notEqual(store.getRevision(staged.revisionId).state, "ready")
      }))
    })
  }
})

test("copier and database failures remain recoverable", async (t) => {
  await t.test("copier failure quarantines partial state", async () => {
    await withStorage(() => Effect.gen(function* () {
      const store = yield* RevisionStore
      const storage = yield* RevisionStorage
      const { acquired, activation } = yield* bindAndActivate("copier-failure")
      const selected = path.join(acquired.workspacePath, "selected")
      yield* Effect.promise(async () => {
        await fs.writeFile(selected, "unreadable")
        await fs.chmod(selected, 0)
      })
      const staged = stageRecord(store, activation, ["selected"], "copier-failure")
      yield* expectStorageFailure(storage.stageRevision(staged.revisionId, acquired.workspacePath, defaultLimits))
      assert.equal(store.getRevision(staged.revisionId).state, "quarantined")
    }))
  })

  await t.test("database failure after rename is recovered idempotently", async () => {
    await withStorage(() => Effect.gen(function* () {
      const database = yield* BrokerDatabase
      const store = yield* RevisionStore
      const storage = yield* RevisionStorage
      const { acquired, activation } = yield* bindAndActivate("database-failure")
      yield* Effect.promise(() => fs.writeFile(path.join(acquired.workspacePath, "file"), "data"))
      const staged = stageRecord(store, activation, ["file"], "database-failure")
      database.connection.exec(`
        CREATE TRIGGER inject_revision_ready_failure
        BEFORE UPDATE OF state ON workspace_revisions
        WHEN NEW.state = 'ready'
        BEGIN SELECT RAISE(ABORT, 'injected database failure'); END;
      `)
      yield* expectStorageFailure(storage.stageRevision(staged.revisionId, acquired.workspacePath, defaultLimits))
      assert.equal(store.getRevision(staged.revisionId).state, "staging")
      database.connection.exec("DROP TRIGGER inject_revision_ready_failure")
      yield* storage.reconcile()
      assert.equal(store.getRevision(staged.revisionId).state, "ready")
      yield* storage.verifyRevision(staged.revisionId)
    }))
  })
})

test("reconciliation quarantines interrupted staging and tampered ready trees", async () => {
  await withStorage((stateDir) => Effect.gen(function* () {
    const store = yield* RevisionStore
    const storage = yield* RevisionStorage
    const interrupted = yield* bindAndActivate("interrupted")
    const staged = stageRecord(store, interrupted.activation, ["file"], "interrupted")
    yield* Effect.promise(() => fs.mkdir(
      path.join(stateDir, "workspace-revisions", "staging", staged.revisionId),
      { recursive: true }
    ))
    yield* storage.reconcile()
    assert.equal(store.getRevision(staged.revisionId).state, "quarantined")

    const tampering = yield* bindAndActivate("tampering")
    yield* Effect.promise(() => fs.writeFile(path.join(tampering.acquired.workspacePath, "file"), "safe"))
    const ready = yield* storage.stageRevision(
      stageRecord(store, tampering.activation, ["file"], "tampering").revisionId,
      tampering.acquired.workspacePath,
      defaultLimits
    )
    const stored = path.join(stateDir, "workspace-revisions", "ready", ready.revisionId, "tree", "file")
    yield* Effect.promise(async () => {
      await fs.chmod(stored, 0o644)
      await fs.writeFile(stored, "evil")
    })
    yield* expectStorageFailure(storage.verifyRevision(ready.revisionId))
    yield* storage.reconcile()
    assert.equal(store.getRevision(ready.revisionId).state, "quarantined")
  }))
})
