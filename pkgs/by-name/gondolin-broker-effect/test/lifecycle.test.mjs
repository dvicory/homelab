import assert from "node:assert/strict"
import { DatabaseSync } from "node:sqlite"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect, Exit, Stream } from "effect"
import { AccessGrants } from "../dist/grants.js"
import { Environments } from "../dist/environments.js"
import { Executor } from "../dist/exec.js"
import { Files } from "../dist/files.js"
import { EnsureRequest, decodeExact } from "../dist/domain.js"
import { Registry } from "../dist/registry.js"
import { makeTestLayer } from "./fakes.mjs"

const withHarness = async (run, options) => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-test-"))
  const harness = makeTestLayer(stateDir, options)
  return Effect.runPromise(Effect.scoped(run(harness).pipe(Effect.provide(harness.layer))))
}

test("ensure reuses a compatible live generation and increments after close", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    const first = yield* environments.ensure({ environmentKey: "conversation-a" })
    const reused = yield* environments.ensure({ environmentKey: "conversation-a" })
    assert.equal(first.state, "created")
    assert.equal(reused.state, "reused")
    assert.equal(reused.generation, first.generation)
    assert.deepEqual(harness.fake.state.created[0].spec.network, {
      mode: "deny-all",
      destinations: []
    })

    yield* environments.close({ environmentKey: first.environmentKey, generation: first.generation })
    const next = yield* environments.ensure({ environmentKey: "conversation-a" })
    assert.equal(next.generation, first.generation + 1)
  }))
})

test("an existing VM observes approval and revocation through its live grant view", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    const grants = yield* AccessGrants
    const environment = yield* environments.ensure({ environmentKey: "conversation-live-network" })
    const dynamic = harness.fake.state.created[0].spec.dynamicNetwork

    assert.ok(dynamic)
    assert.deepEqual(dynamic.activeGrants(), [])
    const prepared = yield* grants.prepare({
      environmentKey: environment.environmentKey,
      capabilities: [{
        version: 1,
        kind: "network-origin",
        scheme: "https",
        host: "api.example.com",
        addressMode: "public"
      }],
      requestedScope: "task"
    })
    const approved = yield* grants.decide({
      requestId: prepared.requestId,
      decision: "approve",
      principal: "operator"
    })

    assert.equal(dynamic.activeGrants().length, 1)
    yield* grants.revoke(approved.grantIds[0], "operator")
    assert.deepEqual(dynamic.activeGrants(), [])
    assert.equal(harness.fake.state.created.length, 1)
  }), {
    grantResolver: async () => [{ address: "93.184.216.34", family: 4 }]
  })
})

test("ensure binds broker-owned default authority and rejects conflicts", async () => {
  await withHarness(() => Effect.gen(function* () {
    const environments = yield* Environments
    const registry = yield* Registry
    const ensured = yield* environments.ensure({ environmentKey: "conversation-authority" })

    assert.equal(ensured.profile, "test")
    assert.equal(ensured.executor, "hermes-gateway")
    assert.equal(ensured.authorityClass, "default")
    assert.equal(ensured.policyDigest, "a".repeat(64))

    const binding = yield* registry.getAuthority("conversation-authority")
    assert.equal(binding.profile, "test")
    assert.equal(binding.executor, "hermes-gateway")
    assert.equal(binding.authorityClass, "default")

    const conflict = yield* Effect.flip(registry.bindAuthority({
      environmentKey: "conversation-authority",
      profile: "test",
      executor: "different-executor",
      authorityClass: "default",
      policyDigest: "a".repeat(64)
    }))
    assert.equal(conflict.reason, "authority.conflict")
  }))
})

test("authority bindings persist across broker registry restarts", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-authority-test-"))
  const request = {
    environmentKey: "conversation-persisted",
    profile: "test",
    executor: "hermes-gateway",
    authorityClass: "default",
    policyDigest: "a".repeat(64)
  }

  const first = makeTestLayer(stateDir)
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    yield* registry.bindAuthority(request)
  }).pipe(Effect.provide(first.layer))))

  const second = makeTestLayer(stateDir)
  const binding = await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    return yield* registry.getAuthority(request.environmentKey)
  }).pipe(Effect.provide(second.layer))))

  assert.equal(binding.profile, request.profile)
  assert.equal(binding.executor, request.executor)
  assert.equal(binding.authorityClass, request.authorityClass)
  assert.equal(binding.policyDigest, request.policyDigest)
})

