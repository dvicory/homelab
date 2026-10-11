# Host telemetry for the in-cluster collector.
#
# node_exporter serves host metrics on the private host–guest network only.
# Two oneshot timers write ZFS pool and SMART disk status into its textfile
# directory. Each file is replaced only after a complete run, so a failing or
# stuck timer leaves an old modification time behind, which the cluster
# alerts on.
#
# Nothing here can fail host activation:
# - the exporter is socket-activated, and its socket uses FreeBind, so it
#   binds even before Incus has given the bridge its address;
# - the status services are started only by their timers, and a failed
#   collection exits 75, which the units count as success. The stale-file
#   alerts report the failure instead of a failed unit.
{
  den,
  inputs,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  diskPath = types.strMatching "/dev/disk/by-(id|path)/[^/]+";
in
{
  den.aspects.services.host-telemetry = {
    settings = {
      expectedDisks = mkOption {
        type = types.attrsOf diskPath;
        default = { };
        description = ''
          Physical disks whose SMART health must keep reporting, keyed by a
          readable name, each with a stable `/dev/disk/by-id/` or
          `/dev/disk/by-path/` path. Use a path that does not embed a serial
          number. USB and virtual devices are not declared.
        '';
        apply =
          disks:
          let
            invalid = lib.filter (name: builtins.match "[a-z][a-z0-9-]*" name == null) (
              builtins.attrNames disks
            );
          in
          assert lib.assertMsg (invalid == [ ])
            "host-telemetry disk names must be lowercase labels: ${lib.concatStringsSep ", " invalid}";
          assert lib.assertMsg (
            builtins.length (lib.unique (builtins.attrValues disks))
            == builtins.length (builtins.attrValues disks)
          ) "host-telemetry declares one disk path twice";
          disks;
      };
      extraRequiredMounts = mkOption {
        type = types.listOf (types.strMatching "/.*");
        default = [ ];
        description = ''
          Mountpoints that must be present beyond the derived ones (each
          MergerFS pool and each provisioned `disk.luks-storage` mount).
        '';
      };
      port = mkOption {
        type = types.port;
        default = 9100;
        description = "Port of the host exporter on the private host–guest address.";
      };
      textfileDirectory = mkOption {
        type = types.strMatching "/run/.+";
        default = "/run/host-telemetry";
        description = "Directory the status timers write and node_exporter reads.";
      };
    };

    includes = [ den.aspects.services.prometheus-targets-collector ];

    # The quirk's first producer: the collector consumes it on this host.
    prometheus-targets =
      { host, ... }:
      [
        {
          host = host.name;
          job = "host-node";
          inherit (host.settings.services.host-telemetry) port;
          path = "/metrics";
          interval = "30s";
          labels.host = host.name;
        }
      ];

    nixos =
      {
        host,
        config,
        pkgs,
        lib,
        ...
      }:
      let
        cfg = host.settings.services.host-telemetry;
        monitoring = config.homelab.monitoring;
        tool = lib.getExe (pkgs.callPackage (inputs.self + "/pkgs/by-name/host-telemetry/package.nix") { });
        directory = cfg.textfileDirectory;
        diskArgs = lib.concatMapStringsSep " " (
          name: lib.escapeShellArg "--disk=${name}=${monitoring.disks.${name}}"
        ) (builtins.attrNames monitoring.disks);
        # A collection failure (exit 75) keeps the previous file and is not a
        # unit failure; see the header comment.
        statusService = description: extra: {
          inherit description;
          serviceConfig = {
            Type = "oneshot";
            SuccessExitStatus = [ 75 ];
            TimeoutStartSec = "5min";
            MemoryMax = "64M";
            CPUQuota = "20%";
            Nice = 10;
            UMask = "0022";
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadWritePaths = [ directory ];
            PrivateTmp = true;
            PrivateNetwork = true;
            NoNewPrivileges = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            DevicePolicy = "closed";
          }
          // extra;
        };
        statusTimer = onBootSec: interval: {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = onBootSec;
            OnUnitActiveSec = interval;
            AccuracySec = "10s";
          };
        };
      in
      {
        systemd.tmpfiles.rules = [ "d ${directory} 0755 root root -" ];

        systemd.sockets.host-telemetry-node-exporter = {
          description = "Host telemetry exporter socket on the private host-guest network";
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = "${monitoring.listenAddress}:${toString cfg.port}";
            # Binds before the Incus bridge carries the address, so the
            # socket starts during activation whether or not Incus is up.
            FreeBind = true;
          };
        };

        # Started only through its socket: no target that activation waits on
        # wants it.
        systemd.services.host-telemetry-node-exporter = {
          description = "Host telemetry exporter (node_exporter)";
          requires = [ "host-telemetry-node-exporter.socket" ];
          after = [ "host-telemetry-node-exporter.socket" ];
          serviceConfig = {
            ExecStart = lib.escapeShellArgs [
              (lib.getExe pkgs.prometheus-node-exporter)
              "--web.systemd-socket"
              "--collector.systemd"
              "--collector.textfile.directory=${directory}"
              "--log.level=warn"
            ];
            DynamicUser = true;
            Restart = "on-failure";
            RestartSec = "10s";
            MemoryMax = "64M";
            CPUQuota = "20%";
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            PrivateTmp = true;
            PrivateDevices = true;
            NoNewPrivileges = true;
            CapabilityBoundingSet = [ "" ];
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            # AF_UNIX reaches systemd over D-Bus for the systemd collector;
            # AF_NETLINK serves the network collectors.
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
              "AF_NETLINK"
            ];
          };
        };

        systemd.services.host-telemetry-zpool-status =
          statusService "Write ZFS pool status for host telemetry"
            {
              ExecStart = "${tool} zpool --zpool ${config.boot.zfs.package}/bin/zpool --output ${directory}/zpool.prom ${diskArgs}";
              CapabilityBoundingSet = [ "" ];
              DeviceAllow = [ "/dev/zfs rw" ];
            };
        systemd.timers.host-telemetry-zpool-status = statusTimer "1min" "2min";

        # Raw SMART access is limited to the declared disks.
        systemd.services.host-telemetry-smart-status =
          statusService "Write SMART disk status for host telemetry"
            {
              ExecStart = "${tool} smart --smartctl ${pkgs.smartmontools}/bin/smartctl --output ${directory}/smart.prom ${diskArgs}";
              CapabilityBoundingSet = [
                "CAP_SYS_RAWIO"
                "CAP_SYS_ADMIN"
              ];
              DeviceAllow = map (path: "${path} rw") (builtins.attrValues monitoring.disks);
            };
        systemd.timers.host-telemetry-smart-status = statusTimer "2min" "15min";
      };
  };
}
