{
  den,
  inputs,
  lib,
  ...
}:
{
  flake-file.inputs.quadlet-nix.url = "github:SEIAROTg/quadlet-nix";

  # Host runtime. This aspect deliberately knows nothing about workloads or
  # user names; those arrive through parametric user aspects.
  den.aspects.virtualization.podman.nixos = {
    imports = [ inputs.quadlet-nix.nixosModules.quadlet ];

    virtualisation = {
      podman = {
        enable = true;
        dockerCompat = false;
        defaultNetwork.settings.dns_enabled = true;
      };
      quadlet.enable = true;
    };
  };

  # Host-side capability for an account that is allowed to build and activate
  # its standalone profile. This grants ordinary daemon access, never trust.
  den.aspects.virtualization.podman-user =
    { user, ... }:
    {
      name = "podman-user/${user.userName}";
      includes = [ den.aspects.virtualization.podman ];
      nixos =
        { pkgs, ... }:
        {
          users.users.${user.userName}.packages = [ pkgs.home-manager ];
          nix.settings.allowed-users = [ user.userName ];
        };
    };

  # Standalone-home capability. Keeping it separate from podman-user prevents
  # workload Quadlets from being spliced into a host rebuild through P-edges.
  den.aspects.virtualization.quadlet-home =
    { home, ... }:
    {
      name = "quadlet-home/${home.userName}";
      homeManager = {
        imports = [ inputs.quadlet-nix.homeManagerModules.quadlet ];
        programs.home-manager.enable = true;
      };
    };
}
