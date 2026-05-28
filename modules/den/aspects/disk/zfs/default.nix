{ lib, inputs, ... }: {
  den.aspects.disk.zfs = {
    nixos = _: {
      imports = [
        inputs.disko-zfs.nixosModules.default
      ];

      boot.supportedFilesystems = [ "vfat" "zfs" ];
      boot.zfs.forceImportRoot = false;
      services.zfs.autoScrub.enable = lib.mkDefault true;
    };
  };
}
