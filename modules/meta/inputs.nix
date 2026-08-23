{ inputs, ... }:
{
  imports = [
    inputs.flake-root.flakeModule
  ];

  # Define all flake inputs
  flake-file.inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

    # Secure Boot
    lanzaboote.url = "github:nix-community/lanzaboote/v0.4.1";
    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";

    # Darwin
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # Home Manager
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # Remote installation
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";

    # Den and the entity/scope libraries used by local fleet schemas.
    den.url = "github:denful/den";

    gen-schema.url = "github:sini/gen-schema";

    scope-engine.url = "github:sini/scope-engine";

    # agenix + agenix-rekey declared by batteries/agenix.nix (self-contained)

    # Impermanence
    impermanence.url = "github:dvicory/impermanence/systemd-requires";

    # Hardware detection
    nixos-facter-modules.url = "github:nix-community/nixos-facter-modules";

    # Remote ZFS unlock
    hoopsnake = {
      url = "github:boinkor-net/hoopsnake/be96a49b7b212eef04f365bb75c8df947d96d1fd";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };

    # ZFS disk layout via disko
    disko-zfs = {
      url = "github:numtide/disko-zfs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };

    # Flake root detection
    flake-root.url = "github:srid/flake-root";

  };
}
