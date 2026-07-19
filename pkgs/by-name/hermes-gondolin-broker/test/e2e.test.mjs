import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { setGondolinSdkForTests } from "../dist/gondolin.js";
import { startBroker } from "../dist/main.js";
import { FakeProvider } from "./fakes.mjs";
import { FrameDecoder } from "../dist/protocol.js";

/**
 * End-to-end broker test: the real dist server, real AF_UNIX socket, real
 * framing/dispatch — with the VM provider faked at the Gondolin boundary.
 * Covers ensure/exec/fs/status/close, generation rotation, fail-closed
 * protocol behavior, and audit wiring over the wire.
 */

function writePolicy(dir) {
  const policy = {
    version: 1,
    policyId: "e2e",
    floor: {
      maxResources: {
        cpus: 2, memoryMiB: 2048, diskMiB: 4096, pidsMax: 128,
        maxOutputBytes: 65536, maxExecsPerVm: 8, maxCommandMs: 5000,
        ringBufferBytes: 4096,
      },
      maxVms: 3,
      maxVmStartsPerMinute: 30,
      maxFrameBytes: 65536,
      maxInputBytes: 65536,
    },
    assets: { general: { path: "/assets/general", buildId: "b1" } },
    bundles: { "pypi-public": { destinations: [{ kind: "exact", host: "pypi.org" }] } },
    credentialCapabilities: {},
    templates: {
      project: {
        version: 1,
        asset: "general",
        network: { mode: "bundles", bundles: ["pypi-public"] },
        workspace: { type: "private" },
      },
    },
    profiles: {
      "hermes-qa": {
        defaultTemplate: "project",
        allowedPairs: [{ asset: "general", template: "project" }],
        maximum: { networkBundles: ["pypi-public"] },
      },
    },
  };
  const policyPath = path.join(dir, "policy.json");
  fs.writeFileSync(policyPath, JSON.stringify(policy));
  return policyPath;
}

class Client {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    this.buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => this.#onData(chunk));
    socket.on("error", () => {});
  }

  #onData(chunk) {
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
    for (;;) {
      if (this.buffer.length < 4) return;
      const length = this.buffer.readUInt32LE(0);
      if (this.buffer.length < 4 + length) return;
      const body = this.buffer.subarray(4, 4 + length);
      this.buffer = this.buffer.subarray(4 + length);
      const frame = JSON.parse(body.toString());
      if (frame.event) {
        this.events.push(frame);
        for (const pending of this.pending.values()) pending.maybeEvent?.(frame);
        continue;
      }
      const pending = this.pending.get(frame.id);
      if (pending) {
        this.pending.delete(frame.id);
        pending(frame);
      }
    }
  }

  call(op, payload) {
    const id = this.nextId++;
    const body = Buffer.from(JSON.stringify({ v: 1, id, op, payload }), "utf8");
    const prefix = Buffer.alloc(4);
    prefix.writeUInt32LE(body.length, 0);
    this.socket.write(Buffer.concat([prefix, body]));
    return new Promise((resolve) => this.pending.set(id, resolve));
  }
}

