{ lib, inputs, ... }: {
  den.aspects.disk = {
    nixos = _: {
      imports = [
        inputs.nixos-anywhere.inputs.disko.nixosModules.disko
      ];

      fileSystems."/boot".neededForBoot = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.systemd-boot = {
        enable = true;
        configurationLimit = 8;
      };
    };
  };
}
