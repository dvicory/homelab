import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Registry } from "../dist/registry.js";

function freshRegistry(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "broker-registry-"));
  const registry = new Registry(path.join(dir, "registry.sqlite"));
  t.after(() => {
    registry.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return registry;
}

const ENV = {
  envKey: "conversation-abc",
  profile: "hermes-qa",
  worklane: null,
  template: "project",
  asset: "general",
  buildId: "build-1",
  policyHash: "hash-1",
  generation: "gen-1",
  workspacePath: "/var/lib/sandbox/conversations/conversation-abc",
  state: "active",
  stateReason: null,
  createdAt: 1000,
  lastActivityAt: 1000,
};

test("environment lifecycle rows round-trip and update", (t) => {
  const registry = freshRegistry(t);
  registry.insertEnvironment(ENV);
  assert.deepEqual(registry.getEnvironment(ENV.envKey), ENV);
  assert.equal(registry.getEnvironment("missing"), null);

  registry.updateEnvironmentState(ENV.envKey, "closing", "client_close", 2000);
  const updated = registry.getEnvironment(ENV.envKey);
  assert.equal(updated.state, "closing");
  assert.equal(updated.stateReason, "client_close");
  assert.equal(updated.lastActivityAt, 2000);
});

test("generation rotation replaces identity fields atomically", (t) => {
  const registry = freshRegistry(t);
  registry.insertEnvironment(ENV);
  registry.rotateEnvironment({ ...ENV, generation: "gen-2", policyHash: "hash-2", state: "recreating" });
  const row = registry.getEnvironment(ENV.envKey);
  assert.equal(row.generation, "gen-2");
  assert.equal(row.policyHash, "hash-2");
  assert.equal(row.state, "recreating");
});

test("tombstones are idempotent and survive deletion", (t) => {
  const registry = freshRegistry(t);
  registry.transaction(() => {
    registry.insertTombstone({ envKey: ENV.envKey, generation: "gen-1", deletedAt: 5000, reason: "client_close" });
    registry.insertEnvironment(ENV);
    registry.deleteEnvironment(ENV.envKey);
  });
  registry.insertTombstone({ envKey: ENV.envKey, generation: "gen-1", deletedAt: 6000, reason: "duplicate" });

  const tombstone = registry.getTombstone(ENV.envKey);
  assert.equal(tombstone.deletedAt, 5000);
  assert.equal(registry.getEnvironment(ENV.envKey), null);
});

test("process rows track state and expiry", (t) => {
  const registry = freshRegistry(t);
  registry.insertEnvironment(ENV);
  const proc = {
    procId: "p1",
    envKey: ENV.envKey,
    generation: "gen-1",
    mode: "background",
    cwd: "/data",
    state: "running",
    exitCode: null,
    signal: null,
    cancelReason: null,
    startedAt: 1000,
    endedAt: null,
    expiresAt: null,
  };
  registry.insertProcess(proc);
  assert.deepEqual(registry.getProcess("p1"), proc);
  assert.equal(registry.listProcesses({ envKey: ENV.envKey, state: "running" }).length, 1);

  registry.finishProcess("p1", "exited", 0, null, null, 2000);
  registry.insertProcess({ ...proc, procId: "p2", expiresAt: 3000, state: "exited", endedAt: 2500 });
  assert.equal(registry.deleteExpiredProcesses(4000), 1);
  assert.equal(registry.getProcess("p2"), null);
});

test("grants activate, expire, and revoke deterministically", (t) => {
  const registry = freshRegistry(t);
  registry.insertEnvironment(ENV);
  const grant = {
    grantId: "g1",
    envKey: ENV.envKey,
    capability: "pypi-public",
    scope: "task",
    policyGeneration: "gen-1",
    createdAt: 1000,
    expiresAt: 5000,
    revokedAt: null,
  };
  registry.insertGrant(grant);
  assert.equal(registry.activeGrant(ENV.envKey, "pypi-public", 2000)?.grantId, "g1");
  assert.equal(registry.activeGrant(ENV.envKey, "pypi-public", 6000), null);

  registry.insertGrant({ ...grant, grantId: "g2", expiresAt: null });
  assert.equal(registry.revokeGrant("g2", 7000), 1);
  assert.equal(registry.activeGrant(ENV.envKey, "pypi-public", 8000), null);
  assert.equal(registry.listGrants(ENV.envKey, 8000).length, 0);
});

test("transactions roll back on failure", (t) => {
  const registry = freshRegistry(t);
  assert.throws(() =>
    registry.transaction(() => {
      registry.insertEnvironment(ENV);
      throw new Error("boom");
    }),
  );
  assert.equal(registry.getEnvironment(ENV.envKey), null);
});

test("foreign keys are enforced", (t) => {
  const registry = freshRegistry(t);
  assert.throws(() =>
    registry.insertProcess({
      procId: "orphan",
      envKey: "ghost",
      generation: "gen-1",
      mode: "foreground",
      cwd: null,
      state: "running",
      exitCode: null,
      signal: null,
      cancelReason: null,
      startedAt: 1,
      endedAt: null,
      expiresAt: null,
    }),
  );
});
