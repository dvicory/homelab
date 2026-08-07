{ self, ... }:
{
  # Both broker suites fake the VM provider boundary and run on every
  # supported dev system. Keep the legacy broker covered during the clean
  # Effect/HTTP cutover; production selects only the Effect package.
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        hermes-gondolin-broker = pkgs.callPackage (self + "/pkgs/by-name/hermes-gondolin-broker/package.nix") { };
        gondolin-broker-effect = pkgs.callPackage (self + "/pkgs/by-name/gondolin-broker-effect/package.nix") { };
      };
    };
}
