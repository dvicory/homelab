# Temporary B3 observation; invoked with bash only for the selected dispatch.
# Read metadata/totals only. Never change admission or determine test success.
set -u
printf '\nSTORAGE_SNAPSHOT phase=%s utc=%s\n' "$1" "$(date -u +%FT%TZ)"
observe() {
  "$@" 2>/dev/null || printf 'STORAGE_SNAPSHOT unavailable status=%s\n' "$?"
}
for requested in / /mnt /nix /nix/build "$RUNNER_TEMP"; do
  existing=$requested
  while [ ! -e "$existing" ]; do
    existing=$(dirname "$existing")
  done
  printf 'STORAGE_PATH requested=%s existing=%s\n' "$requested" "$existing"
  observe timeout 5s df -B1 --output=source,fstype,size,used,avail,pcent,target -- "$existing"
  observe timeout 5s findmnt -n -T "$existing" -o TARGET,SOURCE,FSTYPE
done
if [ -d /nix ] && [ "$(findmnt -n -T /nix -o FSTYPE)" = btrfs ]; then
  printf 'STORAGE_BTRFS usage_bytes\n'
  observe sudo timeout 10s btrfs filesystem usage -b /nix
  printf 'STORAGE_BTRFS device_stats\n'
  observe sudo timeout 10s btrfs device stats /nix
fi
printf 'STORAGE_ALLOCATED controlled_path_totals_bytes\n'
# No recursive names or file contents; suppress errors containing child paths.
observe sudo timeout 20s du -x -B1 -s -- /nix/store /nix/build /nix/var /mnt/nix.img
printf 'STORAGE_SNAPSHOT end=%s\n' "$1"
