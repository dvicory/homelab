import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { GrantManager } from "../dist/grants.js";
import { parsePolicy, composePolicy } from "../dist/policy.js";
import { Registry } from "../dist/registry.js";
import { REASONS } from "../dist/errors.js";

function stack(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "broker-grants-"));
  const registry = new Registry(path.join(dir, "registry.sqlite"));
  const grants = new GrantManager(registry);
  t.after(() => {
    registry.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  const policy = parsePolicy({
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
    bundles: { "pypi-public": { destinations: [{ kind: "exact", host: "pypi.org" }] } },
    credentialCapabilities: {},
    templates: {
      project: {
        version: 1,
        asset: "general",
        network: { mode: "bundles", bundles: ["pypi-public"] },
        workspace: { type: "private" },
        grantScopes: ["once", "task"],
        grantable: ["pypi-public"],
      },
    },
    profiles: {
      "hermes-qa": {
        defaultTemplate: "project",
        allowedPairs: [{ asset: "general", template: "project" }],
        maximum: { networkBundles: ["pypi-public"], grantScopes: ["once", "task"] },
      },
    },
  });
  registry.insertEnvironment({
    envKey: "env-1",
    profile: "hermes-qa",
    worklane: null,
    template: "project",
    asset: "general",
    buildId: "b1",
    policyHash: "h1",
    generation: "g1",
    workspacePath: null,
    state: "active",
    stateReason: null,
    createdAt: 1,
    lastActivityAt: 1,
  });
  return { grants, policy: composePolicy(policy, { profile: "hermes-qa" }) };
}

test("activation validates grantable and scope against the effective policy", (t) => {
  const { grants, policy } = stack(t);
  const grant = grants.activate("env-1", policy, { capability: "pypi-public", scope: "task" }, 1000);
  assert.equal(grant.capability, "pypi-public");
  assert.equal(grant.policyGeneration, policy.policyHash);
  assert.ok(grant.expiresAt > 1000);

  assert.throws(
    () => grants.activate("env-1", policy, { capability: "unknown", scope: "task" }, 1000),
    (err) => err.reason === REASONS.GRANT_NOT_GRANTABLE,
  );
  assert.throws(
    () => grants.activate("env-1", policy, { capability: "pypi-public", scope: "session" }, 1000),
    (err) => err.reason === REASONS.GRANT_SCOPE,
  );
});

test("expiry, revocation, and policy-generation binding", (t) => {
  const { grants, policy } = stack(t);
  const grant = grants.activate("env-1", policy, { capability: "pypi-public", scope: "once" }, 1000);
  assert.equal(grants.isActive("env-1", "pypi-public", policy, 2000), true);
  assert.equal(grants.isActive("env-1", "pypi-public", policy, grant.expiresAt + 1), false);

  const grant2 = grants.activate("env-1", policy, { capability: "pypi-public", scope: "task" }, 2000);
  grants.consumeOnce(grant, 2500); // retire the once grant so revocation is observable
  assert.equal(grants.revoke(grant2.grantId, 3000), true);
  assert.equal(grants.isActive("env-1", "pypi-public", policy, 4000), false);

  // once grants are consumed on first use
  const onceGrant = grants.activate("env-1", policy, { capability: "pypi-public", scope: "once" }, 4000);
  grants.consumeOnce(onceGrant, 5000);
  assert.equal(grants.isActive("env-1", "pypi-public", policy, 6000), false);

  // Stale policy generation: grant from an older hash is invisible.
  const grant3 = grants.activate("env-1", policy, { capability: "pypi-public", scope: "task" }, 6000);
  const stalePolicy = { ...policy, policyHash: "different-hash" };
  assert.equal(grants.isActive("env-1", "pypi-public", stalePolicy, 7000), false);
  assert.equal(grants.isActive("env-1", "pypi-public", policy, 7000), true);
});
