{ lib, inputs, ... }:
let
  inherit (lib) mkOption types;
  self = inputs.self;
in {
  options.den.secretsConfig = {
    masterIdentities = mkOption {
      type = types.listOf types.path;
      description = "Age master identity paths for agenix-rekey (private keys or age-plugin refs).";
    };
  };

  config.den.secretsConfig = {
    masterIdentities = [
      (self + "/.secrets/pub/master.key")
    ];
  };
}
