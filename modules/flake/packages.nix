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
    { pkgs, ... }:
    let
      callPackage = pkgs.callPackage;

      generate-secrets = callPackage (self + "/pkgs/by-name/generate-secrets/package.nix") { };
      rekey = callPackage (self + "/pkgs/by-name/rekey/package.nix") { };
      install = callPackage (self + "/pkgs/by-name/install/package.nix") { };

      provision-keys = callPackage (self + "/pkgs/by-name/provision-keys/package.nix") {
        inherit generate-secrets rekey;
      };
    in
    {
      packages = {
        inherit generate-secrets rekey provision-keys install;
      };

      devshells.default = {
        packages = [
          pkgs.age
          pkgs.openssh
          pkgs.coreutils
          pkgs.git
        ];

        commands = [
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
