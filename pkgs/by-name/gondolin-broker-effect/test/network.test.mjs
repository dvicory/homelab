import assert from "node:assert/strict"
import test from "node:test"
import {
  buildNetworkEnforcement,
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
