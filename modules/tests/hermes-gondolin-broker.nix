{ self, inputs, ... }:
{
  # Both broker suites fake the VM provider boundary and run on every
  # supported dev system. Keep the legacy broker covered during the clean
  # Effect/HTTP cutover; production selects only the Effect package.
  perSystem =
    { pkgs, system, ... }:
    {
      checks =
        {
          hermes-gondolin-broker = pkgs.callPackage (self + "/pkgs/by-name/hermes-gondolin-broker/package.nix") { };
        }
        // pkgs.lib.optionalAttrs (system != "x86_64-darwin") {
          gondolin-broker-effect = inputs.secure-hermes-nix.checks.${system}.gondolin-broker-effect;
        };
    };
}
