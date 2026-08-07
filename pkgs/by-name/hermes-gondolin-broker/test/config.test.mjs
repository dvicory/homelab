import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { resolveAssetBuildIds } from "../dist/config.js";
import { REASONS } from "../dist/errors.js";

function assetDir(t, manifest) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "broker-assets-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  if (manifest !== null) {
    fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify(manifest));
  }
  return dir;
}

const POLICY_BASE = {
  version: 1,
  policyId: "x",
  floor: {},
  assets: {},
  bundles: {},
  credentialCapabilities: {},
  templates: {},
  profiles: {},
};

test("buildId resolves from the immutable manifest", (t) => {
  const dir = assetDir(t, { version: 1, buildId: "abc-123" });
  const resolved = resolveAssetBuildIds({
    ...POLICY_BASE,
    assets: { general: { path: dir } },
  });
  assert.equal(resolved.assets.general.buildId, "abc-123");
});

test("a pinned buildId must match the manifest; mismatches fail closed", (t) => {
  const dir = assetDir(t, { version: 1, buildId: "abc-123" });
  const ok = resolveAssetBuildIds({
    ...POLICY_BASE,
    assets: { general: { path: dir, buildId: "abc-123" } },
  });
  assert.equal(ok.assets.general.buildId, "abc-123");

  assert.throws(
    () =>
      resolveAssetBuildIds({
        ...POLICY_BASE,
        assets: { general: { path: dir, buildId: "different" } },
      }),
    (err) => err.reason === REASONS.POLICY_INVALID && /does not match/.test(err.message),
  );
});

test("missing manifests and missing buildIds fail closed", (t) => {
  const noManifest = assetDir(t, null);
  assert.throws(
    () =>
      resolveAssetBuildIds({
        ...POLICY_BASE,
        assets: { general: { path: noManifest } },
      }),
    (err) => err.reason === REASONS.POLICY_INVALID,
  );

  const noId = assetDir(t, { version: 1 });
  assert.throws(
    () =>
      resolveAssetBuildIds({
        ...POLICY_BASE,
        assets: { general: { path: noId } },
      }),
    (err) => err.reason === REASONS.POLICY_INVALID && /buildId/.test(err.message),
  );
});
