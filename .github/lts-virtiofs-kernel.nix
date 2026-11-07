# Disposable compiler target; not imported by the fleet flake.
let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  input = lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
  nixpkgs = builtins.fetchTarball {
    inherit (input) url;
    sha256 = input.narHash;
  };
  pkgs = import nixpkgs { system = "x86_64-linux"; };
in
assert pkgs.linuxPackages_6_18.kernel.version == "6.18.49";
pkgs.linuxPackages_6_18.kernel.override {
  argsOverride = {
    version = "6.18.62";
    modDirVersion = "6.18.62";
    src = pkgs.fetchurl {
      url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.62.tar.xz";
      hash = "sha256-SQp67fGzVcVl06bAUzPMzLXaggZOyka1kESKcJnX1lE=";
    };
  };
}
