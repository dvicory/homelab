{ inputs, ... }: {
  den.aspects."dlab/profile/facter" = {
    nixos = { config, ... }: {
      imports = [ inputs.nixos-facter-modules.nixosModules.facter ];

      facter.reportPath = ../../hosts + "/${config.networking.hostName}/facter.json";
    };
  };
}
