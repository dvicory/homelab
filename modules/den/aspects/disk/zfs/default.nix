{
  den,
  lib,
  inputs,
  ...
}:
{
  den.aspects.disk.zfs = {
    settings.preserve.datasets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            state = lib.mkOption { type = lib.types.raw; };
            requiredChildren = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          };
        }
      );
      default = { };
      description = "Explicit root-pool dataset to Preserve State mappings.";
    };

    includes = [ den.aspects.disk ];

    nixos = _: {
      imports = [
        inputs.disko-zfs.nixosModules.default
      ];

      boot.supportedFilesystems = [
        "vfat"
        "zfs"
      ];
      boot.zfs.forceImportRoot = false;
      services.zfs.autoScrub.enable = lib.mkDefault true;
    };
  };
}
