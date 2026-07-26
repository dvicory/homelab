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
      qaHome = self.homeConfigurations."hermes-qa-runner@hvn-hyp1".config;
      qaHost = self.nixosConfigurations.hvn-hyp1.config;
      qaExecutionSocket = qaHost.systemd.sockets.hermes-qa-broker-execution.socketConfig;
      qaControlSocket = qaHost.systemd.sockets.hermes-qa-broker-control.socketConfig;
      qaVolumes = qaHome.virtualisation.quadlet.containers.hermes-qa.containerConfig.volumes;
      brokerDirectoryMount = "/run/hermes-qa-broker:/run/hermes-sandbox:ro";
      hasLegacySocketMount =
        lib.any (
          volume:
          lib.hasPrefix "/run/hermes-qa-broker/broker.sock:" volume
          || lib.hasPrefix "/run/hermes-qa-broker/control.sock:" volume
        ) qaVolumes;
    in
    {
      checks.secure-terminal-policy-golden =
        pkgs.runCommand "secure-terminal-policy-golden"
          {
            nativeBuildInputs = [ broker.nodejs ];
            policyJson = "${policy.json}";
          }
          ''
            HERMES_GONDOLIN_BROKER_LIB=${broker}/lib/node_modules/hermes-gondolin-broker/dist \
              POLICY_JSON="$policyJson" \
              node ${self + "/modules/tests/secure-terminal-policy-golden.mjs"}
            touch $out
          '';
      checks.secure-terminal-socket-directory-mount =
        assert lib.elem brokerDirectoryMount qaVolumes;
        assert !hasLegacySocketMount;
        assert lib.elem "d /run/hermes-qa-broker 0711 root root -" qaHost.systemd.tmpfiles.rules;
        assert qaExecutionSocket.DirectoryMode == "0711";
        assert qaExecutionSocket.SocketMode == "0600";
        assert qaExecutionSocket.SocketUser == "hermes-qa-runner";
        assert qaControlSocket.DirectoryMode == "0711";
        assert qaControlSocket.SocketMode == "0600";
        assert qaControlSocket.SocketUser == "hermes-qa-runner";
        pkgs.runCommand "secure-terminal-socket-directory-mount" { } ''
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
            export GONDOLIN_EFFECT_CONTROL_SOCKET="$TMPDIR/control.sock"
            ${effectBroker}/bin/gondolin-broker-effect >"$TMPDIR/broker.log" 2>&1 &
            broker_pid=$!
            trap 'kill "$broker_pid" 2>/dev/null || true' EXIT
            for _ in $(seq 1 100); do
              [ -S "$GONDOLIN_EFFECT_SOCKET" ] && [ -S "$GONDOLIN_EFFECT_CONTROL_SOCKET" ] && break
              if ! kill -0 "$broker_pid"; then
                cat "$TMPDIR/broker.log"
                exit 1
              fi
              sleep 0.05
            done
            [ -S "$GONDOLIN_EFFECT_SOCKET" ]
            [ -S "$GONDOLIN_EFFECT_CONTROL_SOCKET" ]
            node ${self + "/modules/tests/secure-terminal-effect-policy-http.mjs"}
            kill "$broker_pid"
            wait "$broker_pid" || true
            trap - EXIT
            touch $out
          '';
    };
}
