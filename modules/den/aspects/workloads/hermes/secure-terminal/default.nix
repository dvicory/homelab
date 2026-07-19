# Gondolin/QEMU secure-terminal backend for Hermes (V3).
#
# Brokered sandbox architecture: a Node 22 broker consuming a
# systemd-activated, profile-owned Unix socket; immutable Nix-built guest
# assets; and policy JSON rendered at evaluation time. The gateway's only
# sandbox capability is the broker socket.
{
  inputs,
  lib,
  ...
}:
let
  net = import ./_network-dsl.nix { inherit lib; };
  networkBundles = import ./_network-bundles.nix { inherit net; };
  policyLib = import ./_policy.nix { };
  guestAssetsLib = import ./_guest-assets.nix { inherit inputs; };

  settingsFor = user: user.settings.workloads.hermes or { };

  serviceNameFor = user:
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
    in
    {
      name = "workloads/hermes-secure-terminal/${user.userName}";

      # Broker-owned persistent state and rebuildable cache, persisted under
      # impermanence by the persist collector (V3 §15.1). Verify retention
      # across a real reboot before claiming it.
      persist = lib.optional gondolin "/var/lib/${sandboxUser}";
      cache = lib.optional gondolin "/var/cache/${sandboxUser}";

      nixos =
        { pkgs, ... }:
        lib.mkIf gondolin (
          let
            guestAssets = guestAssetsLib.mkGuestAssets pkgs.stdenv.hostPlatform.system;
            brokerPackage = pkgs.callPackage (inputs.self + "/pkgs/by-name/hermes-gondolin-broker/package.nix") { };
            policy = policyLib.mkPolicy {
              inherit pkgs;
              profile = serviceName;
              bundles = networkBundles;
              assets = lib.mapAttrs (_: asset: { path = "${asset}"; }) guestAssets;
              inherit defaultTemplate allowedPairs maximum worklanes;
            };
          in
          {
            # systemd owns the broker socket and hands it to the service by
            # activation. The gateway runner owns the mode-0600 socket (its
            # only sandbox capability); the broker process runs as the
            # distinct sandbox UID and never gets gateway secret access.
            systemd.sockets.${brokerName} = {
              description = "${serviceName} Gondolin sandbox broker";
              wantedBy = [ "sockets.target" ];
              socketConfig = {
                ListenStream = "/run/${brokerName}/broker.sock";
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
              # qemu-system-* (VM runner) from PATH. This is the NixOS
              # service-level PATH, not a serviceConfig key.
              path = [ pkgs.qemu ];
              # Fail-closed KVM: without acceleration the service does not
              # start; there is no silent fallback to an unaccepted mode.
              unitConfig.ConditionPathExists = "/dev/kvm";
              environment = {
                HERMES_BROKER_POLICY = "${policy.json}";
                HERMES_BROKER_PROFILE = serviceName;
                HERMES_BROKER_STATE_DIR = "/var/lib/${sandboxUser}";
                HERMES_BROKER_CACHE_DIR = "/var/cache/${sandboxUser}";
                HERMES_BROKER_RUNTIME_DIR = "/run/${sandboxUser}";
              };
              serviceConfig = {
                Type = "exec";
                User = sandboxUser;
                Group = sandboxUser;
                ExecStart = "${brokerPackage}/bin/hermes-gondolin-broker";

                # Delegated cgroup v2 subtree for per-VM limits (§16).
                Delegate = true;

                StateDirectory = sandboxUser;
                StateDirectoryMode = "0700";
                CacheDirectory = sandboxUser;
                CacheDirectoryMode = "0700";
                RuntimeDirectory = sandboxUser;
                RuntimeDirectoryMode = "0700";

                UMask = "0077";
                PrivateTmp = true;
                ProtectHome = true;
                # ProtectKernelTunables makes /sys read-only; the delegated
                # cgroup v2 subtree must stay writable or the broker (which
                # fails closed rather than run ungoverned) cannot create
                # per-VM cgroups (V3 section 16).
                ProtectSystem = "strict";
                ReadWritePaths = [
                  "/var/lib/${sandboxUser}"
                  "/var/cache/${sandboxUser}"
                  "/run/${sandboxUser}"
                  "/sys/fs/cgroup"
                ];

                DeviceAllow = "/dev/kvm";
                NoNewPrivileges = true;
                ProtectKernelModules = true;
                ProtectKernelTunables = true;
                ProtectKernelLogs = true;
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                  "AF_NETLINK"
                ];
                SystemCallFilter = [
                  "@system-service"
                  "~@privileged"
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