test("broker end-to-end over a real unix socket", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "broker-e2e-"));
  const policyPath = writePolicy(dir);
  const sockPath = path.join(dir, "broker.sock");

  setGondolinSdkForTests({
    VM: { create: async () => { throw new Error("VM.create must not be called (provider injected)"); } },
    createHttpHooks: (options) => ({ httpHooks: { options } }),
  });

  const provider = new FakeProvider();
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(sockPath, resolve);
  });

  const broker = await startBroker({
    provider,
    listen: server,
    env: {
      HERMES_BROKER_POLICY: policyPath,
      HERMES_BROKER_PROFILE: "hermes-qa",
      HERMES_BROKER_STATE_DIR: dir,
      HERMES_BROKER_RUNTIME_DIR: path.join(dir, "run"),
    },
  });
  t.after(async () => {
    await broker.close();
    fs.rmSync(dir, { recursive: true, force: true });
    setGondolinSdkForTests(null);
  });

  const socket = net.connect(sockPath);
  await new Promise((resolve) => socket.once("connect", resolve));
  const client = new Client(socket);

  // unknown op → fail closed
  const badOp = await client.call("policy.set", {});
  assert.equal(badOp.ok, false);
  assert.equal(badOp.error.reason, "protocol.unknown_operation");

  // ensure → created
  const ensured = await client.call("ensure", { envKey: "conv-1" });
  assert.equal(ensured.ok, true);
  assert.equal(ensured.result.outcome, "created");
  assert.equal(provider.vms.length, 1);
  const generation = ensured.result.generation;

  // ensure again → resumed, same generation
  const resumed = await client.call("ensure", { envKey: "conv-1" });
  assert.equal(resumed.result.outcome, "resumed");
  assert.equal(resumed.result.generation, generation);

  // unknown template → policy fail closed
  const badTemplate = await client.call("ensure", { envKey: "conv-2", template: "ghost" });
  assert.equal(badTemplate.ok, false);

  // foreground exec with streamed output
  const execResponsePromise = client.call("exec.start", {
    envKey: "conv-1",
    argv: ["/bin/echo", "hello"],
  });
  // Wait for the server to process exec.start (socket round trip).
  for (let i = 0; i < 200 && provider.vms[0].handles.length === 0; i++) {
    await new Promise((r) => setImmediate(r));
  }
  assert.equal(provider.vms[0].handles.length, 1);
  const handle = provider.vms[0].handles[0];
  handle.emitOutput("stdout", "hello\n");
  handle.finish(0);
  const execResponse = await execResponsePromise;
  assert.equal(execResponse.ok, true);
  assert.equal(execResponse.result.exitCode, 0);
  const outputEvents = client.events.filter((e) => e.event === "exec.output");
  assert.equal(outputEvents.length, 1);
  assert.equal(Buffer.from(outputEvents[0].data, "base64").toString(), "hello\n");
  assert.ok(client.events.some((e) => e.event === "exec.exit"));

  // exec normalization failures surface policy reasons
  const badEnv = await client.call("exec.start", { envKey: "conv-1", argv: ["/bin/true"], env: { AWS_SECRET: "x" } });
  assert.equal(badEnv.ok, false);
  assert.equal(badEnv.error.reason, "resource.env_limit");

  // fs round-trip through the confined workspace
  const write = await client.call("fs.writeAtomic", {
    envKey: "conv-1",
    path: "notes.txt",
    data: Buffer.from("kanban").toString("base64"),
    mode: "replace",
  });
  assert.equal(write.ok, true);
  const read = await client.call("fs.read", { envKey: "conv-1", path: "notes.txt" });
  assert.equal(Buffer.from(read.result.data, "base64").toString(), "kanban");

  // traversal fails closed
  const escape = await client.call("fs.read", { envKey: "conv-1", path: "../../etc/passwd" });
  assert.equal(escape.ok, false);
  assert.equal(escape.error.reason, "fs.mount_escape");

  // status reports the active environment
  const status = await client.call("status", { envKey: "conv-1" });
  assert.equal(status.result.state, "active");
  assert.equal(status.result.generation, generation);

  // background process + wait + stale generation after rotation
  const bg = await client.call("exec.start", { envKey: "conv-1", argv: ["/bin/sleep", "60"], background: true });
  assert.equal(bg.result.background, true);
  const recreated = await client.call("ensure", { envKey: "conv-1", template: "project" });
  assert.equal(recreated.result.outcome, "resumed"); // same template → same generation
  const staleEnsure = await client.call("ensure", { envKey: "conv-1", template: "project", asset: "general" });
  assert.equal(staleEnsure.result.outcome, "resumed");

  // close → warm; old process handles fail stale
  const closed = await client.call("close", { envKey: "conv-1" });
  assert.equal(closed.result.state, "warm");
  const stale = await client.call("exec.cancel", { procId: bg.result.procId });
  assert.equal(stale.ok, false);

  // oversized frame → server sends error and closes the connection
  const raw = net.connect(sockPath);
  await new Promise((resolve) => raw.once("connect", resolve));
  const rawFrames = [];
  const rawDecoder = new FrameDecoder(1 << 20);
  raw.on("data", (chunk) => {
    for (const body of rawDecoder.push(chunk)) rawFrames.push(JSON.parse(body.toString()));
  });
  raw.on("error", () => {});
  const rawClosed = new Promise((resolve) => raw.once("close", resolve));
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32LE(1 << 20, 0);
  raw.write(prefix);
  await rawClosed;
  assert.equal(rawFrames.length, 1);
  assert.equal(rawFrames[0].error.reason, "protocol.frame_too_large");

  socket.end();
});
