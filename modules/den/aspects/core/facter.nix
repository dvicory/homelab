{ inputs, ... }: {
  den.aspects.core.facter = {
    nixos = { config, ... }: {
      imports = [ inputs.nixos-facter-modules.nixosModules.facter ];

      facter.reportPath = inputs.self + "/modules/den/hosts/${config.networking.hostName}/facter.json";
    };
  };
}
