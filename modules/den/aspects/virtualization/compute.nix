{
  den,
  lib,
  inputs,
  ...
}:
let
  inherit (lib) mkOption types;

  deviceType = types.attrsOf types.str;
in
{
  den.aspects.virtualization.compute = {
    settings = {
      options = {
        project = mkOption {
          type = types.str;
          description = "Incus project owning the compute envelope.";
        };
        instance = mkOption {
          type = types.str;
          description = "Incus instance name for the replaceable guest.";
        };
        profile = mkOption {
          type = types.str;
          description = "Incus profile containing the guest envelope.";
        };
        pool = mkOption {
          type = types.str;
          description = "Incus storage pool for the guest root.";
        };
        network = mkOption {
          type = types.str;
          description = "Private Incus network for the guest NIC.";
        };
        address = mkOption {
          type = types.str;
          description = "Fixed DHCP address requested by the guest NIC.";
        };
        idmapBase = mkOption {
          type = types.ints.positive;
          description = "Fixed host UID/GID base reserved for the guest.";
        };
        idmapSize = mkOption {
          type = types.ints.positive;
          description = "Fixed UID/GID map size reserved for the guest.";
        };
        statePath = mkOption {
          type = types.str;
          description = "Persistent Jellyfin configuration directory on the host.";
        };
        recoveryPath = mkOption {
          type = types.str;
          description = "Persistent application recovery directory on the host.";
        };
        identityPath = mkOption {
          type = types.str;
          description = "Persistent guest identity directory on the host.";
        };
        mediaPath = mkOption {
          type = types.str;
          description = "Stable parent of the host-provided media export.";
        };
        mediaSource = mkOption {
          type = types.str;
          description = "Declared mergerfs pool whose branches feed the read-only compute view.";
        };
        config = mkOption {
          type = types.attrsOf types.str;
          description = "Complete desired Incus instance configuration.";
        };
        devices = mkOption {
          type = types.attrsOf deviceType;
          description = "Complete desired Incus instance device map.";
        };
      };
      config = { };
    };

    persist = [
      {
        directories = [ "/var/lib/incus-storage-pools/incus-compute" ];
        user = "root";
        group = "root";
      }
      {
        directories = [
          "/var/lib/homelab/compute-1/jellyfin"
          "/var/lib/homelab/compute-1/recovery"
        ];
        user = "1000751";
        group = "1000751";
        mode = "0750";
      }
      {
        directories = [ "/var/lib/homelab/compute-1/identity" ];
        user = "1000000";
        group = "1000000";
        mode = "0700";
      }
    ];

    nixos =
      {
        host,
        config,
        utils,
        lib,
        pkgs,
        ...
      }:
      let
        cfg = host.settings.virtualization.compute;
        projectConfig = {
          "features.images" = "true";
          "features.networks" = "false";
          restricted = "true";
          "restricted.containers.interception" = "block";
          "restricted.containers.lowlevel" = "block";
          # Incus classifies security.idmap.base/size as unrestricted low-level
          # config. A range-limited raw.idmap keeps raw LXC/AppArmor blocked.
          "restricted.idmap.uid" = "${toString cfg.idmapBase}-${
            toString (cfg.idmapBase + cfg.idmapSize - 1)
          }";
          "restricted.idmap.gid" = "${toString cfg.idmapBase}-${
            toString (cfg.idmapBase + cfg.idmapSize - 1)
          }";
          "restricted.containers.nesting" = "allow";
          "restricted.containers.privilege" = "unprivileged";
          "restricted.devices.disk" = "allow";
          "restricted.devices.disk.paths" = lib.concatStringsSep "," [
            cfg.statePath
            cfg.identityPath
            cfg.mediaPath
          ];
          "restricted.devices.gpu" = "block";
          "restricted.devices.infiniband" = "block";
          "restricted.devices.nic" = "managed";
          "restricted.devices.pci" = "block";
          "restricted.devices.proxy" = "block";
          "restricted.devices.unix-block" = "block";
          "restricted.devices.unix-char" = "block";
          "restricted.devices.unix-hotplug" = "block";
          "restricted.devices.usb" = "block";
          "restricted.networks.access" = cfg.network;
        };
        branches = host.settings.services.mergerfs.pools.${cfg.mediaSource}.branches;
        pinned = lib.imap0 (index: source: {
          inherit source;
          path = "/run/homelab-compute/pinned-${toString index}";
        }) branches;
        mountUnit = path: "${utils.escapeSystemdPath path}.mount";
        pinnedUnits = map (branch: mountUnit branch.path) pinned;
        identityAge = inputs.self + "/.secrets/hosts/${cfg.instance}/runtime_host_key.age";
        identityPub = inputs.self + "/.secrets/hosts/${cfg.instance}/runtime_host_key.pub";
        hasIdentity = builtins.pathExists identityAge && builtins.pathExists identityPub;
        publicKey =
          if builtins.pathExists identityPub then lib.trim (builtins.readFile identityPub) else null;
        publicKeyFile = pkgs.writeText "${cfg.instance}-public-key" (
          if publicKey == null then "" else publicKey
        );
        poolPath = "/var/lib/incus-storage-pools/${cfg.pool}";
        networkConfig = {
          "ipv4.address" = "10.210.0.1/24";
          "ipv4.dhcp" = "true";
          "ipv4.dhcp.ranges" = "${cfg.address}-${cfg.address}";
          "ipv4.nat" = "true";
          "ipv6.address" = "none";
        };

        requiredPaths = [
          {
            path = cfg.statePath;
            uid = cfg.idmapBase + 751;
            gid = cfg.idmapBase + 751;
          }
          {
            path = cfg.recoveryPath;
            uid = cfg.idmapBase + 751;
            gid = cfg.idmapBase + 751;
          }
          {
            path = cfg.identityPath;
            uid = cfg.idmapBase;
            gid = cfg.idmapBase;
          }
          {
            path = cfg.mediaPath;
            uid = 0;
            gid = 0;
            readOnly = true;
          }
        ];
        descriptor = {
          inherit
            publicKey
            projectConfig
            poolPath
            networkConfig
            requiredPaths
            ;
          inherit (cfg)
            project
            instance
            profile
            pool
            network
            address
            idmapBase
            idmapSize
            statePath
            recoveryPath
            identityPath
            mediaPath
            config
            devices
            ;
        };
      in
      {
        environment.systemPackages = [
          (pkgs.callPackage (inputs.self + "/pkgs/by-name/compute-guest/package.nix") { })
        ];
        virtualisation.incus.preseed = {
          projects = [
            {
              name = cfg.project;
              config = projectConfig;
            }
          ];

          storage_pools = [
            {
              name = cfg.pool;
              driver = "dir";
              config.source = poolPath;
            }
          ];

          networks = [
            {
              # Incus managed bridges live in the default network project.
              project = "default";
              name = cfg.network;
              type = "bridge";
              config = networkConfig;
            }
          ];

          profiles = [
            {
              project = cfg.project;
              name = cfg.profile;
              description = "Unprivileged private compute envelope";
              config = cfg.config;
              devices = cfg.devices;
            }
          ];
        };
        systemd.services.incus-preseed.serviceConfig.ExecStart =
          lib.mkForce "${pkgs.util-linux}/bin/flock -n /run/lock/compute-${cfg.project}-${cfg.instance}.lock ${pkgs.writeShellScript "locked-compute-preseed" config.systemd.services.incus-preseed.script}";

        environment.etc."homelab/compute.json" = {
          mode = "0444";
          text = builtins.toJSON descriptor + "\n";
        };

        networking.firewall.interfaces.${cfg.network} = {
          allowedUDPPorts = [
            53
            67
          ];
          allowedTCPPorts = [ 53 ];
        };

        secretRequests = lib.optionalAttrs hasIdentity {
          "${cfg.instance}-host-key" = {
            provider = "agenix";
            ageFile = identityAge;
            mode = "0400";
            restartUnits = [ "compute-stage-identity.service" ];
          };
        };
        systemd.services.compute-stage-identity = {
          description = "Stage the declared compute SSH identity";
          wantedBy = lib.optional hasIdentity "multi-user.target";
          before = [ "incus.service" ];
          path = [
            pkgs.coreutils
            pkgs.util-linux
            pkgs.openssh
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
          };
          script = ''
            set -eu
            exec 9>/run/lock/compute-${cfg.project}-${cfg.instance}.lock
            flock -n 9
            test -s ${publicKeyFile}
            key=/run/agenix/${cfg.instance}-host-key
            actual="$(ssh-keygen -y -f "$key")"
            expected="$(cut -d ' ' -f 1-2 ${publicKeyFile})"
            test "$actual" = "$expected"
            install -m 0400 -o ${toString cfg.idmapBase} -g ${toString cfg.idmapBase} "$key" ${cfg.identityPath}/.key-new
            install -m 0444 -o ${toString cfg.idmapBase} -g ${toString cfg.idmapBase} ${publicKeyFile} ${cfg.identityPath}/.pub-new
            mv -T ${cfg.identityPath}/.key-new ${cfg.identityPath}/ssh_host_ed25519_key
            mv -T ${cfg.identityPath}/.pub-new ${cfg.identityPath}/ssh_host_ed25519_key.pub
          '';
        };

        # Pin the real branch mounts before merging. Merging the original
        # paths directly can turn a lost branch into a successful partial
        # library listing. Stop ordering removes the view before its pins.
        systemd.mounts = map (branch: {
          what = branch.source;
          where = branch.path;
          type = "none";
          options = "bind,ro";
          bindsTo = [ (mountUnit branch.source) ];
          after = [ (mountUnit branch.source) ];
        }) pinned;

        systemd.services.compute-media-root = {
          description = "Prepare the read-only compute media attachment";
          wantedBy = [ "multi-user.target" ];
          before = [ "incus.service" ];
          path = [
            pkgs.coreutils
            pkgs.util-linux
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -eu
            root=${lib.escapeShellArg cfg.mediaPath}
            mkdir -p "$root"
            if ! mountpoint -q "$root"; then
              mount -t tmpfs -o mode=0755,size=1m tmpfs "$root"
              mkdir -m 000 "$root/data"
              mount --make-rshared "$root"
              mount -o remount,ro "$root"
            fi
            test "$(findmnt -n -o FSTYPE -M "$root")" = tmpfs
            if ! mountpoint -q "$root/data"; then
              test "$(stat -c '%u:%g:%a' "$root/data")" = 0:0:0
            fi
            findmnt -n -o VFS-OPTIONS -M "$root" | tr ',' '\n' | ${pkgs.gnugrep}/bin/grep -qx ro
          '';
        };
        systemd.services.incus.requires = [ "compute-media-root.service" ];

        systemd.services.compute-media-export = {
          description = "Read-only media view over pinned source mounts";
          requires = [ "compute-media-root.service" ];
          bindsTo = pinnedUnits;
          after = [ "compute-media-root.service" ] ++ pinnedUnits;
          serviceConfig = {
            Type = "simple";
            ExecStart = "${pkgs.mergerfs}/bin/mergerfs -f -o allow_other,ro ${
              lib.concatMapStringsSep ":" (branch: branch.path) pinned
            } ${cfg.mediaPath}/data";
            ExecStop = "${pkgs.util-linux}/bin/umount -l ${cfg.mediaPath}/data";
          };
        };
        # Retry native mount dependencies after late unlock/reattachment.
        # This timer does not monitor or restart the compute node.
        systemd.timers.compute-media-export = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitInactiveSec = "30s";
          };
        };

        # Native nftables bridge rules own L2 filtering. A second br_netfilter
        # pass through inet conntrack invalidates DHCP packets before host input.
        boot.kernel.sysctl = {
          "net.bridge.bridge-nf-call-iptables" = 0;
          "net.bridge.bridge-nf-call-ip6tables" = 0;
          "net.bridge.bridge-nf-call-arptables" = 0;
        };

        # Incus 7.4 supports NIC ACLs, but its preseed API has no ACL object
        # field. Keep the host boundary declarative until a native ACL owner is
        # available; this catches routed and same-bridge ingress early.
        networking.nftables.tables."homelab-compute-boundary" = {
          family = "inet";
          content = ''
            chain forward {
              type filter hook forward priority -50; policy accept;
              oifname "${cfg.network}" ct state { established, related } accept
              oifname "${cfg.network}" drop
            }
          '';
        };

        networking.nftables.tables."homelab-compute-bridge-boundary" = {
          family = "bridge";
          content = ''
            chain forward {
              type filter hook forward priority -50; policy accept;
              oifname "${cfg.devices.eth0.host_name}" ct state { established, related } accept
              oifname "${cfg.devices.eth0.host_name}" drop
            }
          '';
        };
      };
  };
}
