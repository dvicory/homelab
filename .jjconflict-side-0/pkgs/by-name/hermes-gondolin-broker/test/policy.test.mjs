import { test } from "node:test";
import assert from "node:assert/strict";
import {
  composePolicy,
  destinationToHostPatterns,
  parsePolicy,
} from "../dist/policy.js";
import { BrokerError, REASONS } from "../dist/errors.js";

function basePolicy() {
  return {
    version: 1,
    policyId: "test-policy",
    floor: {
      maxResources: {
        cpus: 4, memoryMiB: 8192, diskMiB: 32768, pidsMax: 512,
        maxOutputBytes: 8 * 1024 * 1024, maxExecsPerVm: 64, maxCommandMs: 600000,
        ringBufferBytes: 262144,
      },
      maxVms: 8,
      maxVmStartsPerMinute: 12,
      maxFrameBytes: 1048576,
      maxInputBytes: 1048576,
    },
    assets: {
      general: { path: "/nix/store/general", buildId: "build-general" },
      minimal: { path: "/nix/store/minimal", buildId: "build-minimal" },
    },
    bundles: {
      "pypi-public": {
        destinations: [
          { kind: "exact", host: "pypi.org" },
          { kind: "exact", host: "files.pythonhosted.org" },
        ],
      },
      "npm-public": {
        destinations: [{ kind: "host-and-subdomains", host: "npmjs.org" }],
      },
    },
    credentialCapabilities: {
      "github-push": {
        networkBundle: "pypi-public",
        adapter: "github",
        secretRef: "hermes-terminal-github",
        targets: [{ owner: "daniel-vicory", repositories: ["homelab-den"] }],
        actions: ["git.push"],
        activation: "approval",
        maximumGrantScope: "once",
      },
    },
    templates: {
      project: {
        version: 3,
        asset: "general",
        network: { mode: "bundles", bundles: ["pypi-public", "npm-public"] },
        workspace: { type: "project", project: "homelab" },
        resources: { cpus: 2, memoryMiB: 4096 },
        grantScopes: ["once", "task"],
        credentials: ["github-push"],
        grantable: ["pypi-public"],
      },
      offline: {
        version: 1,
        asset: "minimal",
        network: { mode: "deny-all" },
        workspace: { type: "private" },
      },
    },
    profiles: {
      "hermes-qa": {
        defaultTemplate: "project",
        allowedPairs: [
          { asset: "general", template: "project" },
          { asset: "minimal", template: "offline" },
          { asset: "general", template: "offline" },
        ],
        maximum: {
          networkBundles: ["pypi-public"],
          credentialCapabilities: ["github-push"],
          resources: { cpus: 4, memoryMiB: 8192 },
          grantScopes: ["once"],
        },
        worklanes: {
          codex: {
            defaultTemplate: "offline",
            allowedPairs: [{ asset: "minimal", template: "offline" }],
            maximum: { networkBundles: [] },
          },
        },
      },
    },
  };
}

test("parses a valid policy and composes with attenuation", () => {
  const policy = parsePolicy(basePolicy());
  const eff = composePolicy(policy, { profile: "hermes-qa" });

  assert.equal(eff.assetName, "general");
  assert.equal(eff.buildId, "build-general");
  assert.equal(eff.templateName, "project");
  assert.equal(eff.templateVersion, 3);
  // profile maximum intersects the template bundle list
  assert.deepEqual(eff.network, {
    mode: "bundles",
    destinations: [
      { kind: "exact", host: "pypi.org" },
      { kind: "exact", host: "files.pythonhosted.org" },
    ],
  });
  // numeric ceilings: template 2 CPUs wins over profile 4 and floor 4;
  // template does not set memory -> profile/floor 8192... template 4096 wins
  assert.equal(eff.resources.cpus, 2);
  assert.equal(eff.resources.memoryMiB, 4096);
  assert.equal(eff.resources.diskMiB, 32768);
  // grant scopes intersect to profile maximum
  assert.deepEqual(eff.grantScopes, ["once"]);
  assert.deepEqual(eff.credentials, ["github-push"]);
  // grantable survives only when within profile maximum
  assert.deepEqual(eff.grantable, ["pypi-public"]);
  assert.equal(typeof eff.policyHash, "string");
  assert.equal(eff.policyHash.length, 64);
});

test("worklane attenuates profile and selects its own pairs", () => {
  const policy = parsePolicy(basePolicy());
  const eff = composePolicy(policy, { profile: "hermes-qa", worklane: "codex" });
  assert.equal(eff.templateName, "offline");
  assert.equal(eff.assetName, "minimal");
  assert.deepEqual(eff.network, { mode: "deny-all" });

  assert.throws(
    () => composePolicy(policy, { profile: "hermes-qa", worklane: "codex", template: "project" }),
    (err) => err instanceof BrokerError && err.reason === REASONS.POLICY_PAIR_FORBIDDEN,
  );
});

