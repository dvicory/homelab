{ self, ... }:
{
  # Policy rendering tests for the active Effect broker. Nix renders the QA
  # profile policy; the broker's strict evaluator must accept and enforce it.
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
      catalogueLib = import (self + "/modules/den/aspects/workloads/hermes/_catalogue.nix") {
        inherit lib;
      };
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
        laneAuthorities = {
          research = {
            authorityClass = "default";
            workspaceProvider = "broker-scratch";
            maximumPermission = "workspace-write";
          };
          codex-plan = {
            authorityClass = "codex";
            workspaceProvider = "broker-project";
            maximumPermission = "read-only";
          };
          codex = {
            authorityClass = "codex";
            workspaceProvider = "broker-project";
            maximumPermission = "workspace-write";
          };
        };
        projectSources = {
          homelab = {
            type = "git";
            upstream = "https://github.com/dvicory/homelab.git";
            defaultRef = "main";
            credential = {
              adapter = "github-token";
              secretRef = "hermes-terminal-github";
            };
          };
        };
        workspaceHandoffEnabled = true;
        workspaceHandoffLimits = {
          maxLogicalBytes = 67108864;
          maxEntries = 8192;
          maxFileBytes = 16777216;
          maxPathBytes = 1024;
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

      effectPolicy = policyLib.mkEffectPolicy {
        inherit pkgs;
        assets = lib.mapAttrs (_: asset: { path = "${asset}"; }) assets;
        bundles = networkBundles;
        profile = qaSelections.profile;
        defaultTemplate = qaSelections.defaultTemplate;
        allowedPairs = qaSelections.allowedPairs;
        maximum = qaSelections.maximum;
        inherit (qaSelections) worklanes laneAuthorities projectSources;
        sourceRevisions = catalogueLib.sourceRevisionsFor qaSelections.projectSources;
        providerRevisions = catalogueLib.providerRevisionsFor catalogueLib.providerContracts;
        workspaceHandoffEnabled = qaSelections.workspaceHandoffEnabled;
        workspaceHandoffLimits = qaSelections.workspaceHandoffLimits;
      };
      qaHome = self.homeConfigurations."hermes-qa-runner@hvn-hyp1".config;
      prodHome = self.homeConfigurations."hermes-prod-runner@hvn-hyp1".config;
      qaHost = self.nixosConfigurations.hvn-hyp1.config;
      qaExecutionSocket = qaHost.systemd.sockets.hermes-qa-broker-execution.socketConfig;
      qaControlSocket = qaHost.systemd.sockets.hermes-qa-broker-control.socketConfig;
      qaBrokerEnvironment = qaHost.systemd.services.hermes-qa-broker.environment;
      qaBrokerHardening = qaHost.systemd.services.hermes-qa-broker.serviceConfig;
      qaGatewayEnvironment =
        qaHome.virtualisation.quadlet.containers.hermes-qa.containerConfig.environments;
      prodGatewayEnvironment =
        prodHome.virtualisation.quadlet.containers.hermes-prod.containerConfig.environments;
      qaVolumes = qaHome.virtualisation.quadlet.containers.hermes-qa.containerConfig.volumes;
      prodVolumes = prodHome.virtualisation.quadlet.containers.hermes-prod.containerConfig.volumes;
      brokerDirectoryMount = "/run/hermes-qa-broker:/run/hermes-sandbox:ro";
      brokerWorkspaceMount = "/var/lib/hermes-qa-sandbox/workspaces/data:/home/hermes/broker-workspaces";
      hasLegacySocketMount =
        lib.any (
          volume:
          lib.hasPrefix "/run/hermes-qa-broker/broker.sock:" volume
          || lib.hasPrefix "/run/hermes-qa-broker/control.sock:" volume
        ) qaVolumes;
    in
    {
      checks.secure-terminal-socket-directory-mount =
        assert lib.elem brokerDirectoryMount qaVolumes;
        assert !hasLegacySocketMount;
        # Trusted external Codex workers consume broker workspaces through a
        # group-shared host bind-mount, never through the guest VFS.
        assert lib.elem brokerWorkspaceMount qaVolumes;
        assert lib.elem "keep-groups" qaHome.virtualisation.quadlet.containers.hermes-qa.containerConfig.addGroups;
        assert qaGatewayEnvironment.HERMES_BROKER_WORKSPACE_DATA == "/home/hermes/broker-workspaces";
        assert lib.elem "hermes-qa-runner" qaHost.users.groups."hermes-qa-sandbox".members;
        assert qaBrokerHardening.StateDirectoryMode == "0750";
        # The prod gateway has no Codex lanes and gets no broker data access.
        assert !(prodGatewayEnvironment ? HERMES_BROKER_WORKSPACE_DATA);
        assert !(lib.any (lib.hasPrefix "/var/lib/hermes-prod-sandbox/") prodVolumes);
        assert lib.elem "d /run/hermes-qa-broker 0711 root root -" qaHost.systemd.tmpfiles.rules;
        assert qaExecutionSocket.DirectoryMode == "0711";
        assert qaExecutionSocket.ListenStream == "/run/hermes-qa-broker/broker.sock";
        assert qaExecutionSocket.SocketMode == "0600";
        assert qaExecutionSocket.SocketUser == "hermes-qa-runner";
        assert qaControlSocket.DirectoryMode == "0711";
        assert qaControlSocket.ListenStream == "/run/hermes-qa-broker/control.sock";
        assert qaControlSocket.SocketMode == "0600";
        assert qaControlSocket.SocketUser == "hermes-qa-runner";
        assert qaBrokerEnvironment.GONDOLIN_EFFECT_STATE_DIR == "/var/lib/hermes-qa-sandbox";
        assert qaBrokerEnvironment.GONDOLIN_EFFECT_WORKSPACE_HANDOFF == "true";
        assert qaGatewayEnvironment.HERMES_WORKSPACE_HANDOFF == "1";
        assert qaGatewayEnvironment.HERMES_GONDOLIN_SOCKET == "/run/hermes-sandbox/broker.sock";
        assert qaGatewayEnvironment.GONDOLIN_EFFECT_CONTROL_SOCKET == "/run/hermes-sandbox/control.sock";
        assert qaBrokerEnvironment.GONDOLIN_EFFECT_SOCKET == "/run/hermes-qa-broker/broker.sock";
        assert qaBrokerEnvironment.GONDOLIN_EFFECT_CONTROL_SOCKET == "/run/hermes-qa-broker/control.sock";
        assert qaBrokerHardening.ProtectControlGroups;
        assert qaBrokerHardening.DevicePolicy == "closed";
        assert lib.elem "/dev/kvm rw" qaBrokerHardening.DeviceAllow;
        assert qaBrokerHardening.CapabilityBoundingSet == "";
        assert !qaBrokerHardening.RestrictSUIDSGID;
        assert lib.any (
          lib.hasPrefix "source-hermes-terminal-github:/run/agenix/hermes-qa-github-pat"
        ) qaBrokerHardening.LoadCredential;
        assert !(prodGatewayEnvironment ? HERMES_WORKSPACE_HANDOFF);
        assert !(qaHost.systemd.services ? hermes-prod-broker);
        assert effectPolicy.policyMaterial.processRegistry == {
          maxConcurrent = 8;
          retainedOutputBytes = 262144;
          maxPollBytes = 1048576;
          terminalTtlMs = 1800000;
        };
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
            export GONDOLIN_EFFECT_WORKSPACE_HANDOFF=true
            node ${effectBroker}/lib/node_modules/gondolin-broker-effect/dist/test-main.js >"$TMPDIR/broker.log" 2>&1 &
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
            if ! node ${self + "/modules/tests/secure-terminal-effect-policy-http.mjs"}; then
              cat "$TMPDIR/broker.log"
              exit 1
            fi
            kill "$broker_pid"
            wait "$broker_pid" || true
            trap - EXIT
            touch $out
          '';
    };
}
