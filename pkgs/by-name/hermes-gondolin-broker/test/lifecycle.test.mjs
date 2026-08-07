import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { AuditLog } from "../dist/audit.js";
import { CgroupManager } from "../dist/cgroups.js";
import { ExecManager } from "../dist/exec.js";
import { LifecycleManager } from "../dist/lifecycle.js";
import { buildRequestHook, isInternalAddress, normalizeRequestUrl } from "../dist/network.js";
import { parsePolicy, composePolicy } from "../dist/policy.js";
import { Registry } from "../dist/registry.js";
import { REASONS } from "../dist/errors.js";
import { FakeProvider } from "./fakes.mjs";
import { DatabaseSync } from "node:sqlite";

function policyFixture() {
  return parsePolicy({
    version: 1,
    policyId: "fixture",
    floor: {
      maxResources: {
        cpus: 2, memoryMiB: 2048, diskMiB: 4096, pidsMax: 128,
        maxOutputBytes: 4096, maxExecsPerVm: 8, maxCommandMs: 5000,
        ringBufferBytes: 1024,
      },
      maxVms: 3,
      maxVmStartsPerMinute: 30,
      maxFrameBytes: 1048576,
      maxInputBytes: 65536,
    },
    assets: { general: { path: "/assets/general", buildId: "b1" } },
    bundles: {
      "pypi-public": {
        destinations: [
          { kind: "exact", host: "pypi.org" },
          { kind: "subdomains", host: "pythonhosted.org" },
        ],
      },
    },
    credentialCapabilities: {},
    templates: {
      project: {
        version: 1,
        asset: "general",
        network: { mode: "bundles", bundles: ["pypi-public"] },
        workspace: { type: "private" },
        envAllow: ["EDITOR"],
      },
      offline: {
        version: 1,
        asset: "general",
        network: { mode: "deny-all" },
        workspace: { type: "private" },
      },
      research: {
        version: 1,
        asset: "general",
        network: { mode: "public-anonymous" },
        workspace: { type: "private" },
      },
    },
    profiles: {
      "hermes-qa": {
        defaultTemplate: "project",
        allowedPairs: [
          { asset: "general", template: "project" },
          { asset: "general", template: "offline" },
          { asset: "general", template: "research" },
        ],
        maximum: { networkBundles: ["pypi-public"] },
      },
    },
  });
}

