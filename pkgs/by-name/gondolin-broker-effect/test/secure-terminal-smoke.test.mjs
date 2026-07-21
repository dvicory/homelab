import assert from "node:assert/strict"
import { mkdtemp } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { AccessGrants } from "../dist/grants.js"
import { Environments } from "../dist/environments.js"
import { makeTestLayer } from "./fakes.mjs"
import { buildNetworkEnforcement } from "../dist/network.js"

const capability = {
  version: 1,
  kind: "network-origin",
  scheme: "https",
  host: "api.example.com",
  ports: [443],
  addressMode: "public"
}

const request = () => new Request("https://api.example.com/private/path?secret=value")

test("secure terminal smoke: deny, approve, same-VM retry, revoke, and restart", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-secure-terminal-smoke-"))
  const harness = makeTestLayer(stateDir, {
    grantResolver: async () => [{ address: "93.184.216.34", family: 4 }]
  })

  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const environments = yield* Environments
    const grants = yield* AccessGrants

    const first = yield* environments.ensure({ environmentKey: "conversation-smoke" })
    const firstVm = harness.fake.state.created[0]
    const dynamic = firstVm.spec.dynamicNetwork
    assert.ok(dynamic)
    const hooks = buildNetworkEnforcement(firstVm.spec.network, dynamic).httpHooks

    const denied = yield* Effect.promise(() => hooks.onRequest(request()))
    assert.ok(denied instanceof Response)
    assert.equal(denied.status, 403)
    const problem = yield* Effect.promise(() => denied.json())
    assert.equal(problem.reason, "network.capability_inactive")
    assert.deepEqual(problem.suggestedCapability, capability)
    assert.equal(JSON.stringify(problem).includes("private/path"), false)
    assert.equal(JSON.stringify(problem).includes("secret=value"), false)

    const prepared = yield* grants.prepare({
      environmentKey: first.environmentKey,
      capabilities: [problem.suggestedCapability],
      requestedScope: "task",
      rationale: "smoke-test retry"
    })
    assert.equal(prepared.state, "pending")

    const approved = yield* grants.decide({
      requestId: prepared.requestId,
      decision: "approve",
      principal: "smoke-operator"
    })
    assert.equal(approved.state, "approved")
    assert.equal(approved.grantIds.length, 1)

    const reused = yield* environments.ensure({ environmentKey: first.environmentKey })
    assert.equal(reused.state, "reused")
    assert.equal(reused.generation, first.generation)
    assert.equal(harness.fake.state.created.length, 1)
    assert.equal(yield* Effect.promise(() => hooks.isRequestAllowed(request())), true)

    yield* grants.revoke(approved.grantIds[0], "smoke-operator")
    const revoked = yield* Effect.promise(() => hooks.onRequest(request()))
    assert.ok(revoked instanceof Response)
    assert.equal(revoked.status, 403)

    yield* environments.close({
      environmentKey: first.environmentKey,
      generation: first.generation
    })
    const restarted = yield* environments.ensure({ environmentKey: first.environmentKey })
    assert.equal(restarted.generation, first.generation + 1)
    assert.equal(harness.fake.state.created.length, 2)
    const restartedDynamic = harness.fake.state.created[1].spec.dynamicNetwork
    assert.ok(restartedDynamic)
    const restartedHooks = buildNetworkEnforcement(
      harness.fake.state.created[1].spec.network,
      restartedDynamic
    ).httpHooks
    assert.equal(yield* Effect.promise(() => restartedHooks.isRequestAllowed(request())), false)
  }).pipe(Effect.provide(harness.layer))))
})
