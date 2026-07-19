import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadGondolinSdk, createGondolinProvider } from "../dist/gondolin.js";

/**
 * Real-SDK contract test (V3 §6, Phase 2 gate).
 *
 * Drives the production provider against the actual Gondolin SDK with
 * locally cached guest assets: boot, argv exec, shell exec, bounded
 * streams, VFS-backed fs, and hard close. Opt-in via
 * HERMES_BROKER_E2E=1 — requires a hypervisor (krun on darwin, KVM on
 * Linux) and cached assets; the Nix check runs the faked suite instead.
 *
 * On hvn-hyp1 this becomes the target-host smoke: same flow against the
 * Nix-built NixOS guest with KVM.
 */

const IMAGE_ROOTS = [
  `${os.homedir()}/.cache/gondolin/images/objects`,
];

function findAssetDir() {
  for (const root of IMAGE_ROOTS) {
    if (!fs.existsSync(root)) continue;
    for (const entry of fs.readdirSync(root)) {
      const dir = path.join(root, entry);
      if (fs.existsSync(path.join(dir, "manifest.json"))) return dir;
    }
  }
  return null;
}

const ASSET_DIR = process.env.HERMES_BROKER_E2E === "1" ? findAssetDir() : null;

test("real Gondolin SDK: boot, exec argv/shell, fs, close", async (t) => {
  if (!ASSET_DIR) {
    t.skip("requires HERMES_BROKER_E2E=1 and cached guest assets");
    return;
  }

  const sdk = await loadGondolinSdk();
  const { httpHooks } = sdk.createHttpHooks({
    allowedHosts: ["pypi.org"],
    blockInternalRanges: true,
  });

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "broker-real-"));
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

  const provider = await createGondolinProvider();
  const vm = await provider.createVm({
    assetPath: ASSET_DIR,
    memoryMiB: 512,
    cpus: 1,
    workspaceHostPath: null,
    workspaceGuestPath: "/data",
    httpHooks,
    dns: { mode: "synthetic", syntheticHostMapping: "per-host" },
    allowWebSockets: false,
    sessionLabel: "hermes-broker-e2e",
  });

  // argv form executes without a shell
  const truthy = vm.exec({ argv: ["/bin/true"], cwd: "/", env: {}, stdin: false });
  const truthyResult = await truthy.result;
  assert.equal(truthyResult.exitCode, 0);

  // shell form with captured output
  const echo = vm.exec({ argv: ["/bin/sh", "-lc", "echo broker-e2e"], cwd: "/", env: {}, stdin: false });
  const chunks = [];
  echo.onOutput((stream, data) => chunks.push([stream, data.toString()]));
  const echoResult = await echo.result;
  assert.equal(echoResult.exitCode, 0);
  assert.ok(chunks.some(([, text]) => text.includes("broker-e2e")));

  // fs round-trip through the guest
  await vm.fs.mkdir("/tmp/broker", true);
  await vm.fs.writeFile("/tmp/broker/note", Buffer.from("gondolin"));
  const back = await vm.fs.readFile("/tmp/broker/note");
  assert.equal(back.toString(), "gondolin");
  const stat = await vm.fs.stat("/tmp/broker/note");
  assert.equal(stat.type, "file");

  await vm.close();
});
