import assert from "node:assert/strict"
import test from "node:test"
import {
  buildNetworkEnforcement,
  evaluateNetworkAddress,
  evaluateNetworkRequest,
  isNetworkRequestAllowed,
  validateNetworkPolicy
} from "../dist/network.js"

const bundles = {
  mode: "bundles",
  destinations: [
    { kind: "exact", host: "pypi.org" },
    { kind: "subdomains", host: "example.org" },
    { kind: "exact", host: "packages.example.net", ports: [8443] }
  ]
}

const capability = (overrides = {}) => ({
  version: 1,
  kind: "network-origin",
  scheme: "https",
  host: "api.example.com",
  ports: [443],
  addressMode: "public",
  pinnedAddresses: [],
  ...overrides
})

const grant = (overrides = {}) => ({
  grantId: "grant-1",
  scope: "task",
  capabilities: [capability()],
  ...overrides
})

const publicAddress = {
  hostname: "api.example.com",
  ip: "93.184.216.34",
  family: 4,
  port: 443,
  protocol: "https"
}

test("bundle policy allows only reviewed HTTPS destinations and ports", () => {
  assert.equal(isNetworkRequestAllowed(bundles, new Request("https://pypi.org/simple/")), true)
  assert.equal(isNetworkRequestAllowed(bundles, new Request("https://cdn.example.org/file")), true)
  assert.equal(isNetworkRequestAllowed(bundles, new Request("https://example.org/file")), false)
  assert.equal(isNetworkRequestAllowed(bundles, new Request("https://github.com/")), false)
  assert.equal(isNetworkRequestAllowed(bundles, new Request("http://pypi.org/")), false)
  assert.equal(isNetworkRequestAllowed(bundles, new Request("https://packages.example.net:8443/")), true)
  assert.equal(isNetworkRequestAllowed(bundles, new Request("https://packages.example.net/")), false)
  assert.equal(isNetworkRequestAllowed(bundles, { url: "https://user:secret@pypi.org/", method: "GET" }), false)
  assert.equal(isNetworkRequestAllowed(bundles, { url: "https://pypi.org/", method: "CONNECT" }), false)
})

test("public-anonymous remains HTTPS-only and deny-all disables the NIC", () => {
  const publicAnonymous = { mode: "public-anonymous", destinations: [] }
  assert.equal(isNetworkRequestAllowed(publicAnonymous, new Request("https://example.com/")), true)
  assert.equal(isNetworkRequestAllowed(publicAnonymous, new Request("https://example.com:8443/")), false)
  assert.equal(isNetworkRequestAllowed(publicAnonymous, new Request("http://example.com/")), false)

  const denied = buildNetworkEnforcement({ mode: "deny-all", destinations: [] })
  assert.deepEqual(denied, { netEnabled: false, allowWebSockets: false })
})

test("Gondolin hooks enforce synthetic DNS, internal-range denial, and no WebSockets", async () => {
  const enforcement = buildNetworkEnforcement(bundles)
  assert.equal(enforcement.netEnabled, true)
  assert.equal(enforcement.allowWebSockets, false)
  assert.deepEqual(enforcement.dns, { mode: "synthetic", syntheticHostMapping: "per-host" })
  assert.equal(await enforcement.httpHooks.isRequestAllowed(new Request("https://pypi.org/simple/")), true)
  assert.equal(await enforcement.httpHooks.isRequestAllowed(new Request("https://github.com/")), false)
  assert.equal(await enforcement.httpHooks.isIpAllowed({
    hostname: "pypi.org", ip: "169.254.169.254", family: 4, port: 443, protocol: "https"
  }), false)
  assert.equal(await enforcement.httpHooks.isIpAllowed({
    hostname: "pypi.org", ip: "8.8.8.8", family: 4, port: 443, protocol: "https"
  }), true)
})

test("live grants activate and revoke network access in the same enforcement instance", async () => {
  let active = []
  const enforcement = buildNetworkEnforcement(
    { mode: "deny-all", destinations: [] },
    {
      activeGrants: () => active,
      consumeOnce: async () => false
    }
  )
  const request = new Request("https://api.example.com/v1/items?limit=1")

  assert.equal(enforcement.netEnabled, true)
  assert.equal(await enforcement.httpHooks.isRequestAllowed(request), false)
  active = [grant()]
  assert.equal(await enforcement.httpHooks.isRequestAllowed(request), true)
  assert.equal(await enforcement.httpHooks.isIpAllowed(publicAddress), true)
  active = []
  assert.equal(await enforcement.httpHooks.isRequestAllowed(request), false)
  assert.equal(await enforcement.httpHooks.isIpAllowed(publicAddress), false)
})

