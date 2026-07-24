#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
export PHASE0_ROLE=docker-guest
exec bash "$SCRIPT_DIR/_phase0-collector-lib.sh" "$@"
