{ inputs, ... }:
{
  imports = [
    inputs.flake-root.flakeModule
    inputs.agenix-rekey.flakeModule
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

    # Den aspect-oriented framework (sini fork with quirk pipes and dynamic settingsType)
    den.url = "github:sini/den/feat/entity-gen-schema-port";

    # gen-schema (entity schema library required by den fork)
    gen-schema.url = "github:sini/gen-schema";
    gen-schema.inputs.nixpkgs.follows = "nixpkgs";

    # Secret management
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";

    agenix-rekey.url = "github:sini/agenix-rekey/feat/settings";
    agenix-rekey.inputs.nixpkgs.follows = "nixpkgs";

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
