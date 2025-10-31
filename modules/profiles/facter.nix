{ inputs, ... }:
{
  flake-file.inputs = {
    nixos-facter-modules.url = "github:nix-community/nixos-facter-modules";
  };

  flake.modules.nixos.profiles-facter =
    { config, ... }:
    {
      imports = [
        inputs.nixos-facter-modules.nixosModules.facter
      ];

      facter.reportPath = ../hosts/${config.dlab.hostName}/facter.json;
    };
}
