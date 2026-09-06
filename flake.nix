# DO-NOT-EDIT. This file was auto-generated using github:vic/flake-file.
# Use `nix run .#write-flake` to regenerate it.
{
  description = "Homelab3 - Dendritic Architecture";

  outputs =
    inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree [ ./modules ]);

  nixConfig = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://dvicory-homelab.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "dvicory-homelab.cachix.org-1:QqOtWxxrlmcq0ZPYM5C3H/SkF/DIYg39hHvyomTS3AY="
    ];
  };

  inputs = {
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix-rekey = {
      url = "github:sini/agenix-rekey/feat/settings";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crowdsec-pr.url = "github:dvicory/nixpkgs/crowdsec";
    den.url = "github:denful/den/5f78bef87047c5ecd632a5a23c9b3718f1de3301";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko-zfs = {
      url = "github:numtide/disko-zfs";
      inputs = {
        flake-parts.follows = "flake-parts";
        nixpkgs.follows = "nixpkgs";
      };
    };
    flake-file.url = "github:vic/flake-file";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-root.url = "github:srid/flake-root";
    gen-algebra.url = "github:sini/gen-algebra/eb98c3acc4167ba30addb12edbfbb5de9706e095";
    gen-lsp = {
      url = "github:sini/gen-lsp/6d5f4cef2676cbfddc0ed7399197d68966c18454";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    gen-schema.url = "github:sini/gen-schema/fd79d909cf5a84be0f902dacf4202044642d44af";
    gen-scope.url = "github:sini/gen-scope/3bc93dfdb49da9ae06ce84a1d35905a1c138de99";
    gondolin-nix = {
      url = "github:dvicory/gondolin-nix/secure-terminal-v3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.7.20";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hoopsnake = {
      url = "github:boinkor-net/hoopsnake/106a95e01352db2143f355fba1a328c887e0c807";
      inputs = {
        flake-parts.follows = "flake-parts";
        nixpkgs.follows = "nixpkgs";
      };
    };
    impermanence.url = "github:dvicory/impermanence/systemd-requires";
    import-tree.url = "github:vic/import-tree";
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents.url = "github:numtide/llm-agents.nix";
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-facter-modules.url = "github:nix-community/nixos-facter-modules";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    quadlet-nix.url = "github:SEIAROTg/quadlet-nix";
    secure-hermes-nix = {
      url = "github:dvicory/secure-hermes-nix";
      inputs = {
        gondolin-nix.follows = "gondolin-nix";
        hermes-agent.follows = "hermes-agent";
        llm-agents.follows = "llm-agents";
        nixpkgs.follows = "nixpkgs";
      };
    };
    systems.url = "github:nix-systems/triplet";
  };
}
