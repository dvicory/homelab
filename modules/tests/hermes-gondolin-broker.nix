{ self, ... }:
{
  # The Gondolin broker's test suite fakes the VM provider boundary and
  # never requires QEMU/KVM, so it runs on every supported dev system
  # (Linux and aarch64-darwin alike).
  perSystem =
    { pkgs, ... }:
    {
      checks.hermes-gondolin-broker = pkgs.callPackage (self + "/pkgs/by-name/hermes-gondolin-broker/package.nix") { };
    };
}
