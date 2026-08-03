import assert from "node:assert/strict"
import { mkdtemp } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect, Stream } from "effect"
import { Environments } from "../dist/environments.js"
import { Executor } from "../dist/exec.js"
import { Processes } from "../dist/processes.js"
import { bindTestAuthority, makeTestLayer } from "./fakes.mjs"

const withHarness = async (run, options) => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-process-test-"))
  const harness = makeTestLayer(stateDir, options)
  return Effect.runPromise(Effect.scoped(run(harness).pipe(Effect.provide(harness.layer))))
}

const startEnvironment = (environmentKey) => Effect.gen(function* () {
  const environments = yield* Environments
  yield* bindTestAuthority(environmentKey)
  return yield* environments.ensure({ environmentKey })
})

test("background execution outlives spawn and retains exact nonzero exit", async () => {
  await withHarness(() => Effect.gen(function* () {
    const processes = yield* Processes
    const environment = yield* startEnvironment("process-nonzero")
    const spawned = yield* Effect.scoped(processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["delayed-exit-7"],
    }))

    assert.equal(spawned.state, "running")
    yield* Effect.sleep("40 millis")

    const result = yield* processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: 0,
    })
    assert.equal(result.state, "exited")
    assert.equal(result.exitCode, 7)
    assert.equal(result.signal, null)
    assert.equal(Buffer.from(result.output[0].dataBase64, "base64").toString(), "delayed-exit-7")
  }))
})

test("cancellation hard-closes only the owning generation and remains observable", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const processes = yield* Processes
    const environments = yield* Environments
    const environment = yield* startEnvironment("process-cancel")
    const spawned = yield* processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["hang"],
    })

    const cancelled = yield* processes.cancel({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
    })
    assert.equal(cancelled.state, "cancelled")
    assert.equal(cancelled.exitCode, null)
    assert.deepEqual(harness.fake.state.closed, ["fake-1"])
    assert.equal((yield* environments.status(environment.environmentKey)).state, "closed")

    const retained = yield* processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: 0,
    })
    assert.equal(retained.state, "cancelled")
  }))
})

test("one running process per environment fails before a second launch", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const processes = yield* Processes
    const environment = yield* startEnvironment("process-capacity")
    const first = yield* processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["hang"],
    })
    const failure = yield* Effect.flip(processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["not-started"],
    }))
    assert.equal(failure.reason, "environment.capacity")
    assert.deepEqual(harness.fake.state.execs, [["hang"]])

    yield* processes.cancel({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: first.processId,
    })
  }))
})

test("one background process leaves a foreground exec permit available", async () => {
  await withHarness((harness) => Effect.gen(function* () {
    const processes = yield* Processes
    const executor = yield* Executor
    const environment = yield* startEnvironment("process-foreground")
    const background = yield* processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["hang"],
    })

    const events = Array.from(yield* Stream.runCollect(executor.execute({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["foreground"],
    })))
    assert.equal(events.at(-1)?.type, "exit")
    assert.deepEqual(harness.fake.state.execs, [["hang"], ["foreground"]])

    yield* processes.cancel({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: background.processId,
    })
  }))
})

test("foreign environment cannot poll an opaque process", async () => {
  await withHarness(() => Effect.gen(function* () {
    const processes = yield* Processes
    const owner = yield* startEnvironment("process-owner")

    const foreign = yield* startEnvironment("process-foreign")
    const spawned = yield* processes.spawn({
      environmentKey: owner.environmentKey,
      generation: owner.generation,
      argv: ["exit-7"],
    })

    const failure = yield* Effect.flip(processes.poll({
      environmentKey: foreign.environmentKey,
      generation: foreign.generation,
      processId: spawned.processId,
      cursor: 0,
    }))
    assert.equal(failure.reason, "process.not_found")
  }))
})

test("poll pagination never skips retained output", async () => {
  await withHarness(() => Effect.gen(function* () {
    const processes = yield* Processes
    const environment = yield* startEnvironment("process-pagination")
    const payload = "x".repeat(4000)
    const spawned = yield* processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: [payload],
    })
    yield* Effect.sleep("10 millis")

    const first = yield* processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: 0,
      maxBytes: 1024,
    })
    const second = yield* processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: first.nextCursor,
      maxBytes: 1024,
    })
    const third = yield* processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: second.nextCursor,
      maxBytes: 1024,
    })
    const fourth = yield* processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: third.nextCursor,
      maxBytes: 1024,
    })
    const decoded = [...first.output, ...second.output, ...third.output, ...fourth.output]
      .map((event) => Buffer.from(event.dataBase64, "base64").toString())
      .join("")
    assert.equal(decoded, payload)
    assert.deepEqual(
      [first.nextCursor, second.nextCursor, third.nextCursor, fourth.nextCursor],
      [1, 2, 3, 4],
    )
  }))
})

