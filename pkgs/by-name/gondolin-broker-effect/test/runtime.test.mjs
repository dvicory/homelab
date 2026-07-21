import assert from "node:assert/strict"
import test from "node:test"
import { parseGondolinDebug } from "../dist/runtime.js"

test("Gondolin debug configuration is explicit and component-scoped", () => {
  assert.equal(parseGondolinDebug(undefined), false)
  assert.equal(parseGondolinDebug(""), false)
  assert.equal(parseGondolinDebug("all"), true)
  assert.deepEqual(parseGondolinDebug("qemu, protocol,net"), ["qemu", "protocol", "net"])
})
