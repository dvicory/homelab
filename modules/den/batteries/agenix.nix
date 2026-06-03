# Agenix battery — self-contained agenix + agenix-rekey integration.
#
# Declares its own flake inputs, imports agenix-rekey's flakeModule,
# and wires the host aspect for identity paths, rekey config, HM
# shared modules, and activation script safety.
#
# Modeled on sini/den-examples modules/den/batteries/agenix.nix.
{
  den,
  inputs,
  lib,
  self,
  ...
}:
let
  agenixGeneratorsModule = import ../aspects/secrets/_generators.nix;

  agenixHostAspect =
    {
      host,
      secretsConfig,
      ...
    }:
    let
      hasImpermanence = host.hasAspect den.aspects.disk.impermanence;
      persistPrefix = lib.optionalString hasImpermanence "/persist";
    in
    {
      name = "agenix/${host.name}";
      ${host.class} =
        { config, lib, ... }:
        {
          imports = [
            inputs.agenix."${host.class}Modules".default
            inputs.agenix-rekey."${host.class}Modules".default
            agenixGeneratorsModule
          ];

          age = {
            identityPaths = [
              "${persistPrefix}/etc/ssh/ssh_host_ed25519_key"
            ];

            rekey = {
              # inherit (secretsConfig) masterIdentities;
              masterIdentities = [
                {
                  identity = self + "/.secrets/keys/master.age";
                  pubkey = self + "/.secrets/pub/master.pub";
                }
              ];

              storageMode = "local";
              hostPubkey = builtins.readFile host.public_key;
              generatedSecretsDir = host.secretPath + "/generated";
              localStorageDir = host.secretPath + "/rekeyed";
            };
          };

          # Remove agenix directory before switching if it's a dir instead of link
          system.activationScripts = lib.mkIf (host.class == "nixos" && config.age.secrets != { }) {
            removeAgenixLink.text = "[[ ! -L /run/agenix ]] && [[ -d /run/agenix ]] && rm -rf /run/agenix";
            agenixNewGeneration.deps = [ "removeAgenixLink" ];
          };

          # Make secrets paths available as module arg
          _module.args.secrets = lib.mapAttrs (_: v: v.path) config.age.secrets;

          home-manager.sharedModules = [
            inputs.agenix.homeManagerModules.default
            inputs.agenix-rekey.homeManagerModules.default
            (
              { config, lib, ... }:
              {
                _module.args.secrets = lib.mapAttrs (_: v: v.path) config.age.secrets;
              }
            )
          ];
        };
    };

  agenixUserAspect =
    {
      user,
      host,
      secretsConfig,
      ...
    }:
    {
      name = "agenix-identity/${user.name}@${host.name}";
      ${host.class} =
        _:
        {
          age.secrets."user-identity-${user.name}" = {
            rekeyFile = self + "/.secrets/users/${user.name}/id_agenix.age";
            owner = user.name;
            group = user.name;
            mode = "600";
            generator.script = "age-identity";
          };
        };
      homeManager =
        { osConfig, ... }:
        {
          age = {
            identityPaths = lib.optionals (osConfig.age.secrets ? "user-identity-${user.name}") [
              osConfig.age.secrets."user-identity-${user.name}".path
            ];

            rekey = {
              # inherit (secretsConfig) masterIdentities;
              masterIdentities = [
                {
                  identity = self + "/.secrets/keys/master.age";
                  pubkey = self + "/.secrets/pub/master.pub";
                }
              ];

              storageMode = "local";
              hostPubkey =
                if (osConfig.age.secrets ? "user-identity-${user.name}") then
                  (self + "/.secrets/users/${user.name}/id_agenix.pub")
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

  den.schema.host.includes = [
    agenixHostAspect
    den.aspects.core.secrets-collector
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
        nixosConfigurations = inputs.self.outputs.nixosConfigurations;
        darwinConfigurations = inputs.self.outputs.darwinConfigurations;
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
