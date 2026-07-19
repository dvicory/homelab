#!/usr/bin/env node
/**
 * Broker smoke client (V3 §19 Phase 3 gate evidence).
 *
 * Drives a running hermes-gondolin-broker over its Unix socket and checks
 * the credential-free spike contract end to end: ensure, foreground exec
 * with bounded streams, VFS round-trip, background cancel, hard close,
 * generation reporting, and fail-closed network/policy behavior. Exits 0
 * only when every check passes.
 *
 * Usage: hermes-gondolin-broker-smoke <socket-path> [env-key]
 */
import net from "node:net";

const SOCKET = process.argv[2];
const ENV_KEY = process.argv[3] ?? `smoke-${process.pid}`;

if (!SOCKET) {
  process.stderr.write("usage: hermes-gondolin-broker-smoke <socket-path> [env-key]\n");
  process.exit(2);
}

let nextId = 1;
const pending = new Map();
const events = [];
let buffer = Buffer.alloc(0);

const socket = net.connect(SOCKET);
socket.on("error", (err) => {
  process.stderr.write(`socket error: ${err.message}\n`);
  process.exit(3);
});

socket.on("data", (chunk) => {
  buffer = buffer.length === 0 ? chunk : Buffer.concat([buffer, chunk]);
  for (;;) {
    if (buffer.length < 4) return;
    const length = buffer.readUInt32LE(0);
    if (buffer.length < 4 + length) return;
    const body = buffer.subarray(4, 4 + length);
    buffer = buffer.subarray(4 + length);
    const frame = JSON.parse(body.toString());
    if (frame.event) {
      events.push(frame);
      continue;
    }
    const resolve = pending.get(frame.id);
    if (resolve) {
      pending.delete(frame.id);
      resolve(frame);
    }
  }
});

function call(op, payload) {
  const id = nextId++;
  const body = Buffer.from(JSON.stringify({ v: 1, id, op, payload }), "utf8");
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32LE(body.length, 0);
  socket.write(Buffer.concat([prefix, body]));
  return new Promise((resolve, reject) => {
    pending.set(id, resolve);
    setTimeout(() => reject(new Error(`${op}: timed out waiting for response`)), 120_000);
  });
}

const checks = [];
async function check(name, fn) {
  try {
    const detail = await fn();
    checks.push([name, true, detail ?? ""]);
    process.stdout.write(`ok   ${name}${detail ? ` — ${detail}` : ""}\n`);
  } catch (err) {
    checks.push([name, false, err.message]);
    process.stdout.write(`FAIL ${name} — ${err.message}\n`);
  }
}
function expect(condition, message) {
  if (!condition) throw new Error(message);
}

await new Promise((resolve, reject) => {
  socket.once("connect", resolve);
  socket.once("error", reject);
  setTimeout(() => reject(new Error("connect timeout")), 10_000);
});

let generation = null;

await check("ensure creates an environment with a generation", async () => {
  const res = await call("ensure", { envKey: ENV_KEY });
  expect(res.ok, `ensure failed: ${res.error?.message}`);
  expect(res.result.outcome === "created", `outcome ${res.result.outcome}`);
  expect(typeof res.result.generation === "string", "no generation");
  expect(typeof res.result.buildId === "string" && res.result.buildId.length > 0, "no buildId");
  generation = res.result.generation;
  return `generation ${generation.slice(0, 12)}… buildId ${res.result.buildId.slice(0, 12)}…`;
});

await check("ensure resumes the same generation", async () => {
  const res = await call("ensure", { envKey: ENV_KEY });
  expect(res.ok && res.result.outcome === "resumed", JSON.stringify(res));
  expect(res.result.generation === generation, "generation changed");
});

await check("foreground argv exec returns exit code and ordered output", async () => {
  const res = await call("exec.start", {
    envKey: ENV_KEY,
    argv: ["/bin/sh", "-lc", "printf 'out'; printf 'err' >&2; exit 3"],
  });
  expect(res.ok, `exec failed: ${res.error?.message}`);
  expect(res.result.exitCode === 3, `exitCode ${res.result.exitCode}`);
  const stdout = events.filter((e) => e.event === "exec.output" && e.stream === "stdout");
  const stderr = events.filter((e) => e.event === "exec.output" && e.stream === "stderr");
  expect(stdout.length > 0, "no stdout frame");
  expect(stderr.length > 0, "no stderr frame");
  expect(events.some((e) => e.event === "exec.exit"), "no exit frame");
});

await check("binary output is byte-exact", async () => {
  const before = events.length;
  const res = await call("exec.start", {
    envKey: ENV_KEY,
    argv: ["/bin/sh", "-lc", "printf '\\000\\001\\377\\002'"],
  });
  expect(res.ok, `exec failed: ${res.error?.message}`);
  const frames = events.slice(before).filter((e) => e.event === "exec.output" && e.stream === "stdout");
  const data = Buffer.concat(frames.map((f) => Buffer.from(f.data, "base64")));
  expect(Buffer.compare(data, Buffer.from([0, 1, 255, 2])) === 0, `bytes ${data.toString("hex")}`);
});

await check("VFS write/read/stat/list round-trip stays confined", async () => {
  const payload = Buffer.from("smoke-vfs");
  const write = await call("fs.writeAtomic", {
    envKey: ENV_KEY,
    path: "smoke.txt",
    data: payload.toString("base64"),
    mode: "replace",
  });
  expect(write.ok, `write failed: ${write.error?.message}`);
  const read = await call("fs.read", { envKey: ENV_KEY, path: "smoke.txt" });
  expect(read.ok && Buffer.from(read.result.data, "base64").equals(payload), "read mismatch");
  const stat = await call("fs.stat", { envKey: ENV_KEY, path: "smoke.txt" });
  expect(stat.ok && stat.result.type === "file", "stat mismatch");
  const list = await call("fs.list", { envKey: ENV_KEY, path: "." });
  expect(list.ok && list.result.entries.some((e) => e.name === "smoke.txt"), "list missing file");
});

