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
      prepare-luks-storage = lib.optionalAttrs isLinux {
        prepare-luks-storage = callPackage (self + "/pkgs/by-name/prepare-luks-storage/package.nix") { };
      };

      provision-keys = callPackage (self + "/pkgs/by-name/provision-keys/package.nix") {
        inherit generate-secrets rekey;
      };
    in
    {
      packages = {
        inherit generate-secrets rekey provision-keys install;
      } // prepare-luks-storage;

      devshells.default = {
        packages = [
          pkgs.age
          pkgs.openssh
          pkgs.coreutils
          pkgs.git
        ];

        commands = lib.optionals isLinux [
          {
            package = prepare-luks-storage.prepare-luks-storage;
            help = "One-shot provisioner for a LUKS-encrypted btrfs data disk";
          }
        ] ++ [
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
