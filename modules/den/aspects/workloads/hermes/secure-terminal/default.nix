# Gondolin/QEMU secure-terminal backend for Hermes (V3).
#
# Brokered sandbox architecture: an Effect/Node 24 HTTP broker consuming a
# systemd-activated, profile-owned Unix socket; immutable Nix-built guest
# assets; and policy JSON rendered at evaluation time. The gateway's only
# sandbox capability is the broker socket.
{
  inputs,
  lib,
  ...
}:
let
  hermesLib = inputs.secure-hermes-nix.lib;
  net = hermesLib.network;
  networkBundles = hermesLib.networkBundles;
  policyLib = hermesLib.policy;
  catalogueLib = hermesLib.catalogue;
  guestAssetsLib = hermesLib.guestAssets;

  settingsFor = user: user.settings.workloads.hermes or { };

  serviceNameFor =
    user:
    let
      cfg = settingsFor user;
      instance =
        cfg.instance
          or (throw "Hermes secure-terminal account '${user.userName}' has no settings.workloads.hermes.instance");
    in
    "hermes-${instance}";

in
{
  # Commit-pinned guest-asset builder and host SDK packaging, following this
  # flake's Nixpkgs (V3 §9.1). Declared beside the Hermes workload it serves;
  # regenerate the flake with `nix run .#write-flake --impure` after changes.
  flake-file.inputs.gondolin-nix = {
    url = "github:dvicory/gondolin-nix/secure-terminal-v3";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Broker units for the Gondolin backend. The companion sandbox account is
  # still derived by the Hermes account aspect (one identity for both
  # engines); this aspect contributes only what the brokered architecture
  # adds: the broker socket/service, the immutable policy, and persistence
  # for broker-owned state.
  den.aspects.workloads.hermes.secureTerminal =
    { user, ... }:
    let
      cfg = settingsFor user;
      secureTerminal = cfg.secureTerminal or { };
      enabled = secureTerminal.enable or false;
      backend = secureTerminal.backend or "podman";
      gondolin = enabled && backend == "gondolin";

      serviceName = serviceNameFor user;
      sandboxUser = "${serviceName}-sandbox";
      brokerName = "${serviceName}-broker";
      executionSocketName = "${brokerName}-execution";
      controlSocketName = "${brokerName}-control";
      executionSocketPath = "/run/${brokerName}/broker.sock";
      controlSocketPath = "/run/${brokerName}/control.sock";

      defaultTemplate = secureTerminal.defaultTemplate or "project";
      allowedPairs =
        secureTerminal.allowedPairs or [
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
      }
      // (secureTerminal.maximum or { });
      worklanes = secureTerminal.worklanes or { };
      laneAuthorities = lib.mapAttrs (
        _: lane:
        let
          workspace = lane.workspace or { };
          projectMode = workspace.projectMode or "none";
        in
        {
          authorityClass = lane.policy.worklane or "default";
          workspaceProvider =
            if projectMode == "none" then
              workspace.scratchProvider or "broker-scratch"
            else
              workspace.projectProvider or "broker-project";
          maximumPermission =
            if projectMode == "none" then "workspace-write" else workspace.maximumPermission;
        }
      ) (cfg.workerLanes or { });
      workspaceHandoff = secureTerminal.workspaceHandoff or { };
      workspaceHandoffEnabled = workspaceHandoff.enable or false;
      workspaceHandoffLimits =
        policyLib.workspaceHandoffLimitCeilings // (workspaceHandoff.handoffLimits or { });
      projectSources = cfg.projectSources or { };
      sourceRevisions = catalogueLib.sourceRevisionsFor projectSources;
      providerRevisions = catalogueLib.providerRevisionsFor catalogueLib.providerContracts;
      projectMaterializationLimits =
        policyLib.projectMaterializationLimitCeilings
        // (secureTerminal.projectMaterializationLimits or { });
      sourceCredentialRefs = lib.unique (
        lib.concatMap (
          source: lib.optional (source.credential or null != null) source.credential.secretRef
        ) (builtins.attrValues projectSources)
      );
      usesGithubSourceCredential = lib.elem "hermes-terminal-github" sourceCredentialRefs;
      brokerCredentialSecretName = "${serviceName}-github-pat";
    in
    {
      name = "workloads/hermes-secure-terminal/${user.userName}";

      # Broker-owned persistent state and rebuildable cache, persisted under
      # impermanence by the persist collector (V3 §15.1). Verify retention
      # across a real reboot before claiming it.
      persist = lib.optional gondolin "/var/lib/${sandboxUser}";
      cache = lib.optional gondolin "/var/cache/${sandboxUser}";

      nixos =
        {
          host,
          pkgs,
          config,
          ...
        }:
        lib.mkIf gondolin (
          let
            guestAssets = guestAssetsLib.mkGuestAssets pkgs.stdenv.hostPlatform.system;
            brokerPackage =
              inputs.secure-hermes-nix.packages.${pkgs.stdenv.hostPlatform.system}.gondolin-broker-effect;
            # The broker resolves logical source credential references through
            # systemd credentials. PID 1 copies the existing runner-owned PAT
            # into the broker's private credential directory; it never enters
            # the guest or any environment/argv channel.
            brokerCredentialAgeFile = host.secretPath + "/${serviceName}-github-pat.age";
            brokerCredentialEnabled = usesGithubSourceCredential && builtins.pathExists brokerCredentialAgeFile;
            policy = policyLib.mkEffectPolicy {
              inherit pkgs;
              profile = serviceName;
              bundles = networkBundles;
              assets = lib.mapAttrs (_: asset: { path = "${asset}"; }) guestAssets;
              inherit
                defaultTemplate
                allowedPairs
                maximum
                worklanes
                laneAuthorities
                workspaceHandoffEnabled
                workspaceHandoffLimits
                projectSources
                sourceRevisions
                providerRevisions
                projectMaterializationLimits
                ;
            };
          in
          {

            # systemd owns the broker socket and hands it to the service by
            # activation. The gateway runner owns the mode-0600 socket (its
            # only sandbox capability); the broker process runs as the
            # distinct sandbox UID and never gets gateway secret access.
            # Keep the mount source inode stable while socket units replace
            # broker.sock/control.sock during activation or operator restarts.
            # The gateway gets traverse-only access plus its mode-0600 sockets.
            systemd.tmpfiles.rules = [
              "d /run/${brokerName} 0711 root root -"
            ];
            systemd.sockets.${executionSocketName} = {
              description = "${serviceName} Gondolin sandbox execution plane";
              wantedBy = [ "sockets.target" ];
              socketConfig = {
                ListenStream = executionSocketPath;
                FileDescriptorName = "execution";
                Service = "${brokerName}.service";
                SocketUser = user.userName;
                SocketGroup = user.userName;
                SocketMode = "0600";
                DirectoryMode = "0711";
                RemoveOnStop = true;
              };
            };
            systemd.sockets.${controlSocketName} = {
              description = "${serviceName} Gondolin sandbox control plane";
              wantedBy = [ "sockets.target" ];
              socketConfig = {
                ListenStream = controlSocketPath;
                FileDescriptorName = "control";
                Service = "${brokerName}.service";
                SocketUser = user.userName;
                SocketGroup = user.userName;
                SocketMode = "0600";
                DirectoryMode = "0711";
                RemoveOnStop = true;
              };
            };
            systemd.services.${brokerName} = {
              description = "${serviceName} Gondolin sandbox broker service";
              # The SDK spawns qemu-img (overlay creation) and
              requires = [
                "${executionSocketName}.socket"
                "${controlSocketName}.socket"
              ];
              after = [
                "${executionSocketName}.socket"
                "${controlSocketName}.socket"
              ];
              # qemu-system-* (VM runner) from PATH. This is the NixOS
              # service-level PATH, not a serviceConfig key.
              path = [ pkgs.qemu ];
              # Fail-closed KVM: without acceleration the service does not
              # start; there is no silent fallback to an unaccepted mode.
              unitConfig.ConditionPathExists = "/dev/kvm";
              environment = {
                GONDOLIN_EFFECT_POLICY = "${policy.json}";
                GONDOLIN_EFFECT_PROFILE = serviceName;
                GONDOLIN_EFFECT_STATE_DIR = "/var/lib/${sandboxUser}";
                GONDOLIN_EFFECT_SOCKET = executionSocketPath;
                GONDOLIN_EFFECT_CONTROL_SOCKET = controlSocketPath;
                GONDOLIN_EFFECT_WORKSPACE_HANDOFF = if workspaceHandoffEnabled then "true" else "false";
              };
              serviceConfig = {
                Type = "exec";
                User = sandboxUser;
                Group = sandboxUser;
                ExecStart = "${brokerPackage}/bin/gondolin-broker-effect";

                # VM admission is enforced in broker policy. Keep the broker
                # itself outside a delegated, writable cgroup subtree.
                StateDirectory = sandboxUser;
                # Group-traversable so the gateway runner (a sandbox-group
                # member when Codex lanes are enabled) can reach the shared
                # broker workspace data root below. Secrets in this tree stay
                # 0600/0700 via the broker umask.
                StateDirectoryMode = "0750";
                CacheDirectory = sandboxUser;
                CacheDirectoryMode = "0700";
                RuntimeDirectory = sandboxUser;
                RuntimeDirectoryMode = "0700";

                UMask = "0077";
                PrivateTmp = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                ReadWritePaths = [
                  "/var/lib/${sandboxUser}"
                  "/var/cache/${sandboxUser}"
                  "/run/${sandboxUser}"
                ];
                ProtectControlGroups = true;

                # Trusted source credentials arrive only through systemd
                # credentials ($CREDENTIALS_DIRECTORY/source-<secretRef>);
                # they are never environment variables or arguments.
                LoadCredential = lib.optional brokerCredentialEnabled "source-hermes-terminal-github:${
                  config.age.secrets.${brokerCredentialSecretName}.path
                }";

                DevicePolicy = "closed";
                DeviceAllow = [ "/dev/kvm rw" ];
                NoNewPrivileges = true;
                ProtectKernelModules = true;
                ProtectKernelTunables = true;
                ProtectKernelLogs = true;
                ProtectClock = true;
                ProtectHostname = true;
                ProtectProc = "invisible";
                ProcSubset = "pid";
                PrivateMounts = true;
                LockPersonality = true;
                RestrictRealtime = true;
                # Workspaces are shared with the runner through their setgid
                # sandbox group. RestrictSUIDSGID blocks the required chmod(2)
                # with EPERM even though the broker owns the directory.
                RestrictSUIDSGID = false;
                RemoveIPC = true;
                CapabilityBoundingSet = "";
                AmbientCapabilities = "";
                SystemCallArchitectures = "native";
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                  "AF_NETLINK"
                ];
                SystemCallFilter = [
                  "@system-service"
                  "~@privileged"
                  # libuv's copyFile preserves source ownership with fchown(2).
                  # The unprivileged broker lacks CAP_CHOWN, so normal DAC
                  # restrictions still apply; permit only this syscall rather
                  # than weakening the privileged-syscall group exclusion.
                  "fchown"
                ];

                # Process-tree cleanup; KillMode=process would leak QEMU
                # children of the main broker process (§18).
                KillMode = "mixed";
                TimeoutStopSec = 70;
              };
            };
          }
        );
    };
}