await check("path traversal fails closed", async () => {
  const res = await call("fs.read", { envKey: ENV_KEY, path: "../../etc/passwd" });
  expect(!res.ok && res.error.reason === "fs.mount_escape", JSON.stringify(res.error));
});

await check("env allowlist rejects credential-shaped variables", async () => {
  const res = await call("exec.start", {
    envKey: ENV_KEY,
    argv: ["/bin/true"],
    env: { GITHUB_TOKEN: "x" },
  });
  expect(!res.ok && res.error.reason === "resource.env_limit", JSON.stringify(res.error));
});

await check("background cancel reports cancellation", async () => {
  const bg = await call("exec.start", { envKey: ENV_KEY, argv: ["/bin/sleep", "600"], background: true });
  expect(bg.ok, `background start failed: ${bg.error?.message}`);
  const cancelled = await call("exec.cancel", { procId: bg.result.procId });
  expect(cancelled.ok && cancelled.result.reason === "cancelled", JSON.stringify(cancelled));
});

await check("status reports the active environment", async () => {
  const res = await call("status", { envKey: ENV_KEY });
  expect(res.ok && res.result.state === "active", JSON.stringify(res.result));
  expect(res.result.generation === generation, "generation drift");
});

await check("unknown operation fails closed", async () => {
  const res = await call("policy.set", {});
  expect(!res.ok && res.error.reason === "protocol.unknown_operation", JSON.stringify(res.error));
});

await check("close goes warm and stale handles fail", async () => {
  const bg = await call("exec.start", { envKey: ENV_KEY, argv: ["/bin/sleep", "600"], background: true });
  expect(bg.ok, `background start failed: ${bg.error?.message}`);
  const closed = await call("close", { envKey: ENV_KEY });
  expect(closed.ok && closed.result.state === "warm", JSON.stringify(closed));
  const stale = await call("exec.cancel", { procId: bg.result.procId });
  expect(!stale.ok, `stale handle accepted: ${JSON.stringify(stale)}`);
});

await check("re-ensure after close recreates with a machine-readable reason", async () => {
  const res = await call("ensure", { envKey: ENV_KEY });
  expect(res.ok && res.result.outcome === "recreated", JSON.stringify(res));
  expect(typeof res.result.reason === "string" && res.result.reason.length > 0, "no reason");
  generation = res.result.generation;
});

await check("anonymous HTTPS through the curated bundle works", async () => {
  const res = await call("exec.start", {
    envKey: ENV_KEY,
    argv: ["/bin/sh", "-lc", "curl -fsS -o /dev/null -w '%{http_code}' https://pypi.org/simple/"],
    timeoutMs: 60000,
  });
  expect(res.ok, `exec failed: ${res.error?.message}`);
  const frames = events.filter((e) => e.event === "exec.output" && e.stream === "stdout").slice(-3);
  const out = frames.map((f) => Buffer.from(f.data, "base64").toString()).join("");
  expect(res.result.exitCode === 0 && out.includes("200"), `http status ${out} exit ${res.result.exitCode}`);
});

await check("off-bundle destinations are denied", async () => {
  const res = await call("exec.start", {
    envKey: ENV_KEY,
    argv: ["/bin/sh", "-lc", "curl -fsS -m 15 -o /dev/null https://example.com/ ; echo exit=$?"],
    timeoutMs: 30000,
  });
  expect(res.ok, `exec failed: ${res.error?.message}`);
  const frames = events.filter((e) => e.event === "exec.output" && e.stream === "stdout").slice(-2);
  const out = frames.map((f) => Buffer.from(f.data, "base64").toString()).join("");
  expect(!out.includes("exit=0"), `expected curl failure, got ${out}`);
});

await check("internal addresses are denied", async () => {
  const res = await call("exec.start", {
    envKey: ENV_KEY,
    argv: ["/bin/sh", "-lc", "curl -fsS -m 10 -o /dev/null http://169.254.169.254/ ; echo exit=$?"],
    timeoutMs: 30000,
  });
  expect(res.ok, `exec failed: ${res.error?.message}`);
  const frames = events.filter((e) => e.event === "exec.output" && e.stream === "stdout").slice(-2);
  const out = frames.map((f) => Buffer.from(f.data, "base64").toString()).join("");
  expect(!out.includes("exit=0"), `expected metadata denial, got ${out}`);
});

await check("no secret material exists in the guest environment", async () => {
  const res = await call("exec.start", {
    envKey: ENV_KEY,
    argv: ["/bin/sh", "-lc", "env | grep -iE 'token|secret|password|credential|pat' ; echo count=$(env | grep -icE 'token|secret|password|credential|pat')"],
  });
  expect(res.ok, `exec failed: ${res.error?.message}`);
  const frames = events.filter((e) => e.event === "exec.output" && e.stream === "stdout").slice(-2);
  const out = frames.map((f) => Buffer.from(f.data, "base64").toString()).join("");
  expect(out.includes("count=0"), `secret-shaped env present: ${out}`);
});

const failed = checks.filter(([, ok]) => !ok);
process.stdout.write(`\n${checks.length - failed.length}/${checks.length} smoke checks passed\n`);
socket.end();
process.exit(failed.length === 0 ? 0 : 1);
