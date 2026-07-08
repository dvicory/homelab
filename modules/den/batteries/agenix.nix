# Agenix battery — flake-level plumbing for agenix/agenix-rekey.
#
# This battery provides:
# - flake-file.inputs (agenix, agenix-rekey)
# - agenix-rekey.flakeModule (wires the `agenix` CLI in the devshell)
# - perSystem config (devshell command, rekey targets)
# - agenixUserAspect → den.schema.user.includes (per-user home-manager
#   agenix identity, skipped for MicroVM guests)
#
# Sini puts ALL agenix config (module imports, secretRequests, age.rekey,
# age.identityPaths) in an agenixHostAspect via den.schema.host.includes.
# We deviate: that config lives in aspects/secrets/agenix.nix instead.
# The reason is MicroVM guests. Sini's guests use intoAttr = [] so they're
# never evaluated standalone — they only exist inside microvm.vms, where
# den.schema.host.includes IS applied. Our guests need standalone
# nixosConfiguration output (for microvm -u and nix eval), but when
# spliced into microvm.vms by the guest resolver, den.schema.host.includes
# are NOT applied (only explicit aspect includes are resolved by
# den.lib.aspects.resolve). Moving agenix config into the secrets.agenix
# aspect (an explicit include) ensures it works in both contexts.
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
      isGuest = host.microvm.isGuest or false;
    in
    {
      name = "agenix-identity/${user.name}@${host.name}";
      ${host.class} =
        _:
        {
          age.secrets."user-identity-${user.name}" = {
            rekeyFile = self + "/.secrets/users/${user.name}/user-identity-${user.name}.age";
            owner = user.name;
            group = user.name;
            mode = "600";
            generator.script = "age-identity";
          };
        };
    } // lib.optionalAttrs (!isGuest) {
      # home-manager integration — skip for MicroVM guests (no home-manager
      # module imported in the guest's spliced config).
      homeManager =
        { osConfig, ... }:
        {
          age = {
            identityPaths = lib.optionals (osConfig.age.secrets ? "user-identity-${user.name}") [
              osConfig.age.secrets."user-identity-${user.name}".path
            ];

            rekey = {
              inherit (secretsConfig) masterIdentities;
              storageMode = "local";
              hostPubkey =
                if (osConfig.age.secrets ? "user-identity-${user.name}") then
                  (self + "/.secrets/users/${user.name}/user-identity-${user.name}.pub")
                else
                  osConfig.age.rekey.hostPubkey;
              generatedSecretsDir = self + "/.secrets/generated/${user.name}/${host.name}";
              localStorageDir = self + "/.secrets/rekeyed/${user.name}/${host.name}";
            };
          };
        };
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
        nixosConfigurations = inputs.self.outputs.nixosConfigurations;
        # darwinConfigurations = inputs.self.outputs.darwinConfigurations;
        collectHomeManagerConfigurations = true;
        extraConfigurations = { };
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
        env = [
          {
            name = "AGENIX_REKEY_ADD_TO_GIT";
            value = "true";
          }
        ];
      };
    };
}
