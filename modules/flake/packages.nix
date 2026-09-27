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

  imports = [
    inputs.devshell.flakeModule
  ];

  perSystem =
    { pkgs, lib, ... }:
    let
      callPackage = pkgs.callPackage;
      isLinux = pkgs.stdenv.hostPlatform.isLinux;

      generate-secrets = callPackage (self + "/pkgs/by-name/generate-secrets/package.nix") { };
      rekey = callPackage (self + "/pkgs/by-name/rekey/package.nix") { };
      install = callPackage (self + "/pkgs/by-name/install/package.nix") { };

      agenix-restart-guard = lib.optionalAttrs isLinux {
        agenix-restart-guard = callPackage (self + "/pkgs/by-name/agenix-restart-guard/package.nix") { };
      };
      compute-runtime = lib.optionalAttrs isLinux {
        compute-runtime = callPackage (self + "/pkgs/by-name/compute-runtime/package.nix") { };
      };
      prepare-luks-storage = lib.optionalAttrs isLinux {
        prepare-luks-storage = callPackage (self + "/pkgs/by-name/prepare-luks-storage/package.nix") { };
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
          ;
      }
      // agenix-restart-guard
      // compute-runtime
      // prepare-luks-storage;

      checks =
        compute-runtime
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
