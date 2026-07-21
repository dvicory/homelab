import assert from "node:assert/strict"
import { mkdtemp } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect, Exit, Stream } from "effect"
import { Environments } from "../dist/environments.js"
import { Executor } from "../dist/exec.js"
import { Files } from "../dist/files.js"
import { makeTestLayer } from "./fakes.mjs"

const withHarness = async (run, options) => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-test-"))
  const harness = makeTestLayer(stateDir, options)
  return Effect.runPromise(Effect.scoped(run(harness).pipe(Effect.provide(harness.layer))))
}

test("ensure reuses a compatible live generation and increments after close", async () => {
  await withHarness(() => Effect.gen(function* () {
    const environments = yield* Environments
    const first = yield* environments.ensure({ environmentKey: "conversation-a" })
    const reused = yield* environments.ensure({ environmentKey: "conversation-a" })
    assert.equal(first.state, "created")
    assert.equal(reused.state, "reused")
    assert.equal(reused.generation, first.generation)

    yield* environments.close({ environmentKey: first.environmentKey, generation: first.generation })
    const next = yield* environments.ensure({ environmentKey: "conversation-a" })
    assert.equal(next.generation, first.generation + 1)
  }))
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
