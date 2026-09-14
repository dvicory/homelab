{
  den,
  lib,
  inputs,
  ...
}:
{
  den.aspects.disk.zfs = {
    settings.preserveNamespace = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Logical namespace for plan-only root-pool state realizations.";
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
