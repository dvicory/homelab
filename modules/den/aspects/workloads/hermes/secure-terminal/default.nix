# Gondolin/QEMU secure-terminal backend for Hermes (V3).
#
# This module tree implements the brokered sandbox architecture: a Node 22
# broker consuming a systemd-activated, profile-owned Unix socket; immutable
# Nix-built guest assets; and policy JSON rendered at evaluation time. The
# gateway's only sandbox capability is the broker socket.
{ ... }:
{
  # Commit-pinned guest-asset builder and host SDK packaging, following this
  # flake's Nixpkgs (V3 §9.1). Declared beside the Hermes workload it serves;
  # regenerate the flake with `nix run .#write-flake --impure` after changes.
  flake-file.inputs.gondolin-nix = {
    url = "github:dvicory/gondolin-nix/secure-terminal-v3";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
