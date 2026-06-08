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
      "https://cache.garnix.io"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
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
      url = "github:sini/den/feat/entity-gen-schema-port";
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
      url = "github:sini/gen-algebra";
    };
    gen-schema = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:sini/gen-schema";
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
    scope-engine = {
      url = "github:sini/scope-engine";
    };
    sops-nix = {
      inputs = {
        nixpkgs = {
          follows = "nixpkgs";
        };
      };
      url = "github:Mic92/sops-nix";
    };
    systems = {
      url = "github:nix-systems/default";
    };
  };

}
