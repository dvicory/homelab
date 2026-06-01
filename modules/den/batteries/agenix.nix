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
    { host, ... }:
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
              masterIdentities =
                let
                  envIdentity = builtins.getEnv "AGENIX_MASTER_IDENTITY";
                in
                  lib.optional (envIdentity != "") envIdentity
                  ++ [ (self + "/.secrets/priv/master.age") ];
              storageMode = "local";
              hostPubkey = builtins.readFile host.public_key;
              generatedSecretsDir = host.secretPath + "/generated";
              localStorageDir = host.secretPath + "/rekeyed";
            };
          };

          system.activationScripts = lib.mkIf (
            host.class == "nixos" && config.age.secrets != { }
          ) {
            removeAgenixLink.text = "[[ ! -L /run/agenix ]] && [[ -d /run/agenix ]] && rm -rf /run/agenix";
            agenixNewGeneration.deps = [ "removeAgenixLink" ];
          };

          _module.args.secrets = lib.mapAttrs (_: v: v.path) config.age.secrets;

          home-manager.sharedModules = [
            inputs.agenix.homeManagerModules.default
            inputs.agenix-rekey.homeManagerModules.default
            (
              { config, lib, ... }:
              {
                _module.args.secrets = lib.mapAttrs (_: v: v.path) config.age.secrets;

                age.rekey.masterIdentities =
                  let
                    envIdentity = builtins.getEnv "AGENIX_MASTER_IDENTITY";
                  in
                    lib.optional (envIdentity != "") envIdentity
                    ++ [ (self + "/.secrets/priv/master.age") ];
              }
            )
          ];
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

  perSystem =
    { ... }:
    {
      agenix-rekey = {
        nixosConfigurations = inputs.self.outputs.nixosConfigurations or { };
        darwinConfigurations = { };
      };

      # Set AGENIX_REKEY_ADD_TO_GIT=true when running agenix CLI commands
      # so rekeyed files are auto-added to git. If using devshell /
      # mission-control, add this to your shell env:
      #   AGENIX_REKEY_ADD_TO_GIT=true
    };
}