test("unknown profile, worklane, template, and pair fail closed", () => {
  const policy = parsePolicy(basePolicy());
  for (const req of [
    { profile: "nope" },
    { profile: "hermes-qa", worklane: "nope" },
    { profile: "hermes-qa", template: "nope" },
    { profile: "hermes-qa", asset: "minimal" }, // pair general/project required
  ]) {
    assert.throws(() => composePolicy(policy, req), BrokerError);
  }
});

test("unknown versions and fields fail closed", () => {
  assert.throws(
    () => parsePolicy({ ...basePolicy(), version: 2 }),
    (err) => err instanceof BrokerError && err.reason === REASONS.POLICY_VERSION,
  );
  assert.throws(
    () => parsePolicy({ ...basePolicy(), surprise: true }),
    (err) => err instanceof BrokerError && err.reason === REASONS.POLICY_UNKNOWN_FIELD,
  );
  const badTemplate = basePolicy();
  badTemplate.templates.project.unexpected = 1;
  assert.throws(
    () => parsePolicy(badTemplate),
    (err) => err instanceof BrokerError && err.reason === REASONS.POLICY_UNKNOWN_FIELD,
  );
});

test("bundles may not lift the hard floor protocol denials", () => {
  const bad = basePolicy();
  bad.bundles["pypi-public"].allowWebSockets = true;
  assert.throws(
    () => parsePolicy(bad),
    (err) => err instanceof BrokerError && err.reason === REASONS.POLICY_ATTENUATION,
  );
});

test("destination validation rejects wildcards, IP literals, bad ports", () => {
  for (const host of ["*.pypi.org", "10.0.0.1", "2001:db8::1", "", "bad host"]) {
    const bad = basePolicy();
    bad.bundles["pypi-public"].destinations = [{ kind: "exact", host }];
    assert.throws(() => parsePolicy(bad), BrokerError, `host ${JSON.stringify(host)}`);
  }
  for (const base of ["com", "co.uk", "github.io", "io"]) {
    const bad = basePolicy();
    bad.bundles["pypi-public"].destinations = [{ kind: "subdomains", host: base }];
    assert.throws(
      () => parsePolicy(bad),
      (err) => err instanceof BrokerError && err.reason === REASONS.POLICY_INVALID,
      `public suffix ${base}`,
    );
  }
  const badPort = basePolicy();
  badPort.bundles["pypi-public"].destinations = [{ kind: "exact", host: "pypi.org", ports: [0] }];
  assert.throws(() => parsePolicy(badPort), BrokerError);
});

test("cross references fail closed", () => {
  const missingBundle = basePolicy();
  missingBundle.templates.project.network.bundles = ["ghost"];
  assert.throws(
    () => parsePolicy(missingBundle),
    (err) => err instanceof BrokerError && err.reason === REASONS.POLICY_UNKNOWN_BUNDLE,
  );

  const missingAsset = basePolicy();
  missingAsset.templates.project.asset = "ghost";
  assert.throws(
    () => parsePolicy(missingAsset),
    (err) => err instanceof BrokerError && err.reason === REASONS.POLICY_UNKNOWN_ASSET,
  );

  const badDefault = basePolicy();
  badDefault.profiles["hermes-qa"].defaultTemplate = "offline";
  badDefault.profiles["hermes-qa"].allowedPairs = [{ asset: "general", template: "project" }];
  assert.throws(
    () => parsePolicy(badDefault),
    (err) => err instanceof BrokerError && err.reason === REASONS.POLICY_PAIR_FORBIDDEN,
  );
});

test("destination rules render to gondolin host patterns", () => {
  assert.deepEqual(destinationToHostPatterns({ kind: "exact", host: "pypi.org" }), ["pypi.org"]);
  assert.deepEqual(destinationToHostPatterns({ kind: "subdomains", host: "pypi.org" }), ["*.pypi.org"]);
  assert.deepEqual(destinationToHostPatterns({ kind: "host-and-subdomains", host: "pypi.org" }), [
    "pypi.org",
    "*.pypi.org",
  ]);
});

test("the allowed pair selects the asset; template.asset is only a default", () => {
  const policy = parsePolicy(basePolicy());
  // offline defaults to the minimal asset via template.asset
  const minimal = composePolicy(policy, { profile: "hermes-qa", template: "offline" });
  assert.equal(minimal.assetName, "minimal");
  assert.equal(minimal.buildId, "build-minimal");
  // the same template pairs with general when explicitly requested
  const general = composePolicy(policy, { profile: "hermes-qa", template: "offline", asset: "general" });
  assert.equal(general.assetName, "general");
  assert.equal(general.buildId, "build-general");
  // generations differ across the two assets
  assert.notEqual(general.policyHash, minimal.policyHash);
});

test("generation-relevant identity changes the policy hash", () => {
  const policy = parsePolicy(basePolicy());
  const a = composePolicy(policy, { profile: "hermes-qa" });
  const b = composePolicy(policy, { profile: "hermes-qa", worklane: "codex" });
  assert.notEqual(a.policyHash, b.policyHash);
});
