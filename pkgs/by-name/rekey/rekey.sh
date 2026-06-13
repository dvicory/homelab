#!/usr/bin/env bash
# rekey.sh — Rekey all agenix secrets for all hosts.
#
# Decrypts each secret with the master identity, then re-encrypts to
# the host's SSH public key. Stores rekeyed copies in:
#   .secrets/hosts/<hostname>/rekeyed/<hash>-<name>.age
#
# The hash formula must match agenix-rekey's Nix implementation:
#   sha256(sha256(hostPubkey) + sha256(rekeyFile))[:32]
#
# Usage: ./scripts/rekey.sh
#
# Requires:
#   - AGENIX_MASTER_IDENTITY env var pointing to master age private key
#     (or .secrets/priv/master.age present)
#   - age CLI (github.com/FiloSottile/age, NOT rage)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

MASTER_ID="${AGENIX_MASTER_IDENTITY:-$REPO_ROOT/.secrets/keys/master.age}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$MASTER_ID" ] || die "Master identity not found at $MASTER_ID (set AGENIX_MASTER_IDENTITY or create .secrets/priv/master.age)"

age_rekey_hash() {
  local host_key_file=$1 rekey_file=$2
  local pubkey_hash file_hash
  pubkey_hash=$(cat "$host_key_file" | sha256sum | cut -d' ' -f1)
  file_hash=$(sha256sum "$rekey_file" | cut -d' ' -f1)
  echo -n "${pubkey_hash}${file_hash}" | sha256sum | cut -c1-32
}

rekey_host() {
  local host=$1
  local srcdir=".secrets/hosts/$host"
  local dstdir="$srcdir/rekeyed"
  local ssh_pub="${srcdir}/runtime_host_key.pub"
  local ssh_pub_content

  [ -f "$ssh_pub" ] || { echo "  $host: SKIP (no runtime_host_key.pub)"; return 0; }
  ssh_pub_content=$(<"$ssh_pub")

  rm -rf "$dstdir"
  mkdir -p "$dstdir"

  echo "=== $host ==="

  for f in "$srcdir"/*.age "$srcdir"/generated/*.age; do
    [ -f "$f" ] || continue

    local name hash plaintext
    name=$(basename "$f" .age)
    hash=$(age_rekey_hash "$ssh_pub" "$f")

    echo "  ${hash}-${name}.age"

    if plaintext=$(age -d -i "$MASTER_ID" "$f" 2>/dev/null); then
      echo "$plaintext" | age -e -r "$ssh_pub_content" -o "$dstdir/${hash}-${name}.age"
    else
      echo "    WARNING: cannot decrypt with master identity, copying as-is"
      cp "$f" "$dstdir/${hash}-${name}.age"
    fi
  done
}

rekey_shared() {
  local srcdir=".secrets/shared"
  local dstdir="$srcdir/rekeyed"

  [ -d "$srcdir" ] || return 0

  rm -rf "$dstdir"
  mkdir -p "$dstdir"

  echo "=== shared ==="

  local -a recipient_args=()
  for pubfile in .secrets/hosts/*/runtime_host_key.pub; do
    [ -f "$pubfile" ] || continue
    recipient_args+=("-r" "$(<"$pubfile")")
  done

  [ ${#recipient_args[@]} -gt 0 ] || { echo "  (no host pubkeys found, skipping)"; return 0; }

  for f in "$srcdir"/*.age; do
    [ -f "$f" ] || continue

    local name plaintext
    name=$(basename "$f" .age)

    echo "  ${name}.age"

    if plaintext=$(age -d -i "$MASTER_ID" "$f" 2>/dev/null); then
      echo "$plaintext" | age -e "${recipient_args[@]}" -o "$dstdir/${name}.age"
    else
      echo "    WARNING: cannot decrypt with master identity, copying as-is"
      cp "$f" "$dstdir/${name}.age"
    fi
  done
}

echo "=== Rekeying all secrets ==="
echo "Master identity: $MASTER_ID"
echo ""

for hostdir in .secrets/hosts/*/; do
  host=$(basename "$hostdir")
  rekey_host "$host"
  echo ""
done

rekey_shared

echo ""
echo "Done. Run: git add -A .secrets/ && git commit -m 'secrets: rekey'"
