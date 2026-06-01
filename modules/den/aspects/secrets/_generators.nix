# Custom agenix-rekey secret generators.
# Plain NixOS module (not flake-parts) — prefix prevents import-tree auto-import.
#
# Imported by the agenix battery to provide:
#   ssh-key    - generates ed25519 SSH key pairs
#   passphrase - generates random passphrases
#   hex        - generates random hex strings
#   base64     - generates random base64 strings
{ config, lib, pkgs, ... }:
let
  inherit (lib) escapeShellArg removeSuffix;
in
{
  age.generators = {
    ssh-key =
      { pkgs, file, name, ... }:
      let
        target = config.networking.hostName or "host";
      in
      ''
        publicKeyFile=${escapeShellArg (removeSuffix ".age" file + ".pub")}
        keyfile=$(mktemp -u)
        ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 \
          -N "" -C ${escapeShellArg "${target}:${name}"} \
          -f "$keyfile" >/dev/null 2>&1
        cat "$keyfile"
        cp "$keyfile.pub" "$publicKeyFile"
        rm -f "$keyfile" "$keyfile.pub"
      '';

    passphrase =
      { pkgs, ... }:
      ''
        ${pkgs.openssl}/bin/openssl rand -base64 48 | tr -d '\n'
      '';

    hex =
      { length ? 64, ... }:
      ''
        ${pkgs.openssl}/bin/openssl rand -hex ${toString (length / 2)}
      '';

    base64 =
      { length ? 64, ... }:
      ''
        ${pkgs.openssl}/bin/openssl rand -base64 ${toString (length * 3 / 4)} | tr -d '\n'
      '';
  };
}
