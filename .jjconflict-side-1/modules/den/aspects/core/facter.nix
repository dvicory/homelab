{ inputs, ... }: {
  den.aspects.core.facter = {
    nixos = { host, config, ... }: {
      imports = [ inputs.nixos-facter-modules.nixosModules.facter ];

      facter = {
        reportPath = inputs.self + "/modules/den/hosts/${host.name}/facter.json";
        detected = {
          dhcp.enable = false;
          graphics.enable = false;
        };
      };
    };
  };
}
