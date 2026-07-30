import assert from "node:assert/strict"
import test from "node:test"
import { Effect } from "effect"
import { makeCreateVm, parseGondolinDebug } from "../dist/runtime.js"

test("Gondolin debug configuration is explicit and component-scoped", () => {
  assert.equal(parseGondolinDebug(undefined), false)
  assert.equal(parseGondolinDebug(""), false)
  assert.equal(parseGondolinDebug("all"), true)
  assert.deepEqual(parseGondolinDebug("protocol, net"), ["protocol", "net"])
  assert.throws(() => parseGondolinDebug("qemu"), /Unknown Gondolin debug component: qemu/)
})

const vmSpec = {
  assetPath: "/asset",
  memoryMiB: 512,
  cpus: 1,
  workspaceHostPath: "/host-workspace",
  workspaceGuestPath: "/workspace",
  workPlaneReadOnly: false,
  sessionLabel: "test:environment:1",
  network: { mode: "deny-all", destinations: [] },
}

const fakeVm = (
  start,
  close,
  exec = () => {
    throw new Error("not exercised")
  },
) => ({
  id: "vm-1",
  start,
  close,
  getHostPid: () => 123,
  fs: {},
  exec,
})

test("VM creation awaits startup before publishing a live handle", async () => {
  let resolveStart
  const started = new Promise((resolve) => {
    resolveStart = resolve
  })
  let options
  let settled = false
  const createVm = makeCreateVm(async (received) => {
    options = received
    return fakeVm(() => started, async () => undefined)
  })
  const pending = Effect.runPromise(createVm(vmSpec))
  void pending.then(() => {
    settled = true
  })

  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(options.autoStart, true)
  assert.equal(options.sandbox.netEnabled, false)
  assert.equal(options.sandbox.allowWebSockets, false)
  assert.equal(settled, false)

  resolveStart()
  const handle = await pending
  assert.equal(handle.id, "vm-1")
  assert.equal(settled, true)
})

test("VM startup failure closes the partially started VM", async () => {
  let closes = 0
  const createVm = makeCreateVm(async () =>
    fakeVm(
      async () => {
        throw new Error("boot failed")
      },
      async () => {
        closes += 1
      },
    )
  )

  await assert.rejects(Effect.runPromise(createVm(vmSpec)), /Gondolin create failed/)
  assert.equal(closes, 1)
})

test("guest exec enables stdin before the broker sends EOF", async () => {
  let execOptions
  let ended = false
  const createVm = makeCreateVm(async () =>
    fakeVm(
      async () => undefined,
      async () => undefined,
      (_argv, options) => {
        execOptions = options
        return {
          result: Promise.resolve({ exitCode: 0 }),
          async *output() {},
          write: () => undefined,
          end: () => {
            if (options.stdin !== true) throw new Error("stdin was not enabled for this exec")
            ended = true
          },
        }
      },
    )
  )
  const vm = await Effect.runPromise(createVm(vmSpec))
  const process = await vm.exec({ argv: ["/bin/true"] })

  process.end()

  assert.equal(execOptions.stdin, true)
  assert.equal(ended, true)
})
