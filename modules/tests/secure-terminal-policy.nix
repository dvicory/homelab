{ self, ... }:
{
  # Golden policy rendering test (V3 §19 Phase 5): the Nix-rendered
  # policy.json for the QA profile shape must parse under the broker's
  # strict validator and compose for every declared pair, worklane, and
  # template. This is the contract between the Nix authoring DSL and the
  # broker evaluator.
  perSystem =
    { pkgs, ... }:
    let
      lib = pkgs.lib;
      net = import (self + "/modules/den/aspects/workloads/hermes/secure-terminal/_network-dsl.nix") {
        inherit lib;
      };
      networkBundles = import (self + "/modules/den/aspects/workloads/hermes/secure-terminal/_network-bundles.nix") {
        inherit net;
      };
      policyLib = import (self + "/modules/den/aspects/workloads/hermes/secure-terminal/_policy.nix") { };
      broker = pkgs.callPackage (self + "/pkgs/by-name/hermes-gondolin-broker/package.nix") { };
      effectBroker = pkgs.callPackage (self + "/pkgs/by-name/gondolin-broker-effect/package.nix") { };

      # Mirror of the QA selections in modules/den/users/hermes-runners.nix.
      # Keep in sync: the host evaluation proves the real path; this check
      # pins the rendered policy contract.
      qaSelections = {
        profile = "hermes-qa";
        defaultTemplate = "project";
        allowedPairs = [
          {
            asset = "general";
            template = "project";
          }
          {
            asset = "general";
            template = "research";
          }
          {
            asset = "general";
            template = "offline";
          }
          {
            asset = "minimal";
            template = "offline";
          }
        ];
        maximum = {
          networkBundles = [
            "git-public"
            "npm-public"
            "pypi-public"
            "nix-cache-public"
          ];
          credentialCapabilities = [
            "github-private-read"
            "github-push"
          ];
          resources = {
            cpus = 4;
            memoryMiB = 8192;
            diskMiB = 32768;
          };
          grantScopes = [
            "once"
            "task"
          ];
        };
        worklanes.codex = {
          allowedPairs = [
            {
              asset = "general";
              template = "project";
            }
            {
              asset = "minimal";
              template = "offline";
            }
          ];
          maximum.networkBundles = [
            "git-public"
            "npm-public"
            "pypi-public"
          ];
        };
      };

      assetManifest =
        name: buildId:
        pkgs.runCommand "asset-${name}-manifest" { } ''
          mkdir -p $out
          echo '{"version":1,"buildId":"${buildId}"}' > $out/manifest.json
        '';
      assets = {
        general = assetManifest "general" "golden-build-general";
        minimal = assetManifest "minimal" "golden-build-minimal";
      };

      policy = policyLib.mkPolicy {
        inherit pkgs;
        assets = lib.mapAttrs (_: asset: { path = "${asset}"; }) assets;
        bundles = networkBundles;
        profile = qaSelections.profile;
        defaultTemplate = qaSelections.defaultTemplate;
        allowedPairs = qaSelections.allowedPairs;
        maximum = qaSelections.maximum;
        worklanes = qaSelections.worklanes;
      };
      effectPolicy = policyLib.mkEffectPolicy {
        inherit pkgs;
        assets = lib.mapAttrs (_: asset: { path = "${asset}"; }) assets;
        bundles = networkBundles;
        profile = qaSelections.profile;
        defaultTemplate = qaSelections.defaultTemplate;
        allowedPairs = qaSelections.allowedPairs;
        maximum = qaSelections.maximum;
        worklanes = qaSelections.worklanes;
      };
    in
    {
      checks.secure-terminal-policy-golden =
        pkgs.runCommand "secure-terminal-policy-golden"
          {
            nativeBuildInputs = [ broker.nodejs ];
            policyJson = "${policy.json}";
          }
          ''
            cp $policyJson policy.json
            node --input-type=module -e '
              import fs from "node:fs";
              import { parsePolicy, composePolicy } from "${broker}/lib/node_modules/hermes-gondolin-broker/dist/policy.js";
              import { resolveAssetBuildIds } from "${broker}/lib/node_modules/hermes-gondolin-broker/dist/config.js";

              const raw = JSON.parse(fs.readFileSync("policy.json", "utf8"));
              const policy = resolveAssetBuildIds(parsePolicy(raw));

              const checks = [
                [{ profile: "hermes-qa" }, "general", "project"],
                [{ profile: "hermes-qa", template: "research" }, "general", "research"],
                [{ profile: "hermes-qa", template: "offline", asset: "general" }, "general", "offline"],
                [{ profile: "hermes-qa", template: "offline" }, "minimal", "offline"],
                [{ profile: "hermes-qa", worklane: "codex" }, "general", "project"],
                [{ profile: "hermes-qa", worklane: "codex", template: "offline" }, "minimal", "offline"],
              ];
              for (const [req, asset, template] of checks) {
                const eff = composePolicy(policy, req);
                if (eff.assetName !== asset || eff.templateName !== template) {
                  throw new Error(`compose ''${JSON.stringify(req)} -> ''${eff.assetName}/''${eff.templateName}, want ''${asset}/''${template}`);
                }
                if (typeof eff.policyHash !== "string" || eff.policyHash.length !== 64) {
                  throw new Error("policyHash missing from effective policy");
                }
              }

              // Hard floor invariants in the rendered document
              if (policy.floor.maxVms <= 0 || policy.floor.maxFrameBytes <= 0) {
                throw new Error("floor bounds missing");
              }
              for (const [name, bundle] of Object.entries(policy.bundles)) {
                for (const flag of ["allowWebSockets", "allowConnect", "allowRawTcp", "allowSsh"]) {
                  if (bundle[flag]) throw new Error(`bundle ''${name} lifts floor via ''${flag}`);
                }
              }
              // No secret values anywhere in policy data (logical IDs only)
              const text = fs.readFileSync("policy.json", "utf8");
              for (const needle of ["ghp_", "github_pat_", "BEGIN PRIVATE", "BEGIN OPENSSH"]) {
                if (text.includes(needle)) throw new Error(`secret-like content in policy: ''${needle}`);
              }
              console.log("policy golden: parse + compose + floor invariants OK");
            '
            touch $out
          '';
      checks.secure-terminal-effect-policy-http =
        pkgs.runCommand "secure-terminal-effect-policy-http"
          {
            nativeBuildInputs = [ pkgs.nodejs_24 ];
            policyJson = "${effectPolicy.json}";
          }
          ''
            export GONDOLIN_EFFECT_POLICY="$policyJson"
            export GONDOLIN_EFFECT_PROFILE=hermes-qa
            export GONDOLIN_EFFECT_STATE_DIR="$TMPDIR/state"
            export GONDOLIN_EFFECT_SOCKET="$TMPDIR/broker.sock"
            ${effectBroker}/bin/gondolin-broker-effect >"$TMPDIR/broker.log" 2>&1 &
            broker_pid=$!
            trap 'kill "$broker_pid" 2>/dev/null || true' EXIT
            for _ in $(seq 1 100); do
              [ -S "$GONDOLIN_EFFECT_SOCKET" ] && break
              if ! kill -0 "$broker_pid"; then
                cat "$TMPDIR/broker.log"
                exit 1
              fi
              sleep 0.05
            done
            [ -S "$GONDOLIN_EFFECT_SOCKET" ]
            node --input-type=module -e '
              import http from "node:http";
              import fs from "node:fs";
              const body = await new Promise((resolve, reject) => {
                const request = http.request({
                  socketPath: process.env.GONDOLIN_EFFECT_SOCKET,
                  path: "/v1/health",
                  method: "GET",
                }, (response) => {
                  const chunks = [];
                  response.on("data", (chunk) => chunks.push(chunk));
                  response.on("end", () => {
                    if (response.statusCode !== 200) reject(new Error("health status " + response.statusCode));
                    else resolve(Buffer.concat(chunks).toString("utf8"));
                  });
                });
                request.on("error", reject);
                request.end();
              });
              if (JSON.parse(body).status !== "ok") throw new Error("broker health response is not ok");
              const rendered = JSON.parse(fs.readFileSync(process.env.GONDOLIN_EFFECT_POLICY, "utf8"));
              for (const lane of ["default", "codex"]) {
                const resource = "worklane:" + lane + ":environment:*";
                const statement = rendered.policy.statements.find(
                  (candidate) =>
                    candidate.actions.includes("environment.ensure") &&
                    candidate.resources.includes(resource)
                );
                if (!statement) throw new Error("missing ensure authority for " + lane);
                const obligations = statement.obligations?.filter(
                  (obligation) => obligation.kind === "network"
                ) ?? [];
                if (obligations.length !== 1) {
                  throw new Error("expected exactly one network obligation for " + lane);
                }
                const networkId = obligations[0].bundleId;
                if (!networkId.startsWith("worklane:" + lane + ":") || !rendered.networkPolicies[networkId]) {
                  throw new Error("network obligation is not content-bound for " + lane);
                }
              }
              const policyFor = (lane) => {
                const statement = rendered.policy.statements.find(
                  (candidate) => candidate.resources.includes("worklane:" + lane + ":environment:*")
                );
                return rendered.networkPolicies[statement.obligations[0].bundleId];
              };
              const defaultHosts = new Set(policyFor("default").destinations.map((item) => item.host));
              for (const host of ["github.com", "registry.npmjs.org", "pypi.org", "cache.nixos.org"]) {
                if (!defaultHosts.has(host)) throw new Error("default lane missing reviewed host " + host);
              }
              const codexHosts = new Set(policyFor("codex").destinations.map((item) => item.host));
              if (!codexHosts.has("github.com") || !codexHosts.has("pypi.org")) {
                throw new Error("codex lane missing its reviewed network bundles");
              }
              if (codexHosts.has("cache.nixos.org")) {
                throw new Error("codex lane exceeded its network maximum");
              }
            '
            kill "$broker_pid"
            wait "$broker_pid" || true
            trap - EXIT
            touch $out
          '';
    };
}
