import assert from "node:assert/strict"
import test from "node:test"
import {
  authorize,
  decodePolicyDocument,
  deterministicDigest,
  evaluate,
  isAuthorizedAction,
  makeActionRegistry
} from "../dist/index.js"

const registry = makeActionRegistry([{ action: "file.read" }])
const action = { action: "file.read", resource: "space/docs/public/report" }
const base = (statements) => decodePolicyDocument({ version: 1, statements })
const allow = (overrides = {}) => ({
  effect: "allow",
  actions: ["file.read"],
  resources: ["space/docs/*"],
  ...overrides
})

test("deny overrides an otherwise matching allow", () => {
  const decision = evaluate({
    policy: base([allow(), { effect: "deny", actions: ["file.read"], resources: ["space/docs/private/*"] }]),
    action: { ...action, resource: "space/docs/private/secret" },
    registry
  })
  assert.deepEqual(decision.reasonCodes, ["EXPLICIT_DENY"])
})

test("resource matching and numeric limits attenuate", () => {
  const decision = evaluate({
    policy: base([allow({ limits: { bytes: 100, count: 4 } }), allow({ limits: { bytes: 40 } })]),
    action,
    registry
  })
  assert.equal(decision.kind, "allow")
  assert.deepEqual(decision.effectiveAuthority.limits, { bytes: 40, count: 4 })
  assert.equal(evaluate({ policy: base([allow()]), action: { ...action, resource: "other/x" }, registry }).kind, "deny")
})

test("non-wildcard resources match exactly", () => {
  const exact = { effect: "allow", actions: ["file.read"], resources: ["space/docs/private"] }
  assert.equal(evaluate({ policy: base([exact]), action: { ...action, resource: "space/docs/private" }, registry }).kind, "allow")
  assert.equal(evaluate({ policy: base([exact]), action: { ...action, resource: "space/docs/private-shadow" }, registry }).kind, "deny")
})

test("action registry constrains resource families and obligations", () => {
  const constrained = makeActionRegistry([{
    action: "file.read",
    resources: ["space/docs/*"],
    obligations: ["audit"]
  }])
  const policy = base([allow({ obligations: ["audit"] })])
  assert.equal(evaluate({
    policy,
    action,
    registry: constrained,
    supportedObligations: ["audit"]
  }).kind, "allow")
  assert.deepEqual(evaluate({
    policy,
    action: { ...action, resource: "space/other/report" },
    registry: constrained,
    supportedObligations: ["audit"]
  }).reasonCodes, ["RESOURCE_NOT_REGISTERED"])
})

test("unknown actions and unsupported obligations fail closed", () => {
  const unknown = evaluate({ policy: base([allow()]), action: { action: "made.up", resource: action.resource }, registry })
  assert.deepEqual(unknown.reasonCodes, ["UNKNOWN_ACTION"])
  const unsupported = evaluate({
    policy: base([allow({ obligations: ["audit"] })]),
    action,
    registry,
    supportedObligations: []
  })
  assert.deepEqual(unsupported.reasonCodes, ["UNSUPPORTED_OBLIGATION"])
})

test("decode rejects excess fields and invalid limits", () => {
  assert.throws(() => decodePolicyDocument({ version: 1, statements: [], unexpected: true }))
  assert.throws(() => decodePolicyDocument({ version: 1, statements: [allow({ limits: { bytes: -1 } })] }))
})

test("only authorize creates a recognized authorized action", () => {
  const request = { policy: base([allow()]), action, registry }
  const decision = evaluate(request)
  assert.equal(decision.kind, "allow")
  const authorized = authorize(request)
  assert.equal(isAuthorizedAction(authorized), true)
  assert.equal(isAuthorizedAction(JSON.parse(JSON.stringify(authorized))), false)
  assert.throws(() => authorize({ ...request, action: { ...action, resource: "other" } }, decision))
})

test("SHA-256 digest is canonical, sensitive, and JSON-bound", () => {
  assert.equal(deterministicDigest({ b: 2, a: 1 }), deterministicDigest({ a: 1, b: 2 }))
  assert.notEqual(deterministicDigest({ a: 1 }), deterministicDigest({ a: 2 }))
  assert.notEqual(deterministicDigest({ a: 1 }), deterministicDigest({ a: 1, b: 0 }))
  assert.equal(deterministicDigest({ a: 1 }), "015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862")
  assert.throws(() => deterministicDigest({ a: undefined }))
  assert.throws(() => deterministicDigest({ a: 1n }))
})
