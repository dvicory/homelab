#!/usr/bin/env bash
set -euo pipefail

INHERITED_RCLONE=$(command -v rclone 2>/dev/null || true)
umask 077
PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

usage() {
  cat <<'EOF'
Usage: phase0-catalog.sh --label NAME --root PATH [--output DIR]

Creates one compressed, recursive rclone JSON catalog for one explicit root.
The catalog includes files, directories, and symbolic links, but never follows
symbolic links, hashes file contents, or enters ZFS .zfs snapshot namespaces.

Options:
  --label NAME  Stable catalog name, e.g. proxmox-kirk or hvn-bulk-2.
  --root PATH   Existing absolute content root to catalog.
  --output DIR  Output directory (default: current directory).
  -h, --help    Show this help.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

LABEL=
ROOT=
OUTPUT=$PWD
while (($#)); do
  case "$1" in
    --label)
      (($# >= 2)) || die "--label requires a value"
      LABEL=$2
      shift 2
      ;;
    --root)
      (($# >= 2)) || die "--root requires a value"
      ROOT=$2
      shift 2
      ;;
    --output)
      (($# >= 2)) || die "--output requires a value"
      OUTPUT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--label must contain only letters, digits, dot, underscore, or hyphen"
[[ "$ROOT" == /* ]] || die "--root must be an absolute path"
[[ "$ROOT" != / ]] || die "refusing to catalog the filesystem root"
[[ -d "$ROOT" ]] || die "root is not a directory: $ROOT"
case "$INHERITED_RCLONE" in
  /nix/store/*/bin/rclone) RCLONE=$INHERITED_RCLONE ;;
  *) RCLONE=$(command -v rclone 2>/dev/null || true) ;;
esac
[[ -n "$RCLONE" ]] || die "rclone is required"
command -v gzip >/dev/null 2>&1 || die "gzip is required"
if command -v sha256sum >/dev/null 2>&1; then
  hasher=(sha256sum --)
elif command -v shasum >/dev/null 2>&1; then
  hasher=(shasum -a 256 --)
else
  die "sha256sum or shasum is required"
fi

ROOT=$(cd -- "$ROOT" && pwd -P)
mkdir -p -- "$OUTPUT"
OUTPUT=$(cd -- "$OUTPUT" && pwd -P)
BASE="$OUTPUT/$LABEL"
CATALOG="$BASE.lsjson.gz"
PARTIAL="$CATALOG.partial"
LOG="$BASE.rclone.log"
METADATA="$BASE.metadata.txt"
CHECKSUMS="$BASE.sha256"

for path in "$CATALOG" "$PARTIAL" "$LOG" "$METADATA" "$CHECKSUMS"; do
  [[ ! -e "$path" ]] || die "refusing to overwrite: $path"
done

{
  printf 'catalog_schema=1\n'
  printf 'label=%s\n' "$LABEL"
  printf 'host=%s\n' "$(hostname -s 2>/dev/null || hostname)"
  printf 'root=%s\n' "$ROOT"
  printf 'started_utc=%s\n' "$(date -u +%FT%TZ)"
  printf 'rclone=%s\n' "$RCLONE"
  "$RCLONE" version | sed 's/^/rclone_version: /'
  printf '\n-- root stat --\n'
  stat -- "$ROOT"
  printf '\n-- containing mount --\n'
  findmnt -T "$ROOT" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true
  printf '\n-- capacity --\n'
  df -B1 -- "$ROOT" 2>&1 || true
} > "$METADATA"
: > "$LOG"

runner=(nice -n 19)
if command -v ionice >/dev/null 2>&1; then
  runner=(ionice -c 3 nice -n 19)
fi

printf 'Cataloging %s as %s. Metadata only; symlinks are recorded but never followed.\n' "$ROOT" "$LABEL"
if ! "${runner[@]}" "$RCLONE" lsjson \
  --config /dev/null \
  --recursive \
  --links \
  --no-mimetype \
  --exclude '/.zfs' \
  --exclude '/.zfs/**' \
  --exclude '**/.zfs' \
  --exclude '**/.zfs/**' \
  --log-level NOTICE \
  --log-file "$LOG" \
  "$ROOT" | gzip -1 > "$PARTIAL"; then
  echo "Catalog failed; preserving partial output and log:" >&2
  echo "  $PARTIAL" >&2
  echo "  $LOG" >&2
  exit 1
fi

mv -- "$PARTIAL" "$CATALOG"
printf 'completed_utc=%s\n' "$(date -u +%FT%TZ)" >> "$METADATA"
(
  cd -- "$OUTPUT"
  "${hasher[@]}" "$(basename -- "$CATALOG")" "$(basename -- "$LOG")" "$(basename -- "$METADATA")"
) > "$CHECKSUMS"
printf 'Catalog complete:\n  %s\n  %s\n  %s\n  %s\n' "$CATALOG" "$LOG" "$METADATA" "$CHECKSUMS"
