# Custom agenix-rekey secret generators.
# Plain NixOS module (not flake-parts) — prefix prevents import-tree auto-import.
#
# Imported by the agenix battery. Extends the built-in generators from
# agenix-rekey with:
#   alnum-no-newline - 48 alphanumeric bytes without a trailing newline
#   ssh-key         - generates ed25519 SSH key pairs
#   age-identity    - generates age x25519 identity (referenced by the
#                     agenix user-identity secret in
#                     modules/den/batteries/agenix.nix)
#   luks-key        - 4096 random bytes, used as a LUKS key file
{ config, lib, ... }:
let
  inherit (lib) escapeShellArg removeSuffix;
in
{
  age.generators = {
    ssh-key =
      {
        pkgs,
        file,
        name,
        ...
      }:
      let
        target = config.networking.hostName or "host";
      in
      ''
        publicKeyFile=${escapeShellArg (removeSuffix ".age" file + ".pub")}
        (
          # The private key exists unencrypted only during generation. A
          # created, mode-700 directory avoids the race inherent in mktemp -u.
          umask 077
          keyDir=$(${pkgs.coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/ssh-key-XXXXXX")
          trap '${pkgs.coreutils}/bin/rm -rf "$keyDir"' EXIT
          keyfile="$keyDir/ssh-key"

          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 \
            -N "" -C ${escapeShellArg "${target}:${name}"} \
            -f "$keyfile" >/dev/null 2>&1
          cat "$keyfile"
          cp "$keyfile.pub" "$publicKeyFile"
          ${pkgs.coreutils}/bin/chmod 0644 "$publicKeyFile"
        )
      '';

    # 32 hex characters: the API key form Radarr, Sonarr and SABnzbd
    # generate for themselves.
    api-key =
      { pkgs, ... }:
      ''
        ${pkgs.openssl}/bin/openssl rand -hex 16 | ${pkgs.coreutils}/bin/tr -d '\n'
      '';

    alnum-no-newline =
      { pkgs, ... }:
      ''
        ${pkgs.pwgen}/bin/pwgen -s 48 1 | ${pkgs.coreutils}/bin/tr -d '\n'
      '';

    # 4096 bytes of random data, suitable as a LUKS key file. The
    # amount of entropy is well above what LUKS considers secure and
    # exceeds the maximum key length, both of which are fine — LUKS
    # hashes the input to derive the actual slot key.
    luks-key =
      { pkgs, ... }:
      ''
        ${pkgs.coreutils}/bin/dd if=/dev/urandom bs=1 count=4096 status=none
      '';

    # age x25519 identity. The public key is written to a `.pub`
    # file adjacent to the .age file; the secret key is on stdout
    # and gets encrypted into the .age file.
    age-identity =
      {
        pkgs,
        file,
        ...
      }:
      ''
        publicKeyFile=${escapeShellArg (removeSuffix ".age" file + ".pub")}
        ${pkgs.age}/bin/age-keygen 2> "$publicKeyFile"
      '';
  };
}
