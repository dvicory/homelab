# Agenix battery — flake-level plumbing for agenix/agenix-rekey.
#
# This battery provides:
# - flake-file.inputs (agenix, agenix-rekey)
# - agenix-rekey.flakeModule (wires the `agenix` CLI in the devshell)
# - perSystem config (devshell command, rekey targets)
# - agenixUserAspect → den.schema.user.includes (per-user home-manager
#   agenix identity)
#
# Sini puts ALL agenix config (module imports, secretRequests, age.rekey,
# age.identityPaths) in an agenixHostAspect via den.schema.host.includes.
# We deviate: that config lives in aspects/secrets/agenix.nix instead,
# keeping it as an explicit aspect include.
{
  den,
  inputs,
  lib,
  self,
  config,
  ...
}:
let
  agenixUserAspect =
    {
      user,
      host,
      secretsConfig,
      ...
    }:
    let
      materializeSecrets = host.settings.core.users.secrets.enable or true;
      hasIdentity = materializeSecrets && (user.identity.sshKeys or [ ]) != [ ];
      identityFile = self + "/.secrets/users/${user.name}/user-identity-${user.name}.age";
      identityPub = self + "/.secrets/users/${user.name}/user-identity-${user.name}.pub";

      nixosSecret = lib.optionalAttrs hasIdentity {
        age.secrets."user-identity-${user.name}" = {
          rekeyFile = identityFile;
          owner = user.userName;
          group = if host.class == "darwin" then "staff" else user.userName;
          mode = "600";
          generator.script = "age-identity";
        };
      };

      homeCfg =
        { osConfig, ... }:
        lib.optionalAttrs materializeSecrets {
          age = {
            identityPaths = lib.optionals (osConfig.age.secrets ? "user-identity-${user.name}") [
              osConfig.age.secrets."user-identity-${user.name}".path
            ];
            rekey = {
              inherit (secretsConfig) masterIdentities;
              storageMode = "local";
              hostPubkey =
                if (osConfig.age.secrets ? "user-identity-${user.name}") then
                  identityPub
                else
                  osConfig.age.rekey.hostPubkey;
              generatedSecretsDir = self + "/.secrets/generated/${user.name}/${host.name}";
              localStorageDir = self + "/.secrets/rekeyed/${user.name}/${host.name}";
            };
          };
        };
    in
    {
      name = "agenix-identity/${user.name}@${host.name}";
      ${host.class} = _: nixosSecret;
      homeManager = homeCfg;
    };
in
{
  flake-file.inputs = {
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix-rekey = {
      url = "github:sini/agenix-rekey/feat/settings";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  imports = [
    inputs.agenix-rekey.flakeModule
  ];

  den.schema.user.includes = [ agenixUserAspect ];

  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    {
      agenix-rekey = {
        agePackage = pkgs.age;
      };

      devshells.default = {
        packages = [
          pkgs.age
        ];
        commands = [
          {
            inherit (config.agenix-rekey) package;
            help = "Manage agenix secrets (edit, view, generate, rekey)";
          }
        ];
      };
    };
}
