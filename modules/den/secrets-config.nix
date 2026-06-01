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
in
{
  options.den.secretsConfig = {
    masterIdentities = mkOption {
      type = types.listOf types.path;
      description = "Age master identity public key paths for agenix-rekey";
    };
  };

  config.den.secretsConfig = {
    masterIdentities = [
      (self + "/.secrets/pub/master.key")
    ];
  };
}