function stack(t, policy = policyFixture()) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "broker-lifecycle-"));
  const registry = new Registry(path.join(dir, "registry.sqlite"));
  const audit = new AuditLog(registry.db);
  const provider = new FakeProvider();
  const cgroups = new CgroupManager("/nonexistent-cgroup-root"); // disabled off-Linux
  const lifecycle = new LifecycleManager({
    registry,
    audit,
    provider,
    cgroups,
    paths: { stateDir: dir, runtimeDir: path.join(dir, "run") },
    buildNetwork: async () => ({ httpHooks: {}, dns: {}, allowWebSockets: false }),
  });
  const exec = new ExecManager(registry, audit, {
    get: (envKey) => lifecycle.getLive(envKey),
    destroyVm: async (envKey) => lifecycle.close(envKey).catch(() => {}),
  });
  lifecycle.attachExecManager(exec);
  t.after(() => {
    registry.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return { registry, audit, provider, lifecycle, exec, policy, dir };
}

const ENV_KEY = "conversation-abc123";

test("ensure creates, resumes, and recreates with generation identity", async (t) => {
  const { lifecycle, policy, provider } = stack(t);
  const effective = composePolicy(policy, { profile: "hermes-qa" });

  const first = await lifecycle.ensure({ envKey: ENV_KEY, policy: effective });
  assert.equal(first.outcome, "created");
  assert.equal(provider.vms.length, 1);

  const second = await lifecycle.ensure({ envKey: ENV_KEY, policy: effective });
  assert.equal(second.outcome, "resumed");
  assert.equal(second.generation, first.generation);
  assert.equal(provider.vms.length, 1);

  // A template change yields a new generation and a new VM.
  const offline = composePolicy(policy, { profile: "hermes-qa", template: "offline" });
  const third = await lifecycle.ensure({ envKey: ENV_KEY, policy: offline });
  assert.equal(third.outcome, "recreated");
  assert.equal(third.reason, "generation_changed");
  assert.notEqual(third.generation, first.generation);
  assert.equal(provider.vms.length, 2);
  assert.equal(provider.vms[0].closed, true);
});

test("close goes warm; tombstoned environments cannot be ensured", async (t) => {
  const { lifecycle, policy, registry } = stack(t);
  const effective = composePolicy(policy, { profile: "hermes-qa" });
  await lifecycle.ensure({ envKey: ENV_KEY, policy: effective });

  const closed = await lifecycle.close(ENV_KEY);
  assert.equal(closed.state, "warm");
  assert.equal(registry.getEnvironment(ENV_KEY).state, "warm");

  // warm → recreating → active
  const resumed = await lifecycle.ensure({ envKey: ENV_KEY, policy: effective });
  assert.equal(resumed.outcome, "recreated");
  assert.equal(registry.getEnvironment(ENV_KEY).state, "active");

  await lifecycle.delete(ENV_KEY, "test_done");
  assert.equal(registry.getEnvironment(ENV_KEY), null);
  assert.ok(registry.getTombstone(ENV_KEY));
  await assert.rejects(
    () => lifecycle.ensure({ envKey: ENV_KEY, policy: effective }),
    (err) => err.reason === REASONS.ENV_TOMBSTONED,
  );
});

test("generation tags gate exec handles; stale handles never retarget", async (t) => {
  const { lifecycle, exec, policy, provider } = stack(t);
  const effective = composePolicy(policy, { profile: "hermes-qa" });
  await lifecycle.ensure({ envKey: ENV_KEY, policy: effective });

  const started = exec.start(ENV_KEY, { argv: ["/bin/sleep", "100"], background: true }, null);
  provider.vms[0].handles[0].emitOutput("stdout", "hello");
  const ring1 = exec.ringSnapshot(started.procId);
  assert.equal(ring1.data.toString(), "hello");

  // Rotate the generation: the old handle is now stale.
  const offline = composePolicy(policy, { profile: "hermes-qa", template: "offline" });
  await lifecycle.ensure({ envKey: ENV_KEY, policy: offline });

  assert.throws(
    () => exec.stdin(started.procId, Buffer.from("x")),
    (err) => err.reason === REASONS.STALE_GENERATION,
  );
  await assert.rejects(
    () => exec.cancel(started.procId),
    (err) => err.reason === REASONS.STALE_GENERATION,
  );
});

test("exec normalization: argv default, shell explicit, env allowlist, cwd confinement", async (t) => {
  const { lifecycle, exec, policy, provider } = stack(t);
  const effective = composePolicy(policy, { profile: "hermes-qa" });
  await lifecycle.ensure({ envKey: ENV_KEY, policy: effective });

  // argv required unless shell is explicit
  assert.throws(
    () => exec.start(ENV_KEY, {}, null),
    (err) => err.reason === REASONS.PROTOCOL_FRAME,
  );
  // env allowlist: EDITOR allowed by template, GITHUB_TOKEN denied always,
  // RANDOM_VAR not on the allowlist
  assert.throws(
    () => exec.start(ENV_KEY, { argv: ["/bin/true"], env: { GITHUB_TOKEN: "x" } }, null),
    (err) => err.reason === REASONS.RESOURCE_ENV,
  );
  assert.throws(
    () => exec.start(ENV_KEY, { argv: ["/bin/true"], env: { RANDOM_VAR: "x" } }, null),
    (err) => err.reason === REASONS.RESOURCE_ENV,
  );
  const ok = exec.start(ENV_KEY, { argv: ["/bin/true"], env: { EDITOR: "vim" } }, null);
  assert.equal(provider.vms[0].execCalls[0].env.EDITOR, "vim");
  provider.vms[0].handles.at(-1).finish(0);

  // cwd must stay under the workspace root
  assert.throws(
    () => exec.start(ENV_KEY, { argv: ["/bin/true"], cwd: "/etc" }, null),
    (err) => err.reason === REASONS.FS_ESCAPE,
  );
  // shell is explicit
  const shellExec = exec.start(ENV_KEY, { shell: "echo hi" }, null);
  assert.deepEqual(provider.vms[0].execCalls.at(-1).argv, ["/bin/sh", "-lc", "echo hi"]);
  provider.vms[0].handles.at(-1).finish(0);
  assert.ok(shellExec.procId);
});

test("foreground streams are bounded with truncation and completion metadata", async (t) => {
  const { lifecycle, exec, policy, provider } = stack(t);
  const effective = composePolicy(policy, { profile: "hermes-qa" });
  await lifecycle.ensure({ envKey: ENV_KEY, policy: effective });

  const frames = [];
  const sink = {
    output: (procId, stream, seq, data, truncated) => frames.push({ stream, seq, data: data.toString(), truncated }),
    exit: (procId, result) => frames.push({ exit: true, ...result }),
  };
  exec.start(ENV_KEY, { argv: ["/bin/yes"] }, sink);
  const handle = provider.vms[0].handles[0];
  handle.emitOutput("stdout", Buffer.alloc(3000, 0x61));
  handle.emitOutput("stdout", Buffer.alloc(3000, 0x62)); // exceeds 4096 cap
  handle.emitOutput("stderr", "oops");
  handle.finish(0);
  await new Promise((r) => setImmediate(r));

  const stdout = frames.filter((f) => f.stream === "stdout");
  assert.equal(stdout[0].data.length, 3000);
  assert.equal(stdout[1].data.length, 1096); // capped remainder
  assert.equal(stdout[1].truncated, true);
  const exit = frames.find((f) => f.exit);
  assert.equal(exit.exitCode, 0);
  assert.equal(exit.truncated, true);
});

test("hard cancel escalates and reports reason; timeout kills", async (t) => {
  const { lifecycle, exec, policy, provider } = stack(t);
  const effective = composePolicy(policy, { profile: "hermes-qa" });
  await lifecycle.ensure({ envKey: ENV_KEY, policy: effective });

  const started = exec.start(ENV_KEY, { argv: ["/bin/sleep", "100"] }, null);
  const completion = await exec.cancel(started.procId);
  assert.equal(completion.reason, "cancelled");
  assert.equal(provider.vms[0].handles[0].killed, true);

  // timeout: maxCommandMs from the fixture floor
  const timed = exec.start(ENV_KEY, { argv: ["/bin/sleep", "100"], timeoutMs: 50 }, null);
  const result = await exec.wait(timed.procId, 5000);
  assert.equal(result.reason, "timeout");
});

test("admission: concurrent VM ceiling is enforced", async (t) => {
  const { lifecycle, policy } = stack(t);
  const effective = composePolicy(policy, { profile: "hermes-qa" });
  await lifecycle.ensure({ envKey: "env-1", policy: effective });
  await lifecycle.ensure({ envKey: "env-2", policy: effective });
  await lifecycle.ensure({ envKey: "env-3", policy: effective });
  await assert.rejects(
    () => lifecycle.ensure({ envKey: "env-4", policy: effective }),
    (err) => err.reason === REASONS.ADMISSION_VMS,
  );
});

test("request hook: bundles, deny-all, public-anonymous, IP literals, ports", () => {
  const policy = policyFixture();
  const project = composePolicy(policy, { profile: "hermes-qa" });
  const hook = buildRequestHook(project);

  const allow = (url) => hook(normalizeRequestUrl(url, "GET"));
  assert.equal(allow("https://pypi.org/simple/").allow, true);
  assert.equal(allow("https://files.pythonhosted.org/x").allow, true);
  assert.equal(allow("https://pythonhosted.org/x").allow, false); // subdomains only
  assert.equal(allow("https://evil.com/").allow, false);
  assert.equal(allow("https://pypi.org.evil.com/").allow, false);
  assert.equal(allow("https://10.1.2.3/").allow, false); // IP literal
  assert.equal(allow("http://pypi.org/").allow, false); // http not in bundle ports

  const offline = composePolicy(policy, { profile: "hermes-qa", template: "offline" });
  const denyHook = buildRequestHook(offline);
  assert.equal(denyHook(normalizeRequestUrl("https://pypi.org/", "GET")).allow, false);

  const research = composePolicy(policy, { profile: "hermes-qa", template: "research" });
  const anonHook = buildRequestHook(research);
  assert.equal(anonHook(normalizeRequestUrl("https://anything.example/", "GET")).allow, true);
  assert.equal(anonHook(normalizeRequestUrl("http://anything.example/", "GET")).allow, false);
  assert.equal(anonHook(normalizeRequestUrl("https://anything.example:8443/", "GET")).allow, false);
  assert.equal(anonHook(normalizeRequestUrl("https://192.168.1.1/", "GET")).allow, false);
});

test("internal address classification: v4, v6, mapped, documentation", () => {
  for (const ip of [
    "10.0.0.1", "192.168.0.1", "172.16.0.1", "127.0.0.1", "169.254.1.1",
    "169.254.169.254", "0.0.0.0", "100.64.0.1", "224.0.0.1", "240.0.0.1",
    "192.0.2.1", "198.51.100.1", "203.0.113.1",
    "::1", "::", "fe80::1", "fc00::1", "fd00::1", "ff02::1",
    "::ffff:10.0.0.1", "2001:db8::1",
  ]) {
    assert.equal(isInternalAddress(ip), true, ip);
  }
  for (const ip of ["8.8.8.8", "1.1.1.1", "151.101.0.1", "2606:4700::1", "2a00:1450::1"]) {
    assert.equal(isInternalAddress(ip), false, ip);
  }
});

test("audit log redacts secrets and bounds metadata", async (t) => {
  const { audit } = stack(t);
  audit.emit({
    ts: 1,
    profile: "p",
    worklane: null,
    envKey: "e",
    generation: "g",
    requestId: 1,
    event: "net.decision",
    reason: "network.host_denied",
    layer: "template",
    metadata: {
      host: "pypi.org",
      command: "pip install x",
      headers: { authorization: "bearer x" },
      token: "secret",
      nested: { no: true },
    },
  });
  const rows = audit.query({ envKey: "e" });
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].metadata, { host: "pypi.org" });
});
