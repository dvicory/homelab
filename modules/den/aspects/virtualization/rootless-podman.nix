{ inputs, den, lib, ... }:
{
  flake-file.inputs.quadlet-nix = {
    url = "github:SEIAROTg/quadlet-nix";
  };

  den.aspects.virtualization.rootless-podman = {
    nixos = { pkgs, ... }: {
      virtualisation.podman = {
        enable = true;
        dockerCompat = false;
        defaultNetwork.settings = {
          dns_enabled = true;
        };
      };

      home-manager.sharedModules = [ inputs.quadlet-nix.homeManagerModules.quadlet ];

      users.users.hermes-runner = {
        useDefaultShell = lib.mkForce false;
      };

      nix.settings.allowed-users = lib.mkForce [ "root" "@wheel" "hermes-runner" ];
    };
  };
}