test("global process capacity rejects a second environment", async () => {
  await withHarness(() => Effect.gen(function* () {
    const processes = yield* Processes
    const firstEnvironment = yield* startEnvironment("process-global-a")
    const secondEnvironment = yield* startEnvironment("process-global-b")
    const first = yield* processes.spawn({
      environmentKey: firstEnvironment.environmentKey,
      generation: firstEnvironment.generation,
      argv: ["hang"],
    })
    const failure = yield* Effect.flip(processes.spawn({
      environmentKey: secondEnvironment.environmentKey,
      generation: secondEnvironment.generation,
      argv: ["not-started"],
    }))
    assert.equal(failure.reason, "environment.capacity")
    yield* processes.cancel({
      environmentKey: firstEnvironment.environmentKey,
      generation: firstEnvironment.generation,
      processId: first.processId,
    })
  }), {
    policyFile: {
      processRegistry: {
        maxConcurrent: 1,
        retainedOutputBytes: 4096,
        maxPollBytes: 4096,
        terminalTtlMs: 30 * 60 * 1000,
      },
    },
  })
})

test("terminal records expire after the configured TTL", async () => {
  await withHarness(() => Effect.gen(function* () {
    const processes = yield* Processes
    const environment = yield* startEnvironment("process-ttl")
    const spawned = yield* processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["exit-7"],
    })
    yield* Effect.sleep("100 millis")
    const failure = yield* Effect.flip(processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: 0,
    }))
    assert.equal(failure.reason, "process.not_found")
  }), {
    policyFile: {
      processRegistry: {
        maxConcurrent: 4,
        retainedOutputBytes: 4096,
        maxPollBytes: 4096,
        terminalTtlMs: 40,
      },
    },
  })
})

test("stdout and stderr retain broker execution order", async () => {
  await withHarness(() => Effect.gen(function* () {
    const processes = yield* Processes
    const environment = yield* startEnvironment("process-stream-order")
    const spawned = yield* processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["mixed-output"],
    })
    yield* Effect.sleep("10 millis")
    const result = yield* processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: 0,
    })
    assert.deepEqual(
      result.output.map((event) => [
        event.stream,
        Buffer.from(event.dataBase64, "base64").toString(),
      ]),
      [
        ["stdout", "out-1"],
        ["stderr", "err-1"],
        ["stdout", "out-2"],
      ],
    )
  }))
})

test("cancel racing a natural exit preserves the real terminal result", async () => {
  await withHarness(() => Effect.gen(function* () {
    const processes = yield* Processes
    const environment = yield* startEnvironment("process-exit-cancel-race")
    const spawned = yield* processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["exit-7"],
    })
    yield* Effect.sleep("10 millis")
    const result = yield* processes.cancel({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
    })
    assert.equal(result.state, "exited")
    assert.equal(result.exitCode, 7)
  }))
})

test("retention reports dropped bytes and resumes at the first available cursor", async () => {
  await withHarness(() => Effect.gen(function* () {
    const processes = yield* Processes
    const environment = yield* startEnvironment("process-truncation")
    const spawned = yield* processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["x".repeat(4000)],
    })
    yield* Effect.sleep("10 millis")
    const result = yield* processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: 0,
    })
    assert.equal(result.truncatedBytes, 2048)
    assert.equal(result.firstAvailableCursor, 3)
    assert.equal(
      result.output
        .map((event) => Buffer.from(event.dataBase64, "base64").byteLength)
        .reduce((total, bytes) => total + bytes, 0),
      1952,
    )
  }), {
    policyFile: {
      processRegistry: {
        maxConcurrent: 4,
        retainedOutputBytes: 2048,
        maxPollBytes: 4096,
        terminalTtlMs: 30 * 60 * 1000,
      },
    },
  })
})

test("environment close drains execution and fences the old process generation", async () => {
  await withHarness(() => Effect.gen(function* () {
    const processes = yield* Processes
    const environments = yield* Environments
    const environment = yield* startEnvironment("process-generation-close")
    const spawned = yield* processes.spawn({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      argv: ["hang"],
    })
    const closeStartedAt = Date.now()
    yield* environments.close({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
    })
    assert.ok(Date.now() - closeStartedAt < 500, "environment close did not cancel the process")
    const drained = yield* processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: 0,
    })
    assert.equal(drained.state, "cancelled")
    assert.equal(drained.reason, "environment_closed")
    const replacement = yield* environments.ensure({
      environmentKey: environment.environmentKey,
    })
    assert.equal(replacement.generation, environment.generation + 1)
    const failure = yield* Effect.flip(processes.poll({
      environmentKey: environment.environmentKey,
      generation: environment.generation,
      processId: spawned.processId,
      cursor: 0,
    }))
    assert.equal(failure.reason, "process.not_found")
  }))
})

test("broker restart reports an old process as unknown without fabricating exit", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-process-restart-test-"))
  const firstHarness = makeTestLayer(stateDir)
  const reference = await Effect.runPromise(Effect.scoped(
    Effect.gen(function* () {
      const processes = yield* Processes
      const environment = yield* startEnvironment("process-restart")
      const spawned = yield* processes.spawn({
        environmentKey: environment.environmentKey,
        generation: environment.generation,
        argv: ["hang"],
      })
      return {
        environmentKey: environment.environmentKey,
        generation: environment.generation,
        processId: spawned.processId,
      }
    }).pipe(Effect.provide(firstHarness.layer)),
  ))

  const restartedHarness = makeTestLayer(stateDir)
  const failure = await Effect.runPromise(Effect.scoped(
    Effect.gen(function* () {
      const processes = yield* Processes
      return yield* Effect.flip(processes.poll({ ...reference, cursor: 0 }))
    }).pipe(Effect.provide(restartedHarness.layer)),
  ))
  assert.equal(failure.reason, "process.not_found")
  assert.equal("exitCode" in failure, false)
})
