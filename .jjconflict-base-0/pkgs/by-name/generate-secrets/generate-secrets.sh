#!/usr/bin/env bash
# generate-secrets.sh — Generate agenix secrets (boot keys, etc.) for a host.
#
# Idempotent: skips generation if the output file already exists.
# Encrypts generated private keys to both the host's SSH public key
# and the master public key (so master can always decrypt for recovery).
# Public keys are committed to git alongside the encrypted private key.
#
# Usage: ./scripts/generate-secrets.sh <hostname>
#        ./scripts/generate-secrets.sh hvn-hyp1
#
# Requires:
#   - age CLI (from nixpkgs or homebrew)
#   - ssh-keygen
#
# Secrets directory: .secrets/hosts/<hostname>/
#   generated/boot-host-key.age   — SSH keypair for initrd remote unlock (encrypted)
#   generated/boot-host-key.pub   — public key (plain, committed)

set -euo pipefail

HOST="${1:?Usage: $0 <hostname>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

SECRETS_DIR=".secrets/hosts/$HOST"
GEN_DIR="$SECRETS_DIR/generated"
SSH_PUB="$(cat "$SECRETS_DIR/runtime_host_key.pub")"
MASTER_PUB="$(cat ".secrets/pub/master.pub")"

mkdir -p "$GEN_DIR"

generate_boot_key() {
  local name="boot-host-key"
  local age_file="$GEN_DIR/${name}.age"
  local pub_file="$GEN_DIR/${name}.pub"

  if [[ -f "$age_file" ]] && [[ -f "$pub_file" ]]; then
    echo "  $HOST: $name (exists, skipping)"
    return 0
  fi

  echo "  $HOST: $name (generating)"

  # Keep the unencrypted private key in a private directory for the shortest
  # possible time. `mktemp -u` would only reserve a name, allowing another
  # user to race ssh-keygen and redirect the key material.
  (
    umask 077
    key_dir=$(mktemp -d "${TMPDIR:-/tmp}/ssh-key-XXXXXX")
    trap 'rm -rf "$key_dir"' EXIT
    keyfile="$key_dir/$name"

    ssh-keygen -q -t ed25519 -N "" -C "${HOST}:${name}" -f "$keyfile" >/dev/null 2>&1
    age -e -r "$SSH_PUB" -r "$MASTER_PUB" -o "$age_file" < "$keyfile"
    cp "$keyfile.pub" "$pub_file"
    chmod 0644 "$pub_file"
  )
}

echo "=== Generating secrets for $HOST ==="
generate_boot_key
echo ""
echo "Done. Run ./scripts/rekey.sh to rekey all secrets."
echo "Then: git add -A .secrets/ && git commit -m 'secrets: generate keys for $HOST'"