test("legacy numeric policy state is discarded without deleting workspaces", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-policy-digest-migration-"))
  const workspaceFile = path.join(stateDir, "workspaces", "legacy", "fixture.txt")
  await mkdir(path.dirname(workspaceFile), { recursive: true })
  await writeFile(workspaceFile, "preserved")
  const databasePath = path.join(stateDir, "broker.sqlite")
  const legacy = new DatabaseSync(databasePath)
  legacy.exec(`
    CREATE TABLE environments (environment_key TEXT PRIMARY KEY, policy_generation INTEGER) STRICT;
    CREATE TABLE authority_bindings (environment_key TEXT PRIMARY KEY, policy_generation INTEGER) STRICT;
    CREATE TABLE access_requests (request_id TEXT PRIMARY KEY, policy_generation INTEGER) STRICT;
    CREATE TABLE runtime_grants (grant_id TEXT PRIMARY KEY, policy_generation INTEGER) STRICT;
  `)
  legacy.close()

  const harness = makeTestLayer(stateDir)
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    yield* AccessGrants
    const binding = yield* registry.bindAuthority({
      environmentKey: "digest-migrated",
      profile: "test",
      executor: "hermes-gateway",
      authorityClass: "default",
      policyDigest: "a".repeat(64)
    })
    assert.equal(binding.policyDigest, "a".repeat(64))
  }).pipe(Effect.provide(harness.layer))))

  const migrated = new DatabaseSync(databasePath)
  for (const table of ["environments", "authority_bindings", "access_requests", "runtime_grants"]) {
    const columns = migrated.prepare(`SELECT name FROM pragma_table_info('${table}')`).all().map((row) => row.name)
    assert.equal(columns.includes("policy_generation"), false)
    assert.equal(columns.includes("policy_digest"), true)
  }
  migrated.close()
  assert.equal(await readFile(workspaceFile, "utf8"), "preserved")
})

test("ordinary ensure input rejects caller-selected authority", async () => {
  await assert.rejects(
    Effect.runPromise(decodeExact(EnsureRequest, {
      environmentKey: "conversation-authority",
      worklane: "codex"
    }))
  )
})

test("stale generations are rejected after recreation", async () => {
  await withHarness(() => Effect.gen(function* () {
    const environments = yield* Environments
    const first = yield* environments.ensure({ environmentKey: "conversation-a" })
    yield* environments.close({ environmentKey: first.environmentKey, generation: first.generation })
    const next = yield* environments.ensure({ environmentKey: "conversation-a" })
    const result = yield* Effect.exit(environments.lease(first).pipe(Effect.scoped))
    assert.equal(Exit.isFailure(result), true)
    assert.equal(next.generation, 2)
  }))
})

test("missing policy allow fails closed before VM creation", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    const error = yield* Effect.flip(environments.ensure({ environmentKey: "conversation-denied" }))
    assert.equal(error.reason, "policy.denied")
    assert.equal(harness.fake.state.created.length, 0)
  }), {
    policyFile: { policy: { version: 1, statements: [] } }
  })
})

test("ensure requires one resolvable policy-authorized network obligation", async () => {
  const allowWithoutNetwork = {
    version: 1,
    statements: [{
      effect: "allow",
      actions: ["environment.ensure"],
      resources: ["worklane:default:environment:*"]
    }]
  }
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    const error = yield* Effect.flip(environments.ensure({ environmentKey: "conversation-no-network" }))
    assert.equal(error.reason, "policy.indeterminate")
    assert.equal(harness.fake.state.created.length, 0)
  }), { policyFile: { policy: allowWithoutNetwork } })

  const unknownNetwork = {
    version: 1,
    statements: [{
      effect: "allow",
      actions: ["environment.ensure"],
      resources: ["worklane:default:environment:*"],
      obligations: [{ kind: "network", bundleId: "missing" }]
    }]
  }
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    const error = yield* Effect.flip(environments.ensure({ environmentKey: "conversation-unknown-network" }))
    assert.equal(error.reason, "policy.indeterminate")
    assert.equal(harness.fake.state.created.length, 0)
  }), { policyFile: { policy: unknownNetwork } })
})

