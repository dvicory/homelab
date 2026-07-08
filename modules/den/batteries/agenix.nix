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
