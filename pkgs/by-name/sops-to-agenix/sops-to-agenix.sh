#!/usr/bin/env bash
# sops-to-agenix.sh — Migrate sops secrets to agenix format.
#
# Reads decrypted sops values and creates age-encrypted files in the
# agenix directory structure. Uses the master identity to encrypt.
#
# Usage: sops-to-agenix
#
# Prerequisites:
#   - Master identity accessible (passphrase-protected keys/master.age)
#   - sops secrets accessible (via sops.key or SOPS_AGE_KEY)
#   - age CLI available
#
# What it does:
#   1. Decrypts sops secrets for each host
#   2. Encrypts each value as a separate .age file in .secrets/hosts/<host>/
#   3. Encrypts shared secrets in .secrets/shared/
#   4. Runs rekey to create host-specific rekeyed copies
#
# After running: verify with `age -d -i <master-key> <file>`

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

MASTER_PUB=".secrets/pub/master.pub"
SOPS_KEY="${SOPS_AGE_KEY:-$REPO_ROOT/sops.key}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$MASTER_PUB" ] || die "Master public key not found at $MASTER_PUB"
[ -f "$SOPS_KEY" ] || die "SOPS key not found at $SOPS_KEY"

# Decrypt sops file once and cache the output
sops_decrypt() {
  local file="$1"
  SOPS_AGE_KEY_FILE="$SOPS_KEY" nix run .#sops -- decrypt "$file" 2>/dev/null
}

# Extract a YAML path from already-decrypted content
yaml_get() {
  local content="$1"
  local path="$2"
  local val
  val=$(echo "$content" | yq -r ".$path" 2>/dev/null)
  if [ "$val" = "null" ] || [ -z "$val" ]; then
    return 1
  fi
  echo "$val"
}

# Encrypt a value to the master public key
encrypt_value() {
  local output_file="$1"
  local value="$2"
  echo -n "$value" | age -e -r "$(cat "$MASTER_PUB")" -o "$output_file"
}

echo "=== SOPS → Agenix Migration ==="
echo ""

# --- hvn-hyp1 ---
echo "=== hvn-hyp1 ==="
HOST="hvn-hyp1"
SOPS_FILE="modules/den/hosts/$HOST/secrets.yaml"
HOST_DIR=".secrets/hosts/$HOST"

if [ -f "$SOPS_FILE" ]; then
  CONTENT=$(sops_decrypt "$SOPS_FILE")

  # gocryptfs passphrases
  for vol in media1 media2 media3; do
    val=$(yaml_get "$CONTENT" "$HOST.gocryptfs.$vol" || true)
    if [ -n "$val" ]; then
      encrypt_value "$HOST_DIR/gocryptfs-${vol}.age" "$val"
      echo "  gocryptfs-${vol}.age ✓"
    fi
  done

  # crowdsec bouncer API key
  val=$(yaml_get "$CONTENT" "$HOST.crowdsec.bouncerApiKey" || true)
  if [ -n "$val" ]; then
    encrypt_value "$HOST_DIR/crowdsec-bouncerApiKey.age" "$val"
    echo "  crowdsec-bouncerApiKey.age ✓"
  fi

  # hashed password → user-level (shared across hosts)
  val=$(yaml_get "$CONTENT" "$HOST.users.daniel.hashedPassword" || true)
  if [ -n "$val" ]; then
    USER_DIR=".secrets/users/daniel"
    mkdir -p "$USER_DIR"
    encrypt_value "$USER_DIR/hashed-password.age" "$val"
    echo "  users/daniel/hashed-password.age ✓"
  fi

  # root passphrase (disk encryption)
  val=$(yaml_get "$CONTENT" "$HOST.disks.rootPassphrase" || true)
  if [ -n "$val" ]; then
    encrypt_value "$HOST_DIR/rootPassphrase.age" "$val"
    echo "  rootPassphrase.age ✓"
  fi
else
  echo "  SKIP (no $SOPS_FILE)"
fi

echo ""

# --- builder ---
echo "=== builder ==="
HOST="builder"
SOPS_FILE="modules/den/hosts/$HOST/secrets.yaml"
HOST_DIR=".secrets/hosts/$HOST"

if [ -f "$SOPS_FILE" ]; then
  CONTENT=$(sops_decrypt "$SOPS_FILE")

  # crowdsec bouncer API key
  val=$(yaml_get "$CONTENT" "$HOST.crowdsec.bouncerApiKey" || true)
  if [ -n "$val" ]; then
    encrypt_value "$HOST_DIR/crowdsec-bouncerApiKey.age" "$val"
    echo "  crowdsec-bouncerApiKey.age ✓"
  fi

  # hashed password → user-level (shared across hosts)
  val=$(yaml_get "$CONTENT" "$HOST.users.daniel.hashedPassword" || true)
  if [ -n "$val" ]; then
    USER_DIR=".secrets/users/daniel"
    mkdir -p "$USER_DIR"
    encrypt_value "$USER_DIR/hashed-password.age" "$val"
    echo "  users/daniel/hashed-password.age ✓"
  fi

  # root passphrase
  val=$(yaml_get "$CONTENT" "$HOST.disks.rootPassphrase" || true)
  if [ -n "$val" ]; then
    encrypt_value "$HOST_DIR/rootPassphrase.age" "$val"
    echo "  rootPassphrase.age ✓"
  fi

  # data passphrase
  val=$(yaml_get "$CONTENT" "$HOST.disks.dataPassphrase" || true)
  if [ -n "$val" ]; then
    encrypt_value "$HOST_DIR/dataPassphrase.age" "$val"
    echo "  dataPassphrase.age ✓"
  fi
else
  echo "  SKIP (no $SOPS_FILE)"
fi

echo ""

# --- shared ---
echo "=== shared ==="
SOPS_FILE="shared/secrets.yaml"
SHARED_DIR=".secrets/shared"

if [ -f "$SOPS_FILE" ]; then
  CONTENT=$(sops_decrypt "$SOPS_FILE")

  val=$(yaml_get "$CONTENT" "crowdsec.enrollment_key" || true)
  if [ -n "$val" ]; then
    encrypt_value "$SHARED_DIR/enrollmentKey.age" "$val"
    echo "  enrollmentKey.age ✓"
  fi
else
  echo "  SKIP (no $SOPS_FILE)"
fi

echo ""
echo "=== Migration complete ==="
echo ""
echo "Verify with:"
echo "  age -d -i <master-key-file> .secrets/hosts/hvn-hyp1/gocryptfs-media1.age"
echo ""
echo "Then rekey for all hosts:"
echo "  AGENIX_MASTER_IDENTITY=<master-key-file> rekey"
echo ""
echo "Then commit:"
echo "  git add -A .secrets/ && git commit -m 'secrets: migrate sops to agenix'"
