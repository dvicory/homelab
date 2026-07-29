import assert from "node:assert/strict"
import { mkdtemp } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import test from "node:test"
import { Effect } from "effect"
import { AccessGrants } from "../dist/grants.js"
import { Registry } from "../dist/registry.js"
import { Workspaces } from "../dist/workspaces.js"
import { makeTestLayer } from "./fakes.mjs"

const origin = (host = "docs.example.com") => ({
  version: 1,
  kind: "network-origin",
  scheme: "https",
  host,
  addressMode: "public"
})

const resolver = async (host) => {
  const addresses = {
    "docs.example.com": "93.184.216.34",
    "api.example.net": "8.8.8.8",
    "packages.example.org": "1.1.1.1",
    "internal.example.com": "192.168.1.10"
  }
  if (!(host in addresses)) throw new Error(`unexpected host ${host}`)
  return [{ address: addresses[host], family: 4 }]
}

const bind = (registry, environmentKey, overrides = {}) => Effect.gen(function* () {
  const workspaces = yield* Workspaces
  const acquired = yield* workspaces.acquire(environmentKey)
  return yield* registry.bindAuthority({
    environmentKey,
    profile: "test",
    executor: "hermes-gateway",
    authorityClass: "default",
    policyDigest: "a".repeat(64),
    workspaceId: acquired.workspace.workspaceId,
    workspaceLeaseId: acquired.lease.leaseId,
    ...overrides
  })
})

test("proactive preparation uses explicit authority without starting a VM", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-proactive-"))
  const harness = makeTestLayer(stateDir, {
    grantResolver: resolver,
    policyFile: {
      networkPolicies: {
        "worklane:default": {
          mode: "bundles",
          destinations: [{ kind: "exact", host: "docs.example.com", ports: [443] }]
        }
      }
    }
  })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    const grants = yield* AccessGrants
    yield* bind(registry, "task-proactive")

    const covered = yield* grants.prepare({
      environmentKey: "task-proactive",
      capabilities: [origin()],
      requestedScope: "task"
    })
    assert.equal(covered.state, "active")
    assert.equal(covered.requestId, null)
    assert.deepEqual(covered.grantIds, [])
    assert.equal(grants.snapshot().grants.length, 0)
    assert.equal((yield* registry.getAuthority("task-proactive")).authorityClass, "default")
    assert.equal(yield* registry.get("task-proactive"), undefined)
    assert.equal(harness.fake.state.created.length, 0)

    const requestable = yield* grants.prepare({
      environmentKey: "task-proactive",
      capabilities: [origin("api.example.net")],
      requestedScope: "task"
    })
    assert.equal(requestable.state, "pending")
    assert.ok(requestable.requestId)
  }).pipe(Effect.provide(harness.layer))))
})

test("a static hostname does not bypass pinned-private approval", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-private-baseline-"))
  const harness = makeTestLayer(stateDir, {
    grantResolver: resolver,
    policyFile: {
      networkPolicies: {
        "worklane:default": {
          mode: "bundles",
          destinations: [{ kind: "exact", host: "internal.example.com", ports: [443] }]
        }
      }
    }
  })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const grants = yield* AccessGrants
    const registry = yield* Registry
    yield* bind(registry, "task-private")
    const prepared = yield* grants.prepare({
      environmentKey: "task-private",
      capabilities: [{
        ...origin("internal.example.com"),
        addressMode: "pinned-private"
      }],
      requestedScope: "task"
    })
    assert.equal(prepared.state, "pending")
    assert.deepEqual(prepared.capabilities[0].pinnedAddresses, ["192.168.1.10"])
  }).pipe(Effect.provide(harness.layer))))
})

