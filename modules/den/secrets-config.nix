# Canonical den.secretsConfig option — single source of truth for master
# identity paths used by agenix, nixidy, and sops-config.
#
# NOTE: age.rekey.masterIdentities (per-host decryption identities at
# rekey time) is set by the agenix battery in batteries/agenix.nix.
# This fleet-level option documents available master key pub files.
{
  lib,
  self,
  ...
}:
let
  inherit (lib) mkOption types;
  identitySetType = types.submodule {
    options = {
      identity = mkOption {
        type = types.path;
        description = "Path to the local age identity file (or encrypted envelope).";
      };
      pubkey = mkOption {
        type = types.oneOf [ types.str types.path ];
        description = "Path to the corresponding public key file.";
      };
    };
  };
in
{
  options.den.secretsConfig = {
    masterIdentities = mkOption {
      type = types.listOf (types.oneOf [
        types.str
        types.path
        identitySetType
      ]);
      description = "Age master identity public key paths or configuration objects for agenix-rekey.";
    };
  };

  config.den.secretsConfig = {
    masterIdentities = [
      {
        identity = self + "/.secrets/keys/master.age";
        pubkey = self + "/.secrets/pub/master.pub";
      }
    ];
  };
}
