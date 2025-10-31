/**
  # OS Builder Functions

  Provides convenient builder functions for NixOS and nix-darwin configurations.

  ## Builder Functions

  - **mkNixos**: `system -> cls -> name -> nixosSystem`
    - system: "x86_64-linux", "aarch64-linux", etc.
    - cls: "nixos", "wsl", etc. (determines which class module to load)
    - name: hostname (loads modules.nixos.${name})

  - **mkDarwin**: `system -> name -> darwinSystem`
    - system: "x86_64-darwin", "aarch64-darwin"
    - name: hostname (loads modules.darwin.${name})
  ```
*/
{
  inputs,
  self,
  lib,
  config,
  withSystem,
  ...
}:
let
  mkNixos =
    system: cls: name:
    withSystem system (
      { pkgs, ... }:
      inputs.nixpkgs.lib.nixosSystem {
        inherit system pkgs;
        modules = lib.flatten [
          {
            options.dlab = {
              hostName = lib.mkOption {
                type = lib.types.str;
              };
              # TODO: I don't like this - find a better, safer, easier way to make hostCfg available?
              hostCfg = lib.mkOption {
                type = lib.types.anything;
              };
            };

            config = {
              dlab.hostName = lib.mkForce name;
              dlab.hostCfg = lib.mkForce config.flake.dlab.hosts.${name};

              networking.hostName = lib.mkDefault name;
              nixpkgs.hostPlatform = lib.mkDefault system;
              system.stateVersion = lib.mkDefault "25.05";
            };
          }
          self.modules.nixos.${cls} # Class module (nixos, wsl, etc.)
          self.modules.nixos.${system} # System-specific module (x86_64-linux, aarch64-linux, etc.)
          self.modules.nixos."hosts-${name}" # Host-specific module
        ];
      }
    );

  mkDarwin =
    system: name:
    inputs.nix-darwin.lib.darwinSystem {
      inherit system;
      modules = lib.flatten [
        (withSystem system (
          { pkgs, ... }:
          {
            nixpkgs = { inherit pkgs; };
            # networking.hostName = lib.mkDefault name;
            nixpkgs.hostPlatform = lib.mkDefault system;
            system.stateVersion = 6;
          }
        ))
        self.modules.darwin.darwin # Base darwin module
        self.modules.darwin.${name} # Host-specific module
      ];
    };

  # Convenience builders for common configurations (deprecated - use lazy.* instead)
  nixos-x86 = mkNixos "x86_64-linux" "nixos";
  nixos-arm = mkNixos "aarch64-linux" "nixos";
  darwin-arm = mkDarwin "aarch64-darwin";
  darwin-x86 = mkDarwin "x86_64-darwin";
in
{
  # Export mk-os functions to flake.lib
  config.flake.lib.mk-os = {
    inherit mkNixos mkDarwin;
    inherit
      nixos-x86
      nixos-arm
      darwin-x86
      darwin-arm
      ;

    # Lazy helpers - don't take hostname parameter
    # Hostname will be provided by fromHosts via mapAttrs
    lazy = {
      # NixOS variants
      nixos-x86 = hostname: mkNixos "x86_64-linux" "nixos" hostname;
      nixos-arm = hostname: mkNixos "aarch64-linux" "nixos" hostname;

      # Darwin variants
      darwin-x86 = hostname: mkDarwin "x86_64-darwin" hostname;
      darwin-arm = hostname: mkDarwin "aarch64-darwin" hostname;
    };

    # Helper to build configurations from host definitions
    # Automatically passes hostname from attrset key to config function
    fromHosts = hosts: lib.mapAttrs (hostname: hostDef: hostDef.config hostname) hosts;
  };
}