test("access preparation coalesces pending requests and publishes approved batches atomically", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-grants-"))
  const harness = makeTestLayer(stateDir, { grantResolver: resolver })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    const grants = yield* AccessGrants
    yield* bind(registry, "task-a")

    const proposal = {
      environmentKey: "task-a",
      capabilities: [origin(), origin("DOCS.EXAMPLE.COM")],
      requestedScope: "task"
    }
    const prepared = yield* grants.prepare(proposal)
    assert.equal(prepared.state, "pending")
    assert.equal(prepared.capabilities.length, 1)
    assert.ok(prepared.requestId)

    const duplicate = yield* grants.prepare(proposal)
    assert.equal(duplicate.state, "existing-pending")
    assert.equal(duplicate.requestId, prepared.requestId)

    const suppressed = yield* Effect.flip(grants.prepare({
      ...proposal,
      capabilities: [origin("api.example.net")]
    }))
    assert.equal(suppressed.reason, "approval.request_suppressed")

    const before = grants.snapshot()
    assert.equal(before.grants.length, 0)
    const decision = yield* grants.decide({
      requestId: prepared.requestId,
      decision: "approve",
      principal: "operator"
    })
    assert.equal(decision.state, "approved")
    assert.equal(decision.grantIds.length, 1)

    const after = grants.snapshot()
    assert.ok(Object.isFrozen(after))
    assert.ok(Object.isFrozen(after.grants))
    assert.equal(before.grants.length, 0)
    assert.equal(after.grants.length, 1)
    assert.ok(after.revision > before.revision)
    assert.deepEqual(after.grants[0].capabilities.map((capability) => capability.host), ["docs.example.com"])
  }).pipe(Effect.provide(harness.layer))))
})

test("once use is consumed transactionally at most once", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-once-"))
  const harness = makeTestLayer(stateDir, { grantResolver: resolver })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    const grants = yield* AccessGrants
    yield* bind(registry, "task-once")
    const prepared = yield* grants.prepare({
      environmentKey: "task-once",
      capabilities: [origin()],
      requestedScope: "once"
    })
    const decision = yield* grants.decide({
      requestId: prepared.requestId,
      decision: "approve",
      principal: "operator"
    })
    const [first, second] = yield* Effect.all([
      grants.consumeOnce(decision.grantIds[0]),
      grants.consumeOnce(decision.grantIds[0])
    ], { concurrency: "unbounded" })
    assert.equal(Number(first) + Number(second), 1)
    assert.equal(grants.snapshot().grants.length, 0)
  }).pipe(Effect.provide(harness.layer))))
})

test("timed expiry and revocation remove grants from the live snapshot", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-expiry-"))
  let timestamp = 100000
  const harness = makeTestLayer(stateDir, { grantResolver: resolver, now: () => timestamp })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    const grants = yield* AccessGrants
    const binding = yield* bind(registry, "task-timed")
    const prepared = yield* grants.prepare({
      environmentKey: "task-timed",
      capabilities: [origin()],
      requestedScope: "timed",
      durationSeconds: 30
    })
    const decision = yield* grants.decide({
      requestId: prepared.requestId,
      decision: "approve",
      principal: "operator"
    })
    assert.equal(grants.matching(binding, "task-timed").length, 1)

    timestamp += 31000
    assert.equal(grants.matching(binding, "task-timed").length, 0)
    const expired = yield* grants.list("task-timed")
    assert.equal(expired[0].state, "expired")
    assert.equal(grants.snapshot().grants.length, 0)

    const next = yield* grants.prepare({
      environmentKey: "task-timed",
      capabilities: [origin("api.example.net")],
      requestedScope: "task"
    })
    const approved = yield* grants.decide({
      requestId: next.requestId,
      decision: "approve",
      principal: "operator"
    })
    yield* grants.revoke(approved.grantIds[0], "operator")
    assert.equal(grants.snapshot().grants.length, 0)
  }).pipe(Effect.provide(harness.layer))))
})

test("remembered grants match new bindings and remain listable and revocable", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-remembered-"))
  const harness = makeTestLayer(stateDir, { grantResolver: resolver })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    const grants = yield* AccessGrants
    yield* bind(registry, "task-profile-a")
    const prepared = yield* grants.prepare({
      environmentKey: "task-profile-a",
      capabilities: [origin()],
      requestedScope: "profile"
    })
    const approved = yield* grants.decide({
      requestId: prepared.requestId,
      decision: "approve",
      principal: "operator"
    })

    yield* bind(registry, "task-profile-b")
    const remembered = yield* grants.prepare({
      environmentKey: "task-profile-b",
      capabilities: [origin()],
      requestedScope: "task"
    })
    assert.equal(remembered.state, "active")
    assert.deepEqual(remembered.grantIds, approved.grantIds)

    const listed = yield* grants.list()
    assert.equal(listed.length, 1)
    assert.equal(listed[0].scope, "profile")
    yield* grants.revoke(listed[0].grantId, "operator")
    const afterRevoke = yield* grants.prepare({
      environmentKey: "task-profile-b",
      capabilities: [origin()],
      requestedScope: "task"
    })
    assert.equal(afterRevoke.state, "pending")
  }).pipe(Effect.provide(harness.layer))))
})