test("network capability matching is exact by scheme, host, and port", () => {
  const denied = { mode: "deny-all", destinations: [] }
  const active = [grant()]
  assert.equal(evaluateNetworkRequest(
    denied,
    active,
    new Request("https://api.example.com/any/path?query=allowed")
  ).allowed, true)
  assert.equal(evaluateNetworkRequest(
    denied,
    active,
    new Request("http://api.example.com/")
  ).reason, "network.capability_inactive")
  assert.equal(evaluateNetworkRequest(
    denied,
    active,
    new Request("https://sub.api.example.com/")
  ).allowed, false)
  assert.equal(evaluateNetworkRequest(
    denied,
    active,
    new Request("https://api.example.com:8443/")
  ).allowed, false)

  const suggestion = evaluateNetworkRequest(
    denied,
    [],
    new Request("https://missing.example.net:8443/private/path?token=no")
  ).suggestedCapability
  assert.deepEqual(suggestion, {
    version: 1,
    kind: "network-origin",
    scheme: "https",
    host: "missing.example.net",
    ports: [8443],
    addressMode: "public"
  })
  assert.equal(JSON.stringify(suggestion).includes("private/path"), false)
  assert.equal(JSON.stringify(suggestion).includes("token"), false)
})

test("public grants reject private rebinding and pinned-private grants admit only reviewed IPs", () => {
  const denied = { mode: "deny-all", destinations: [] }
  const publicGrant = grant()
  assert.equal(evaluateNetworkAddress(denied, [publicGrant], publicAddress).allowed, true)
  assert.equal(evaluateNetworkAddress(denied, [publicGrant], {
    ...publicAddress,
    ip: "10.0.0.8"
  }).reason, "network.rebinding_denied")

  const privateGrant = grant({
    capabilities: [capability({
      addressMode: "pinned-private",
      pinnedAddresses: ["10.0.0.8"]
    })]
  })
  assert.equal(evaluateNetworkAddress(denied, [privateGrant], {
    ...publicAddress,
    ip: "10.0.0.8"
  }).allowed, true)
  assert.equal(evaluateNetworkAddress(denied, [privateGrant], {
    ...publicAddress,
    ip: "10.0.0.9"
  }).reason, "network.rebinding_denied")
  assert.equal(evaluateNetworkAddress(denied, [privateGrant], publicAddress).allowed, false)
})

test("a once grant admits one request while repeated DNS/connect checks stay authorized", async () => {
  const once = grant({ scope: "once" })
  let active = [once]
  let consumed = 0
  const enforcement = buildNetworkEnforcement(
    { mode: "deny-all", destinations: [] },
    {
      activeGrants: () => active,
      consumeOnce: async (grantId) => {
        assert.equal(grantId, once.grantId)
        if (consumed !== 0) return false
        consumed += 1
        active = []
        return true
      }
    }
  )
  const request = () => new Request("https://api.example.com/once")

  assert.deepEqual(
    await Promise.all([
      enforcement.httpHooks.isRequestAllowed(request()),
      enforcement.httpHooks.isRequestAllowed(request())
    ]),
    [true, false]
  )
  assert.equal(consumed, 1)
  assert.equal(await enforcement.httpHooks.isIpAllowed(publicAddress), true)
  assert.equal(await enforcement.httpHooks.isIpAllowed(publicAddress), true)
  assert.equal(await enforcement.httpHooks.isRequestAllowed(request()), false)
})

test("redirect destinations are re-authorized as independent request hops", async () => {
  const active = [grant()]
  const enforcement = buildNetworkEnforcement(
    { mode: "deny-all", destinations: [] },
    { activeGrants: () => active, consumeOnce: async () => false }
  )

  assert.equal(
    await enforcement.httpHooks.isRequestAllowed(new Request("https://api.example.com/start")),
    true
  )
  assert.equal(
    await enforcement.httpHooks.isRequestAllowed(new Request("https://redirected.example.net/landing")),
    false
  )
})

test("inactive capability denial is requestable and contains no URL path or query", async () => {
  const enforcement = buildNetworkEnforcement(
    { mode: "deny-all", destinations: [] },
    { activeGrants: () => [], consumeOnce: async () => false }
  )
  const response = await enforcement.httpHooks.onRequest(
    new Request("https://api.example.com/private/path?secret=value")
  )
  const problem = await response.json()

  assert.equal(response.status, 403)
  assert.equal(response.headers.get("content-type"), "application/problem+json")
  assert.equal(problem.reason, "network.capability_inactive")
  assert.deepEqual(problem.suggestedCapability, {
    version: 1,
    kind: "network-origin",
    scheme: "https",
    host: "api.example.com",
    ports: [443],
    addressMode: "public"
  })
  assert.equal(JSON.stringify(problem).includes("private/path"), false)
  assert.equal(JSON.stringify(problem).includes("secret=value"), false)
})

test("invalid or overbroad network policies fail closed", () => {
  assert.throws(
    () => validateNetworkPolicy({ mode: "bundles", destinations: [] }),
    /requires at least one destination/
  )
  assert.throws(
    () => validateNetworkPolicy({ mode: "deny-all", destinations: [{ kind: "exact", host: "pypi.org" }] }),
    /cannot carry destinations/
  )
  assert.throws(
    () => validateNetworkPolicy({ mode: "bundles", destinations: [{ kind: "subdomains", host: "com" }] }),
    /refusing to wildcard/
  )
  assert.throws(
    () => validateNetworkPolicy({ mode: "bundles", destinations: [{ kind: "exact", host: "127.0.0.1" }] }),
    /invalid network destination/
  )
})
