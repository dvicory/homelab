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
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:ryantm/agenix";
    };
    agenix-rekey = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:sini/agenix-rekey/feat/settings";
    };
    crowdsec-pr = {
      url = "github:dvicory/nixpkgs/crowdsec";
    };
    den = {
      url = "github:denful/den/5f78bef87047c5ecd632a5a23c9b3718f1de3301";
    };
    deploy-rs = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:serokell/deploy-rs";
    };
    devshell = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:numtide/devshell";
    };
    disko-zfs = {
      inputs = {
        flake-parts = {
          follows = "flake-parts";
        };
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:numtide/disko-zfs";
    };
    flake-file = {
      url = "github:vic/flake-file";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };
    flake-root = {
      url = "github:srid/flake-root";
    };
    gen-algebra = {
      url = "github:sini/gen-algebra/eb98c3acc4167ba30addb12edbfbb5de9706e095";
    };
    gen-lsp = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:sini/gen-lsp/6d5f4cef2676cbfddc0ed7399197d68966c18454";
    };
    gen-schema = {
      url = "github:sini/gen-schema/fd79d909cf5a84be0f902dacf4202044642d44af";
    };
    gen-scope = {
      url = "github:sini/gen-scope/3bc93dfdb49da9ae06ce84a1d35905a1c138de99";
    };
    gondolin-nix = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:dvicory/gondolin-nix/secure-terminal-v3";
    };
    hermes-agent = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:NousResearch/hermes-agent/v2026.7.20";
    };
    home-manager = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:nix-community/home-manager";
    };
    hoopsnake = {
      inputs = {
        flake-parts = {
          follows = "flake-parts";
        };
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:boinkor-net/hoopsnake/be96a49b7b212eef04f365bb75c8df947d96d1fd";
    };
    impermanence = {
      url = "github:dvicory/impermanence/systemd-requires";
    };
    import-tree = {
      url = "github:vic/import-tree";
    };
    lanzaboote = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:nix-community/lanzaboote/v0.4.1";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
    };
    nix-darwin = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:LnL7/nix-darwin";
    };
    nixos-anywhere = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:nix-community/nixos-anywhere";
    };
    nixos-facter-modules = {
      url = "github:nix-community/nixos-facter-modules";
    };
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    quadlet-nix = {
      url = "github:SEIAROTg/quadlet-nix";
    };
    secure-hermes-nix = {
      inputs = {
        gondolin-nix = {
          follows = "gondolin-nix";
        };
        hermes-agent = {
          follows = "hermes-agent";
        };
        llm-agents = {
          follows = "llm-agents";
        };
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:dvicory/secure-hermes-nix";
    };
    systems = {
      url = "github:nix-systems/triplet";
    };
  };

}
