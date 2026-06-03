#!/usr/bin/env bash
# install.sh — Provision secrets for nixos-anywhere remote install.
#
# Decrypts the boot host key and stages it as an extra-file for
# nixos-anywhere so the initrd SSH host key is in place at first boot.
#
# Usage: ./scripts/install.sh <hostname> <target-ip>
#        ./scripts/install.sh hvn-hyp1 10.10.10.5
#
# Prerequisites:
#   1. Master identity available (AGENIX_MASTER_IDENTITY or .secrets/priv/master.age)
#   2. nixos-anywhere in PATH

set -euo pipefail

HOST="${1:?Usage: $0 <hostname> <target-ip>}"
IP="${2:?Usage: $0 <hostname> <target-ip>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

MASTER_ID="${AGENIX_MASTER_IDENTITY:-$REPO_ROOT/.secrets/priv/master.age}"
EXTRA_FILES="$(mktemp -d /tmp/nixos-anywhere-extra-XXXXXX)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$MASTER_ID" ] || die "Master identity not found (set AGENIX_MASTER_IDENTITY or create .secrets/priv/master.age)"

BOOT_KEY_AGE=".secrets/hosts/${HOST}/generated/boot-host-key.age"
BOOT_KEY_DEST="$EXTRA_FILES/boot/boot_host_key"

echo "=== Pre-install: decrypting secrets for $HOST ==="

if [ -f "$BOOT_KEY_AGE" ]; then
  mkdir -p "$(dirname "$BOOT_KEY_DEST")"
  age -d -i "$MASTER_ID" -o "$BOOT_KEY_DEST" "$BOOT_KEY_AGE" 2>/dev/null \
    || die "Failed to decrypt boot host key for $HOST"
  chmod 600 "$BOOT_KEY_DEST"
  echo "  boot_host_key → $BOOT_KEY_DEST"
else
  echo "  WARNING: no boot-host-key.age found — initrd SSH will fail on first boot"
fi

echo ""
echo "=== Running nixos-anywhere ==="
# nixos-anywhere --flake ".#$HOST" --target-host "root@$IP" --extra-files "$EXTRA_FILES"
echo ""
echo "Dry run. To actually install, uncomment the line above."
echo "After install, reboot and verify initrd SSH:"
echo "  ssh -p 2222 root@$IP -i ~/.ssh/<your-key>"
