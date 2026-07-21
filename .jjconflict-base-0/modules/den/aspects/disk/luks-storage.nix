{ den, self, lib, ... }:
{
  den.aspects.disk.luks-storage = {
    settings.disks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          # Device path that cryptsetup will open. Typically
          # `/dev/disk/by-id/<suffix>` for a whole disk or
          # `/dev/disk/by-id/<suffix>-part1` for a partitioned disk.
          # The path is used verbatim in the crypttab row, so users
          # with non-default layouts (multiple partitions, LVM PVs,
          # ZFS labels) can point at whatever device holds the LUKS
          # header.
          device = lib.mkOption {
            type = lib.types.str;
            example = "/dev/disk/by-id/wwn-0x5000cca27061f6b4-part1";
            description = "Full device path that cryptsetup will open.";
          };
          mapperName = lib.mkOption {
            type = lib.types.str;
            default = "crypt-${name}";
            defaultText = lib.literalExpression ''"crypt-${"\${name}"}"'';
            description = "Device-mapper name (becomes /dev/mapper/<name>).";
          };
          mountpoint = lib.mkOption {
            type = lib.types.str;
            description = "Where to mount the unlocked filesystem.";
          };
          fsType = lib.mkOption {
            type = lib.types.str;
            description = "Filesystem type for the unlocked volume (e.g. btrfs, ext4).";
          };
          mountOptions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "defaults"
              "noatime"
            ];
            description = "Mount options for the unlocked filesystem.";
          };
          # Two-phase provisioning: false (the default) emits only the
          # agenix secret; true adds the crypttab row and fileSystems
          # entry. Run `prepare-luks-storage` on the host between the
          # two deploys.
          provisioned = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Set true after `prepare-luks-storage` runs on the host.";
          };
        };
      }));
      default = { };
      description = "LUKS-encrypted data disks managed by this aspect.";
    };

    nixos = { host, config, lib, ... }: let
      cfg = host.settings.disk.luks-storage.disks or { };
      readyDisks = lib.filterAttrs (_: d: d.provisioned) cfg;
    in lib.mkIf (cfg != { }) {
      secretRequests = lib.mapAttrs' (name: d: {
        name = "luks-${name}-key";
        value = {
          provider = "agenix";
          ageFile = self + "/.secrets/hosts/${host.name}/luks-${name}-key.age";
          mode = "0400";
          restartUnits = lib.optional (d.provisioned) "systemd-cryptsetup@${d.mapperName}.service";
          # Generator defined in modules/den/aspects/secrets/_generators.nix
          generator.script = "luks-key";
        };
      }) cfg;

      environment.etc."crypttab".text = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: d: lib.concatStringsSep " " [
          d.mapperName
          d.device
          "/run/agenix/luks-${name}-key"
          "luks,discard"
        ]) readyDisks
      ) + "\n";

      fileSystems = lib.mapAttrs' (_: d:
        lib.nameValuePair d.mountpoint {
          device = "/dev/mapper/${d.mapperName}";
          fsType = d.fsType;
          options = d.mountOptions;
        }
      ) readyDisks;
    };
  };
}
