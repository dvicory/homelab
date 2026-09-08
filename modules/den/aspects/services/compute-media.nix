{ den, lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  den.aspects.services.compute-media = {
    settings.source = mkOption {
      type = types.str;
      description = "MergerFS pool whose mounted branches feed the compute media view.";
    };

    nixos =
      {
        host,
        utils,
        pkgs,
        lib,
        ...
      }:
      let
        compute = host.settings.virtualization.compute;
        cfg = host.settings.services.compute-media;
        media = compute.devices.media or null;
        branches = host.settings.services.mergerfs.pools.${cfg.source}.branches;
        root = media.source;
        pinned = lib.imap0 (index: source: {
          inherit source;
          path = "/run/homelab-compute/pinned-${toString index}";
        }) branches;
        mountUnit = path: "${utils.escapeSystemdPath path}.mount";
        pinnedUnits = map (branch: mountUnit branch.path) pinned;
      in
      assert lib.assertMsg (
        media != null
        && (media.type or null) == "disk"
        && (media.source or null) != null
        && (media.path or null) != null
        && (media.required or null) == "true"
      ) "compute-media requires a required source-backed media disk device.";
      {
        # Pin each real branch before merging. A missing branch must remove the
        # view instead of producing a successful partial library listing.
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
            root=${lib.escapeShellArg root}
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
            } ${root}/data";
            ExecStop = "${pkgs.util-linux}/bin/umount -l ${root}/data";
          };
        };
        # Retry native mount dependencies after late unlock/reattachment without
        # monitoring or restarting the compute node.
        systemd.timers.compute-media-export = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitInactiveSec = "30s";
          };
        };
      };
  };
}
