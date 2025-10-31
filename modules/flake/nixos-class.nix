/**
  # NixOS Class Module

  This module includes:
  - Contracts infrastructure (secret provider, contract definitions)
  - Base profile (packages, SSH, nix settings)

  All NixOS systems automatically get these through the class module.
*/
{ self, ... }:
{
  # Define the nixos class module
  flake.modules.nixos.nixos =
    { ... }:
    {
      imports = [
        # Contracts infrastructure - provides _contracts to all NixOS modules
        self.modules.nixos.contracts-provider

        # SOPS provider - imported at class level so it's available to all systems
        self.modules.nixos.secret-sops-provider

        # Base profile - provides reasonable defaults for all NixOS systems
        self.modules.nixos.profiles-base
      ];
    };

  flake.modules.nixos.aarch64-linux = { };
  flake.modules.nixos.x86_64-linux = { };
}