test("denial cooldown and rolling prompt budget survive request state changes", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-fatigue-"))
  let timestamp = 100000
  const harness = makeTestLayer(stateDir, {
    grantResolver: resolver,
    now: () => timestamp,
    policyFile: {
      grantPolicy: {
        allowedScopes: ["task"],
        maxDurationSeconds: 60,
        denialCooldownSeconds: 60,
        promptBudget: { maxNewRequests: 2, windowSeconds: 300 }
      }
    }
  })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    const grants = yield* AccessGrants
    yield* bind(registry, "task-fatigue")

    const first = yield* grants.prepare({
      environmentKey: "task-fatigue",
      capabilities: [origin()],
      requestedScope: "task"
    })
    yield* grants.decide({ requestId: first.requestId, decision: "deny", principal: "operator" })
    const cooldown = yield* Effect.flip(grants.prepare({
      environmentKey: "task-fatigue",
      capabilities: [origin()],
      requestedScope: "task"
    }))
    assert.equal(cooldown.reason, "approval.request_suppressed")

    const second = yield* grants.prepare({
      environmentKey: "task-fatigue",
      capabilities: [origin("api.example.net")],
      requestedScope: "task"
    })
    yield* grants.decide({ requestId: second.requestId, decision: "deny", principal: "operator" })
    const budget = yield* Effect.flip(grants.prepare({
      environmentKey: "task-fatigue",
      capabilities: [origin("packages.example.org")],
      requestedScope: "task"
    }))
    assert.equal(budget.reason, "approval.request_suppressed")
    assert.equal(budget.details.maximum, 2)
  }).pipe(Effect.provide(harness.layer))))
})

test("restart restores only current non-expired grants", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "gondolin-effect-restart-grants-"))
  let timestamp = 100000
  const firstHarness = makeTestLayer(stateDir, { grantResolver: resolver, now: () => timestamp })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const registry = yield* Registry
    const grants = yield* AccessGrants
    yield* bind(registry, "task-restart")
    const durable = yield* grants.prepare({
      environmentKey: "task-restart",
      capabilities: [origin()],
      requestedScope: "task"
    })
    yield* grants.decide({ requestId: durable.requestId, decision: "approve", principal: "operator" })
    const timed = yield* grants.prepare({
      environmentKey: "task-restart",
      capabilities: [origin("api.example.net")],
      requestedScope: "timed",
      durationSeconds: 10
    })
    yield* grants.decide({ requestId: timed.requestId, decision: "approve", principal: "operator" })
  }).pipe(Effect.provide(firstHarness.layer))))

  timestamp += 11000
  const restarted = makeTestLayer(stateDir, { grantResolver: resolver, now: () => timestamp })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const grants = yield* AccessGrants
    assert.equal(grants.snapshot().grants.length, 1)
    assert.equal(grants.snapshot().grants[0].capabilities[0].host, "docs.example.com")
    const all = yield* grants.list("task-restart")
    assert.deepEqual(all.map((grant) => grant.state).sort(), ["active", "expired"])
  }).pipe(Effect.provide(restarted.layer))))

  const changedPolicy = makeTestLayer(stateDir, {
    grantResolver: resolver,
    now: () => timestamp,
    policyFile: { policyDigest: "b".repeat(64) }
  })
  await Effect.runPromise(Effect.scoped(Effect.gen(function* () {
    const grants = yield* AccessGrants
    assert.equal(grants.snapshot().grants.length, 0)
    const all = yield* grants.list("task-restart")
    assert.deepEqual(all.map((grant) => grant.state).sort(), ["expired", "revoked"])
    assert.equal(all.find((grant) => grant.state === "revoked").revokedBy, "policy-digest")
  }).pipe(Effect.provide(changedPolicy.layer))))
})
