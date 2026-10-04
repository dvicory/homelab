{
  self,
  inputs,
  ...
}:
{
  flake-file.inputs.devshell = {
    url = "github:numtide/devshell";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  flake-file.inputs.nixpkgs-multiverse.url =
    "github:fzakaria/nixpkgs-multiverse/9e89229225547747c0150f396ffa413d80bc1427";

  imports = [
    inputs.devshell.flakeModule
  ];

  perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      callPackage = pkgs.callPackage;
      isLinux = pkgs.stdenv.hostPlatform.isLinux;

      generate-secrets = callPackage (self + "/pkgs/by-name/generate-secrets/package.nix") { };
      rekey = callPackage (self + "/pkgs/by-name/rekey/package.nix") { };
      install = callPackage (self + "/pkgs/by-name/install/package.nix") { };

      agenix-restart-guard = lib.optionalAttrs isLinux {
        agenix-restart-guard = callPackage (self + "/pkgs/by-name/agenix-restart-guard/package.nix") { };
      };
      compute-runtime = callPackage (self + "/pkgs/by-name/compute-runtime/package.nix") { };
      prepare-luks-storage = lib.optionalAttrs isLinux {
        prepare-luks-storage = callPackage (self + "/pkgs/by-name/prepare-luks-storage/package.nix") { };
      };
      retained-directories-image = lib.optionalAttrs isLinux {
        retained-directories-image = callPackage (
          self + "/pkgs/by-name/retained-directories-image/package.nix"
        ) { inherit compute-runtime; };
      };
      kanidm-provision-image = lib.optionalAttrs isLinux {
        kanidm-provision-image = callPackage (
          self + "/pkgs/by-name/kanidm-provision-image/package.nix"
        ) { };
      };
      jellyfin-provisioner-image = lib.optionalAttrs isLinux {
        jellyfin-provisioner-image = callPackage (
          self + "/pkgs/by-name/jellyfin-provisioner-image/package.nix"
        ) {
          jellyfinMultiverse = inputs.nixpkgs-multiverse.multiverse.${pkgs.stdenv.hostPlatform.system};
        };
      };

      provision-keys = callPackage (self + "/pkgs/by-name/provision-keys/package.nix") {
        inherit generate-secrets rekey;
      };
    in
    {
      packages = {
        inherit
          generate-secrets
          rekey
          provision-keys
          install
          compute-runtime
          ;
      }
      // agenix-restart-guard
      // prepare-luks-storage
      // kanidm-provision-image
      // retained-directories-image
      // jellyfin-provisioner-image;

      checks = {
        compute-runtime = config.packages.compute-runtime;
      }
      // lib.optionalAttrs isLinux {
        prepare-luks-storage =
          pkgs.runCommand "prepare-luks-storage-check"
            {
              # The real tools the script runs: test.sh uses rsync and
              # python3 for copy and verify, and checks every other command
              # line's options against these binaries.
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.cryptsetup
                pkgs.findutils
                pkgs.gnugrep
                pkgs.gnused
                pkgs.gptfdisk
                pkgs.python3
                pkgs.rsync
                pkgs.systemdMinimal
                pkgs.util-linux
              ];
              REQUIRE_REAL_TOOL_CHECKS = "1";
            }
            ''
              ${pkgs.bash}/bin/bash ${self + "/pkgs/by-name/prepare-luks-storage/test.sh"}
              touch "$out"
            '';
      };

      devshells.default = {
        packages = [
          pkgs.age
          pkgs.openssh
          pkgs.coreutils
          pkgs.git
        ]
        ++ lib.optionals isLinux [
          pkgs.python3
          pkgs.rsync
          pkgs.xfsprogs
        ];

        commands =
          lib.optionals isLinux [
            {
              package = prepare-luks-storage.prepare-luks-storage;
              help = "Read-only direct-source preflight, separately approved LUKS2 format, and verified copy";
            }
          ]
          ++ [
            {
              package = generate-secrets;
              help = "Generate agenix secrets (boot keys) for a host";
            }
            {
              package = rekey;
              help = "Rekey all agenix secrets for all hosts";
            }
            {
              package = provision-keys;
              help = "Full new-host secrets provisioning pipeline";
            }
            {
              package = install;
              help = "nixos-anywhere install helper";
            }
          ];
      };
    };
}
