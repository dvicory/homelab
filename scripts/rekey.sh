#!/usr/bin/env bash
# rekey.sh — Generate boot keys and rekey all agenix secrets.
# Runs rage directly (not inside a Nix derivation), so master identity
# at ~/.config/agenix/master.age is accessible.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

MASTER_ID="$HOME/.config/agenix/master.age"

# agenix-rekey computes the rekeyed file hash as:
#   identHash = substring(0, 32, hashString("sha256", hashString("sha256", hostPubkey) + hashFile("sha256", rekeyFile)))
# 
# hostPubkey is read with builtins.readFile (keeps trailing newline).
# hashString/hashFile use Nix's sha256 which matches sha256sum.
age_rekey_hash() {
  local host_key_file=$1 rekey_file=$2
  local pubkey_hash=$(cat "$host_key_file" | sha256sum | cut -d' ' -f1)
  local file_hash=$(sha256sum "$rekey_file" | cut -d' ' -f1)
  echo -n "${pubkey_hash}${file_hash}" | sha256sum | cut -c1-32
}

rekey_one() {
  local host=$1 host_ssh_pub_file=$2
  local host_ssh_pub=$(<"$host_ssh_pub_file")
  local srcdir=".secrets/hosts/$host"
  local dstdir="$srcdir/rekeyed"

  rm -rf "$dstdir"; mkdir -p "$dstdir"

  # Rekey both source .age files and generated .age files
  for f in "$srcdir"/*.age "$srcdir"/generated/*.age; do
    [ -f "$f" ] || continue
    local name=$(basename "$f" .age)
    local hash=$(age_rekey_hash "$host_ssh_pub_file" "$f")
    echo "  $host: $name"

    local plaintext=""
    if plaintext=$(rage -d -i "$MASTER_ID" -i sops.key "$f" 2>/dev/null); then
      echo "$plaintext" | age -e -r "$host_ssh_pub" -o "$dstdir/${hash}-${name}.age"
    else
      echo "    (can't decrypt with master keys, using source as-is)"
      cp "$f" "$dstdir/${hash}-${name}.age"
    fi
  done
}

generate_hoot_key() {
  local host=$1 host_ssh_pub_file=$2
  local host_ssh_pub=$(<"$host_ssh_pub_file")
  local gendir=".secrets/hosts/$host/generated"

  rm -rf "$gendir"; mkdir -p "$gendir"

  local keyfile=$(mktemp -u)
  ssh-keygen -t ed25519 -N "" -f "$keyfile" -C "$host:boot-host-key" >/dev/null 2>&1
  rage -e -r "$host_ssh_pub" -o "$gendir/boot-host-key.age" < "$keyfile"
  cp "$keyfile.pub" "$gendir/boot-host-key.pub"
  rm -f "$keyfile" "$keyfile.pub"
  echo "  $host: boot-host-key (generated)"
}

echo "=== Boot keys ==="
generate_hoot_key hvn-hyp1 modules/den/hosts/hvn-hyp1/runtime_host_key.pub
generate_hoot_key builder modules/den/hosts/builder/runtime_host_key.pub

echo ""
echo "=== Rekeying ==="
echo "=== hvn-hyp1 ==="
rekey_one hvn-hyp1 modules/den/hosts/hvn-hyp1/runtime_host_key.pub
echo "=== builder ==="
rekey_one builder modules/den/hosts/builder/runtime_host_key.pub

# Shared secrets: encrypt to both hosts
echo "=== shared ==="
rm -rf .secrets/shared/rekeyed; mkdir -p .secrets/shared/rekeyed
for f in .secrets/shared/*.age; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .age)
  echo "  shared: $name"
  rage -d -i "$MASTER_ID" -i sops.key "$f" | \
    rage -e -r "$(cat modules/den/hosts/hvn-hyp1/runtime_host_key.pub)" \
            -r "$(cat modules/den/hosts/builder/runtime_host_key.pub)" \
            -o ".secrets/shared/rekeyed/${name}.age"
done

echo ""
echo "Done. Run: git add -A .secrets/ && git commit -m 'agenix: rekey' && git push"
