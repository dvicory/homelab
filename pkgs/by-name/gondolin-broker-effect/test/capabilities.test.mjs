import assert from "node:assert/strict"
import test from "node:test"
import { Effect } from "effect"
import {
  canonicalCapabilityKey,
  prepareCapabilityBatch,
  prepareNetworkOrigin
} from "../dist/capabilities.js"

const resolver = async (host) => {
  switch (host) {
    case "docs.example.com":
      return [{ address: "93.184.216.34", family: 4 }]
    case "mixed.example.com":
      return [
        { address: "93.184.216.34", family: 4 },
        { address: "192.168.1.10", family: 4 }
      ]
    case "printer.home.arpa":
      return [
        { address: "192.168.1.40", family: 4 },
        { address: "192.168.1.40", family: 4 }
      ]
    case "loopback.home.arpa":
      return [{ address: "127.0.0.1", family: 4 }]
    default:
      throw new Error(`unexpected resolver host ${host}`)
  }
}

const publicOrigin = (overrides = {}) => ({
  version: 1,
  kind: "network-origin",
  scheme: "https",
  host: "docs.example.com",
  addressMode: "public",
  ...overrides
})

test("network-origin preparation canonicalizes exact public origins", async () => {
  const prepared = await Effect.runPromise(prepareNetworkOrigin(publicOrigin({
    host: "Docs.Example.COM.",
    ports: [8443, 443, 8443]
  }), resolver))

  assert.deepEqual(prepared, {
    version: 1,
    kind: "network-origin",
    scheme: "https",
    host: "docs.example.com",
    ports: [443, 8443],
    addressMode: "public",
    canonicalOrigin: "https://docs.example.com",
    pinnedAddresses: []
  })
  assert.equal(canonicalCapabilityKey(prepared), JSON.stringify({
    version: 1,
    kind: "network-origin",
    scheme: "https",
    host: "docs.example.com",
    ports: [443, 8443],
    addressMode: "public",
    pinnedAddresses: []
  }))
})

test("capability batches deduplicate after canonical preparation", async () => {
  const prepared = await Effect.runPromise(prepareCapabilityBatch([
    publicOrigin({ host: "DOCS.EXAMPLE.COM", ports: [443] }),
    publicOrigin(),
    publicOrigin({ scheme: "http" })
  ], resolver))

  assert.equal(prepared.length, 2)
  assert.deepEqual(prepared.map((capability) => [capability.scheme, capability.ports]), [
    ["http", [80]],
    ["https", [443]]
  ])
})

test("closed capability decoding rejects unsupported and unsafe proposals", async () => {
  await Effect.runPromise(Effect.gen(function* () {
    const unsupported = yield* Effect.flip(prepareNetworkOrigin({ version: 1, kind: "host-mount" }, resolver))
    assert.equal(unsupported.reason, "capability.unsupported")

    const version = yield* Effect.flip(prepareNetworkOrigin(publicOrigin({ version: 2 }), resolver))
    assert.equal(version.reason, "capability.unsupported")

    const excess = yield* Effect.flip(prepareNetworkOrigin(publicOrigin({ path: "/private" }), resolver))
    assert.equal(excess.reason, "capability.invalid")

    for (const host of ["*.example.com", "user@example.com", "https://docs.example.com/path", "docs.example.com?token=x"]) {
      const invalid = yield* Effect.flip(prepareNetworkOrigin(publicOrigin({ host }), resolver))
      assert.equal(invalid.reason, "capability.invalid")
    }
  }))
})

test("public grants reject any internal resolution", async () => {
  await Effect.runPromise(Effect.gen(function* () {
    const mixed = yield* Effect.flip(prepareNetworkOrigin(publicOrigin({ host: "mixed.example.com" }), resolver))
    assert.equal(mixed.reason, "network.address_forbidden")

    const literal = yield* Effect.flip(prepareNetworkOrigin(publicOrigin({ host: "169.254.169.254" }), resolver))
    assert.equal(literal.reason, "network.address_forbidden")
  }))
})

test("pinned-private grants retain only grantable exact private addresses", async () => {
  const prepared = await Effect.runPromise(prepareNetworkOrigin(publicOrigin({
    host: "printer.home.arpa",
    addressMode: "pinned-private"
  }), resolver))
  assert.deepEqual(prepared.pinnedAddresses, ["192.168.1.40"])

  await Effect.runPromise(Effect.gen(function* () {
    const loopback = yield* Effect.flip(prepareNetworkOrigin(publicOrigin({
      host: "loopback.home.arpa",
      addressMode: "pinned-private"
    }), resolver))
    assert.equal(loopback.reason, "network.address_forbidden")

    const publicAddress = yield* Effect.flip(prepareNetworkOrigin(publicOrigin({
      host: "docs.example.com",
      addressMode: "pinned-private"
    }), resolver))
    assert.equal(publicAddress.reason, "network.address_forbidden")
  }))
})
