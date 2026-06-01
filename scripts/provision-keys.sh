#!/usr/bin/env bash
# provision-keys.sh — Full new-host secrets provisioning pipeline.
#
# 1. Generates secrets (boot keys) for the host if missing
# 2. Rekeys all secrets for all hosts
# 3. Stages and commits changes
#
# Usage: ./scripts/provision-keys.sh <hostname>
#
# Prerequisites for new hosts:
#   1. First boot the host (sshd auto-generates SSH host keys)
#   2. Copy the pubkey: scp root@<host>:/persist/etc/ssh/ssh_host_ed25519_key.pub \
#                         .secrets/hosts/<hostname>/runtime_host_key.pub
#   3. Run: ./scripts/provision-keys.sh <hostname>

set -euo pipefail

HOST="${1:?Usage: $0 <hostname>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Phase 1: Generate secrets ---
echo "=== Phase 1: Generate ==="
bash "$SCRIPT_DIR/generate-secrets.sh" "$HOST"

# --- Phase 2: Rekey ---
echo ""
echo "=== Phase 2: Rekey ==="
bash "$SCRIPT_DIR/rekey.sh"

# --- Phase 3: Commit ---
echo ""
echo "=== Phase 3: Commit ==="
git add -A .secrets/

if git diff --cached --quiet; then
  echo "No changes to commit."
else
  git commit -m "secrets: provision keys for $HOST"
  echo ""
  echo "Committed. If ready to deploy, run: git push"
fi

echo ""
echo "=== Provisioning complete ==="
echo "Next steps:"
echo "  1. nh os switch $HOST --update"
echo "  2. Reboot to test initrd remote unlock"
