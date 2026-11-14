{ system }:
let
  # Exact pre-upgrade production input; never follow the candidate fleet lock.
  source = builtins.fetchTarball {
    url = "https://releases.nixos.org/nixos/unstable/nixos-26.11pre1067334.801bef6abd86/nixexprs.tar.xz";
    sha256 = "sha256-/Mz6ovEL+KZ9b0UkWEBd/DtmODXuXW3FhNnuGQYghvg=";
  };
  pkgs = import source { inherit system; };
in
assert pkgs.incus.version == "7.4.0";
assert pkgs.tailscale.version == "1.102.3";
pkgs
