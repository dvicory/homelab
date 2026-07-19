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
    };
}
