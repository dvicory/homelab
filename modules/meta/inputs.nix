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
    den.url = "github:denful/den/5f78bef87047c5ecd632a5a23c9b3718f1de3301";

    gen-algebra.url = "github:sini/gen-algebra/eb98c3acc4167ba30addb12edbfbb5de9706e095";

    gen-schema.url = "github:sini/gen-schema/fd79d909cf5a84be0f902dacf4202044642d44af";

    gen-lsp = {
      url = "github:sini/gen-lsp/6d5f4cef2676cbfddc0ed7399197d68966c18454";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    scope-engine.url = "github:sini/scope-engine/6984433ba18d18dca455da5919c82e4e34d67827";

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
