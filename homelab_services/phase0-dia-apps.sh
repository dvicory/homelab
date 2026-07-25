#!/usr/bin/env bash
# Credential-safe, read-only application recovery preflight for dia.
# shellcheck disable=SC2016 # Nested bash -c programs intentionally use single quotes.
set -euo pipefail
umask 077
PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

OUTPUT_PARENT=$PWD
MAKE_ARCHIVE=1

usage() {
  cat <<'EOF'
Usage: phase0-dia-apps.sh [--output DIR] [--no-archive]

Collects immutable container/image identities, mounts, environment variable
names, state-root sizes, database filenames, and safe version probes. It never
prints environment values or configuration contents and never starts, stops,
restarts, freezes, or backs up a container. Run on dia as root (preferred) or
as a user with Docker access.
The report remains sensitive because paths and database names are included.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

while (($#)); do
  case "$1" in
    --output) (($# >= 2)) || die "--output requires a value"; OUTPUT_PARENT=$2; shift 2 ;;
    --no-archive) MAKE_ARCHIVE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ $(uname -s) == Linux ]] || die "this collector supports Linux only"
have docker || die "docker is required"
have python3 || die "python3 is required"
docker info >/dev/null 2>&1 || die "Docker is not accessible; run as root or grant Docker socket access"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
HOST=$(hostname -s 2>/dev/null || hostname)
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT=$(readlink -f "$OUTPUT_PARENT")
OUT="$OUTPUT_PARENT/phase0-dia-apps-${STAMP}"
mkdir "$OUT"
LOG="$OUT/00-command-log.tsv"
WARNINGS="$OUT/00-warnings.txt"
printf 'section\texit_code\n' > "$LOG"
: > "$WARNINGS"

capture() {
  local section=$1
  shift
  local rc=0
  {
    printf '# %s\n# started_utc: %s\n\n' "$section" "$(date -u +%FT%TZ)"
    "$@" || rc=$?
    printf '\n# exit_code: %s\n' "$rc"
  } > "$OUT/${section}.txt" 2>&1
  printf '%s\t%s\n' "$section" "$rc" >> "$LOG"
  ((rc == 0)) || printf '%s: command exited %s\n' "$section" "$rc" >> "$WARNINGS"
}

capture_shell() {
  local section=$1 script=$2
  shift 2
  capture "$section" bash -c "$script" bash "$@"
}

cat > "$OUT/00-metadata.txt" <<EOF
label=dia-app-recovery
hostname=$HOST
started_utc=$(date -u +%FT%TZ)
collector_version=1
collector_uid=$(id -u)
read_only=1
container_lifecycle_changes=0
configuration_contents_collected=0
environment_values_collected=0
EOF

capture "10-system" bash -c 'hostnamectl; printf "\n--- filesystem ---\n"; df -B1 -T / /home /mnt/medialibrary 2>&1; printf "\n--- mounts ---\n"; findmnt -T /mnt/medialibrary; findmnt -T /mnt/ceres-complete-downloads 2>&1 || true'
capture "20-docker-version" docker version
capture "21-docker-space" docker system df -v
capture_shell "22-container-recovery-inventory" '
  ids=$(docker ps -aq)
  [[ -n "$ids" ]] || { printf "[]\n"; exit 0; }
  docker inspect $ids | python3 -c '\''
import json, sys
containers = json.load(sys.stdin)
allowed_labels = {
    "com.docker.compose.project", "com.docker.compose.service",
    "com.docker.compose.project.config_files", "com.docker.compose.project.working_dir",
    "org.opencontainers.image.created", "org.opencontainers.image.revision",
    "org.opencontainers.image.source", "org.opencontainers.image.version",
    "build_version", "build_date",
}
result = []
for item in containers:
    config = item.get("Config") or {}
    host = item.get("HostConfig") or {}
    labels = config.get("Labels") or {}
    result.append({
        "id": item.get("Id"),
        "name": (item.get("Name") or "").lstrip("/"),
        "configured_image": config.get("Image"),
        "immutable_image_id": item.get("Image"),
        "created": item.get("Created"),
        "state": (item.get("State") or {}).get("Status"),
        "restart_policy": (host.get("RestartPolicy") or {}).get("Name"),
        "environment_names": sorted(x.split("=", 1)[0] for x in (config.get("Env") or [])),
        "labels": {k: labels[k] for k in sorted(labels) if k in allowed_labels},
        "mounts": [{
            "type": m.get("Type"), "source": m.get("Source"),
            "destination": m.get("Destination"), "mode": m.get("Mode"),
            "read_write": m.get("RW"), "name": m.get("Name"),
        } for m in item.get("Mounts") or []],
        "networks": sorted(((item.get("NetworkSettings") or {}).get("Networks") or {}).keys()),
    })
json.dump(sorted(result, key=lambda x: x["name"]), sys.stdout, indent=2)
print()
'\''
'
capture_shell "23-image-recovery-inventory" '
  ids=$(docker ps -aq)
  [[ -n "$ids" ]] || { printf "[]\n"; exit 0; }
  image_ids=$(docker inspect --format "{{.Image}}" $ids | sort -u)
  docker image inspect $image_ids | python3 -c '\''
import json, sys
images = json.load(sys.stdin)
allowed = {"build_version", "build_date", "org.opencontainers.image.created", "org.opencontainers.image.revision", "org.opencontainers.image.source", "org.opencontainers.image.version"}
result = []
for item in images:
    labels = ((item.get("Config") or {}).get("Labels") or {})
    result.append({
        "id": item.get("Id"), "repo_tags": item.get("RepoTags") or [],
        "repo_digests": item.get("RepoDigests") or [], "created": item.get("Created"),
        "architecture": item.get("Architecture"), "os": item.get("Os"),
        "size": item.get("Size"),
        "labels": {k: labels[k] for k in sorted(labels) if k in allowed},
    })
json.dump(sorted(result, key=lambda x: x["id"] or ""), sys.stdout, indent=2)
print()
'\''
'
capture_shell "24-compose-file-metadata" '
  docker inspect $(docker ps -aq) --format "{{index .Config.Labels \"com.docker.compose.project.config_files\"}}" 2>/dev/null |
    tr "," "\n" | sed "/^$/d" | sort -u | while IFS= read -r path; do
      if [[ -f "$path" ]]; then stat --printf="%n\t%s\t%y\t%U:%G\t%a\n" "$path"; sha256sum "$path"; else printf "MISSING\t%s\n" "$path"; fi
    done
'
capture_shell "30-state-root-capacity" '
  roots=(
    /home/medialibrary/.config/appdata
    /home/medialibrary/.stacks
    /var/lib/docker/volumes
    /mnt/medialibrary/nextcloud
    /mnt/medialibrary/photos
    /mnt/medialibrary/sync
  )
  for root in "${roots[@]}"; do
    if [[ -e "$root" ]]; then
      stat --printf="STAT\t%n\t%F\t%s\t%y\t%U:%G\t%a\n" "$root"
      du -sx --bytes --one-file-system "$root" 2>&1 | sed "s/^/DU\t/"
    else
      printf "MISSING\t%s\n" "$root"
    fi
  done
'
capture_shell "31-database-file-metadata" '
  python3 - <<'\''PY'\''
import os
from pathlib import Path
roots = [Path("/home/medialibrary/.config/appdata"), Path("/home/medialibrary/.stacks")]
suffixes = {".db", ".sqlite", ".sqlite3", ".mv.db", ".sql", ".dump", ".backup", ".zip"}
names = {"config.xml", "sabnzbd.ini", "nzbhydra.yml", "version.php", "PG_VERSION"}
for root in roots:
    if not root.is_dir():
        continue
    for current, dirs, files in os.walk(root, followlinks=False):
        relative = Path(current).relative_to(root)
        if len(relative.parts) >= 7:
            dirs.clear()
            continue
        for filename in files:
            path = Path(current, filename)
            lower = filename.casefold()
            if lower not in {x.casefold() for x in names} and not any(lower.endswith(x) for x in suffixes):
                continue
            try:
                stat = path.stat(follow_symlinks=False)
                print(f"{path}\t{stat.st_size}\t{stat.st_mtime_ns}\t{stat.st_uid}:{stat.st_gid}\t{stat.st_mode & 0o777:o}")
            except OSError as error:
                print(f"ERROR\t{path}\t{error}")
PY
'
capture_shell "32-running-image-version-files" '
  for name in $(docker ps --format "{{.Names}}" | sort); do
    printf "===== %s =====\n" "$name"
    docker exec "$name" sh -c '\''
      for f in /build_version /app/*/package_info; do
        [ -f "$f" ] || continue
        printf "%s: " "$f"
        head -c 2048 "$f" | tr "\000" "?"
        printf "\n"
      done
    '\'' 2>&1 || true
  done
'
capture_shell "33-nextcloud-status" '
  [[ $(docker inspect -f "{{.State.Running}}" nextcloud 2>/dev/null || true) == true ]] || { echo "nextcloud is not running"; exit 0; }
  for occ in /app/www/public/occ /config/www/nextcloud/occ; do
    if docker exec nextcloud test -f "$occ"; then
      docker exec -u abc nextcloud php "$occ" status --output=json
      exit $?
    fi
  done
  echo "occ path not found"
  exit 1
'
capture_shell "34-postgres-status" '
  [[ $(docker inspect -f "{{.State.Running}}" postgres 2>/dev/null || true) == true ]] || { echo "postgres is not running"; exit 0; }
  docker exec postgres sh -c '\''psql -Atqc "select version(); select datname from pg_database where datistemplate = false order by datname" -U "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-postgres}"'\''
'

cat >> "$WARNINGS" <<'EOF'
No native backup was created. This preflight intentionally does not call backup APIs, enter maintenance mode, dump a database, or copy application state.
A Proxmox VM backup covers the VM disk but not the host-provided /tank1/ds1/mccoy/media tree mounted inside dia.
Image IDs/digests identify what ran but do not guarantee that registries will retain pullable layers; image export is a later, write-producing step.
EOF

if ((MAKE_ARCHIVE)); then
  ARCHIVE="$OUT.tar.gz"
  tar -C "$OUTPUT_PARENT" -czf "$ARCHIVE" "$(basename "$OUT")"
  sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
  printf 'Application preflight complete:\n%s\n%s\n%s\n' "$OUT" "$ARCHIVE" "$ARCHIVE.sha256"
else
  printf 'Application preflight complete:\n%s\n' "$OUT"
fi
