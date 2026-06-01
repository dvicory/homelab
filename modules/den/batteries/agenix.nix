# Agenix battery: imports agenix + agenix-rekey modules, configures
# age.rekey with master identities and host pubkeys, wires identity paths.
#
# Secrets directory: .secrets/hosts/<hostname>/
# Master identity:   .secrets/pub/master.key  (SSH-derived age public key)
# Host pubkey:       .secrets/hosts/<hostname>/ssh_host_ed25519_key.pub
{
  den,
  inputs,
  lib,
  self,
  ...
}:
let
  agenixHostAspect =
    { host, ... }:
    {
      name = "agenix/${host.name}";
      ${host.class} =
        { config, lib, pkgs, ... }:
        {
          imports = [
            inputs.agenix."${host.class}Modules".default
            inputs.agenix-rekey."${host.class}Modules".default
            (./. + "/../aspects/secrets/_generators.nix")
          ];
          age = {
            identityPaths = [
              "/persist/etc/ssh/ssh_host_ed25519_key"
            ];

            rekey = {
              masterIdentities = [
                (builtins.getEnv "AGENIX_MASTER_IDENTITY")
              ];
              storageMode = "local";
              hostPubkey = builtins.readFile host.public_key;
              generatedSecretsDir = host.secretPath + "/generated";
              localStorageDir = host.secretPath + "/rekeyed";
            };
          };

          _module.args.secrets = lib.mapAttrs (_: v: v.path) config.age.secrets;
        };
    };
in
{
  den.schema.host.includes = [
    agenixHostAspect
    den.aspects.core.secrets-collector
  ];
}