test("file operations enforce workspace paths and byte ceilings", async () => {
  await withHarness(() => Effect.gen(function* () {
    const environments = yield* Environments
    const files = yield* Files
    const environment = yield* environments.ensure({ environmentKey: "conversation-files" })
    const reference = { environmentKey: environment.environmentKey, generation: environment.generation }

    yield* files.write({ ...reference, path: "note.txt", dataBase64: Buffer.from("hello").toString("base64") })
    const read = yield* files.read({ ...reference, path: "/workspace/note.txt" })
    assert.equal(Buffer.from(read.dataBase64, "base64").toString(), "hello")

    const escaped = yield* Effect.exit(files.read({ ...reference, path: "/etc/passwd" }))
    assert.equal(Exit.isFailure(escaped), true)
    const oversized = yield* Effect.exit(files.write({
      ...reference,
      path: "large.bin",
      dataBase64: Buffer.alloc(1025).toString("base64")
    }))
    assert.equal(Exit.isFailure(oversized), true)
  }))
})

test("file operations reject non-canonical data and workspace-root removal", async () => {
  await withHarness(() => Effect.gen(function* () {
    const environments = yield* Environments
    const files = yield* Files
    const environment = yield* environments.ensure({ environmentKey: "conversation-file-guards" })
    const reference = { environmentKey: environment.environmentKey, generation: environment.generation }

    const malformed = yield* Effect.flip(files.write({
      ...reference,
      path: "bad.bin",
      dataBase64: "not base64"
    }))
    assert.equal(malformed.reason, "request.invalid")

    const removeRoot = yield* Effect.flip(files.remove({
      ...reference,
      path: "/workspace",
      recursive: true
    }))
    assert.equal(removeRoot.reason, "fs.path_forbidden")
  }))
})

test("environment admission enforces the configured live VM ceiling", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    yield* environments.ensure({ environmentKey: "conversation-capacity-a" })
    const rejected = yield* Effect.flip(environments.ensure({ environmentKey: "conversation-capacity-b" }))
    assert.equal(rejected.reason, "environment.capacity")
    assert.equal(harness.fake.state.created.length, 1)
  }), { policyFile: { maxEnvironments: 1 } })
})

test("output limit failures hard-close the environment", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    const executor = yield* Executor
    const environment = yield* environments.ensure({ environmentKey: "conversation-output-limit" })
    const failure = yield* Effect.flip(Stream.runCollect(executor.execute({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["output-longer-than-limit"],
      outputLimitBytes: 4
    })))
    assert.equal(failure.reason, "exec.output_limit")
    assert.equal(harness.fake.state.closed.length, 1)
    const status = yield* environments.status(environment.environmentKey)
    assert.equal(status.live, false)
    assert.equal(status.state, "failed")
  }))
})

test("guest input setup failures are typed and hard-close the environment", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    const executor = yield* Executor
    const environment = yield* environments.ensure({ environmentKey: "conversation-input-failure" })
    const failure = yield* Effect.flip(Stream.runCollect(executor.execute({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["stdin-disabled"]
    })))
    assert.equal(failure.reason, "runtime.operation_failed")
    assert.equal(failure.details.cause, "stdin was not enabled for this exec")
    assert.equal(harness.fake.state.closed.length, 1)
  }))
})

test("early stream consumer termination hard-closes the environment", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    const executor = yield* Executor
    const environment = yield* environments.ensure({ environmentKey: "conversation-disconnect" })
    const events = yield* Stream.runCollect(executor.execute({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["hang"],
      timeoutMs: 1000
    }).pipe(Stream.take(1)))
    const collected = Array.from(events)
    assert.equal(collected.length, 1)
    assert.equal(collected[0].type, "start")
    assert.equal(harness.fake.state.closed.length, 1)
    const status = yield* environments.status(environment.environmentKey)
    assert.equal(status.live, false)
    assert.equal(status.state, "failed")
  }))
})

test("deadline failure hard-closes an uncooperative environment", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const environments = yield* Environments
    const executor = yield* Executor
    const environment = yield* environments.ensure({ environmentKey: "conversation-hang" })
    const result = yield* Effect.exit(Stream.runCollect(executor.execute({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["hang"],
      timeoutMs: 20
    })))
    assert.equal(Exit.isFailure(result), true)
    assert.equal(harness.fake.state.closed.length, 1)
    const status = yield* environments.status(environment.environmentKey)
    assert.equal(status.live, false)
    assert.equal(status.state, "failed")
  }))
})
