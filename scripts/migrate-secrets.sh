#!/usr/bin/env bash
# migrate-secrets.sh — Re-encrypts all sops secrets as agenix .age files.
# Reads from .sops.yaml mappings, decrypts with sops, encrypts with rage.
# Non-destructive: does not touch sops files.
set -euo pipefail

FLAKE_ROOT="$(git rev-parse --show-toplevel)"
cd "$FLAKE_ROOT"

export SOPS_AGE_KEY_FILE="$FLAKE_ROOT/sops.key"

MASTER_KEY="$FLAKE_ROOT/.secrets/pub/master.key"
HVN_KEY="$FLAKE_ROOT/.secrets/hosts/hvn-hyp1/ssh_host_ed25519_key.pub"
BUILDER_KEY="$FLAKE_ROOT/.secrets/hosts/builder/ssh_host_ed25519_key.pub"

HOST_KEY_HVN="$(<"$HVN_KEY")"
HOST_KEY_BUILDER="$(<"$BUILDER_KEY")"
MASTER_PUB="$(<"$MASTER_KEY")"

age_encrypt() {
  local host_key="$1" output="$2" recipients=() file
  shift 2
  mkdir -p "$(dirname "$output")"
  for file in "$@"; do
    if [[ "$file" == all ]]; then
      recipients+=(-r "$HOST_KEY_HVN" -r "$HOST_KEY_BUILDER")
    elif [[ "$file" == "hvn-hyp1" ]]; then
      recipients+=(-r "$HOST_KEY_HVN")
    elif [[ "$file" == "builder" ]]; then
      recipients+=(-r "$HOST_KEY_BUILDER")
    fi
  done
  recipients+=(-r "$MASTER_PUB")
  echo "  -> $output"
  rage -e "${recipients[@]}" -o "$output" < /dev/stdin
}

# ─── hvn-hyp1 ──────────────────────────────────────────────────────
echo "=== hvn-hyp1 ==="

sops -d --extract '["hvn-hyp1"]["users"]["daniel"]["hashedPassword"]' \
  modules/den/hosts/hvn-hyp1/secrets.yaml \
  | age_encrypt "$HOST_KEY_HVN" .secrets/hosts/hvn-hyp1/hashedPassword-daniel.age hvn-hyp1

sops -d --extract '["hvn-hyp1"]["disks"]["rootPassphrase"]' \
  modules/den/hosts/hvn-hyp1/secrets.yaml \
  | age_encrypt "$HOST_KEY_HVN" .secrets/hosts/hvn-hyp1/rootPassphrase.age hvn-hyp1

sops -d --extract '["hvn-hyp1"]["gocryptfs"]["media1"]' \
  modules/den/hosts/hvn-hyp1/secrets.yaml \
  | age_encrypt "$HOST_KEY_HVN" .secrets/hosts/hvn-hyp1/gocryptfs-media1.age hvn-hyp1

sops -d --extract '["hvn-hyp1"]["gocryptfs"]["media2"]' \
  modules/den/hosts/hvn-hyp1/secrets.yaml \
  | age_encrypt "$HOST_KEY_HVN" .secrets/hosts/hvn-hyp1/gocryptfs-media2.age hvn-hyp1

sops -d --extract '["hvn-hyp1"]["gocryptfs"]["media3"]' \
  modules/den/hosts/hvn-hyp1/secrets.yaml \
  | age_encrypt "$HOST_KEY_HVN" .secrets/hosts/hvn-hyp1/gocryptfs-media3.age hvn-hyp1

sops -d --extract '["hvn-hyp1"]["crowdsec"]["bouncerApiKey"]' \
  modules/den/hosts/hvn-hyp1/secrets.yaml \
  | age_encrypt "$HOST_KEY_HVN" .secrets/hosts/hvn-hyp1/bouncerApiKey.age hvn-hyp1

# ─── builder ───────────────────────────────────────────────────────
echo "=== builder ==="

sops -d --extract '["builder"]["users"]["daniel"]["hashedPassword"]' \
  modules/den/hosts/builder/secrets.yaml \
  | age_encrypt "$HOST_KEY_BUILDER" .secrets/hosts/builder/hashedPassword-daniel.age builder

sops -d --extract '["builder"]["disks"]["rootPassphrase"]' \
  modules/den/hosts/builder/secrets.yaml \
  | age_encrypt "$HOST_KEY_BUILDER" .secrets/hosts/builder/rootPassphrase.age builder

sops -d --extract '["builder"]["disks"]["dataPassphrase"]' \
  modules/den/hosts/builder/secrets.yaml \
  | age_encrypt "$HOST_KEY_BUILDER" .secrets/hosts/builder/dataPassphrase.age builder

sops -d --extract '["builder"]["crowdsec"]["bouncerApiKey"]' \
  modules/den/hosts/builder/secrets.yaml \
  | age_encrypt "$HOST_KEY_BUILDER" .secrets/hosts/builder/bouncerApiKey.age builder

# ─── shared ────────────────────────────────────────────────────────
echo "=== shared ==="

sops -d --extract '["crowdsec"]["enrollment_key"]' \
  shared/secrets.yaml \
  | age_encrypt "$HOST_KEY_HVN" .secrets/shared/enrollmentKey.age all

echo ""
echo "Done. .age files created under .secrets/"
echo "Run: git add .secrets/ && nix run .#write-flake --impure"
