#!/usr/bin/env bash
# prepare-luks-storage — inspect an evaluated target and, after separate
# approvals, format it or seed it from a quiesced direct source.
#
# Preflight never opens or mutates a block device. It records the target
# identity and, when a source is given, direct-source provenance, source byte
# counts, and target capacity in an evidence file. Format and copy re-check
# that evidence before writing. A preflight without --source records
# SOURCE=none; that evidence can authorize format but never copy.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  prepare-luks-storage describe --descriptor /etc/homelab/storage/NAME
  prepare-luks-storage preflight --descriptor /etc/homelab/storage/NAME \
    [--source /mnt/storage-clear/SOURCE] --evidence /run/NAME-preflight
  prepare-luks-storage format --descriptor /etc/homelab/storage/NAME \
    --evidence /run/NAME-preflight \
    --confirm-target WHOLE_BY_ID|SERIAL|WWN|SIZE_BYTES --approve-format
  prepare-luks-storage copy --descriptor /etc/homelab/storage/NAME \
    --evidence /run/NAME-preflight \
    --quiescence-evidence /run/NAME-quiescence \
    --receipt /run/NAME-copy-receipt --approve-copy

Without --source, preflight checks only target identity and emptiness and
records SOURCE=none. Such evidence allows format; copy refuses it.
copy stages the source under MOUNTPOINT/.seed.

The host-specific wrapper supplies --descriptor from the evaluated Den
disk.luks-storage declaration. Do not pass a second descriptor.
EOF
  exit 64
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

trim() {
  local value=${1-}
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_uint() {
  [[ ${1-} =~ ^[0-9]+$ ]]
}

DISK_NAME=
DESCRIPTOR=
DECLARED_DEVICE=
MAPPER=
KEY_FILE=
MOUNTPOINT=
FS_TYPE=
SOURCE_PATH=
EVIDENCE_PATH=
QUIESCENCE_EVIDENCE=
RECEIPT_PATH=
CONFIRM_TARGET=
APPROVE_FORMAT=false
APPROVE_COPY=false

WHOLE_DEVICE=
WHOLE_BY_ID=
EXPECTED_WHOLE_BY_ID=
DEVICE_SERIAL=
DEVICE_WWN=
DEVICE_SIZE_BYTES=
DEVICE_TYPE=
PARTITION=

SOURCE_REALPATH=
SOURCE_MOUNT_TARGET=
SOURCE_DEVICE=
SOURCE_FSTYPE=
SOURCE_UUID=
SOURCE_ST_DEV=
SOURCE_APPARENT_BYTES=
SOURCE_ALLOCATED_BYTES=
SOURCE_TOKEN=
TARGET_CAPACITY_BYTES=
TARGET_REQUIRED_BYTES=
TARGET_CLEAR=false
SOURCE_READY=false
CAPACITY_READY=false
GATE_FAILURES=0
GATE_MANUALS=0
MIN_HEADROOM_BYTES=10737418240

pass_gate() { printf 'PASS  %s\n' "$*"; }
fail_gate() { printf 'FAIL  %s\n' "$*"; GATE_FAILURES=$((GATE_FAILURES + 1)); }
manual_gate() { printf 'MANUAL %s\n' "$*"; GATE_MANUALS=$((GATE_MANUALS + 1)); }

parse_args() {
  local command=${1-}
  shift || true
  while (($#)); do
    case $1 in
      --descriptor)
        (($# >= 2)) || die "$command: --descriptor needs a value"
        [[ -z $DESCRIPTOR ]] || die "$command: --descriptor may be supplied only once"
        DESCRIPTOR=$2
        shift 2
        ;;
      --source)
        (($# >= 2)) || die "$command: --source needs a value"
        [[ -z $SOURCE_PATH ]] || die "$command: --source may be supplied only once"
        SOURCE_PATH=$2
        shift 2
        ;;
      --evidence)
        (($# >= 2)) || die "$command: --evidence needs a value"
        [[ -z $EVIDENCE_PATH ]] || die "$command: --evidence may be supplied only once"
        EVIDENCE_PATH=$2
        shift 2
        ;;
      --quiescence-evidence)
        (($# >= 2)) || die "$command: --quiescence-evidence needs a value"
        [[ -z $QUIESCENCE_EVIDENCE ]] || die "$command: --quiescence-evidence may be supplied only once"
        QUIESCENCE_EVIDENCE=$2
        shift 2
        ;;
      --receipt)
        (($# >= 2)) || die "$command: --receipt needs a value"
        [[ -z $RECEIPT_PATH ]] || die "$command: --receipt may be supplied only once"
        RECEIPT_PATH=$2
        shift 2
        ;;
      --confirm-target)
        (($# >= 2)) || die "$command: --confirm-target needs a value"
        [[ -z $CONFIRM_TARGET ]] || die "$command: --confirm-target may be supplied only once"
        CONFIRM_TARGET=$2
        shift 2
        ;;
      --approve-format)
        APPROVE_FORMAT=true
        shift
        ;;
      --approve-copy)
        APPROVE_COPY=true
        shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        die "$command: unknown argument: $1"
        ;;
    esac
  done
}

# Kept as functions so the disposable fake-command check can exercise the
# gates without creating or opening a real block device. Executed users get
# the kernel's block-device and canonical-path checks.
block_device_exists() { [[ -b $1 ]]; }
canonical_path() { readlink -f -- "$1"; }

assert_direct_storage_mountpoint() {
  [[ $MOUNTPOINT == /mnt/storage-clear/* ]] || die "descriptor mountpoint is outside direct storage"
}

read_descriptor() {
  [[ -n $DESCRIPTOR ]] || die "--descriptor is required"
  [[ -r $DESCRIPTOR ]] || die "descriptor is not readable: $DESCRIPTOR"

  VERSION=
  DISK_NAME=
  DECLARED_DEVICE=
  MAPPER=
  KEY_FILE=
  MOUNTPOINT=
  FS_TYPE=
  local key value
  while IFS='=' read -r key value; do
    case $key in
      VERSION) VERSION=$value ;;
      DISK_NAME) DISK_NAME=$value ;;
      DECLARED_DEVICE) DECLARED_DEVICE=$value ;;
      MAPPER) MAPPER=$value ;;
      KEY_FILE) KEY_FILE=$value ;;
      MOUNTPOINT) MOUNTPOINT=$value ;;
      FS_TYPE) FS_TYPE=$value ;;
      '') ;;
      *) die "unknown descriptor field: $key" ;;
    esac
  done < "$DESCRIPTOR"

  [[ $VERSION == 1 ]] || die "unsupported or missing descriptor version: $VERSION"
  [[ $DISK_NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "descriptor has invalid disk name"
  [[ $DECLARED_DEVICE == /dev/disk/by-id/* && ${DECLARED_DEVICE%/*} == /dev/disk/by-id ]] ||
    die "descriptor device is not a canonical /dev/disk/by-id path"
  [[ $MAPPER =~ ^[A-Za-z0-9._-]+$ ]] || die "descriptor has invalid mapper name"
  [[ $KEY_FILE == /run/agenix/luks-"$DISK_NAME"-key ]] ||
    die "descriptor key path is not the declared agenix key"
  assert_direct_storage_mountpoint
  [[ $FS_TYPE == xfs ]] || die "descriptor filesystem is not xfs"

  if [[ $DECLARED_DEVICE =~ -part[0-9]+$ ]]; then
    EXPECTED_WHOLE_BY_ID=${DECLARED_DEVICE%-part*}
  else
    EXPECTED_WHOLE_BY_ID=$DECLARED_DEVICE
  fi
  [[ $EXPECTED_WHOLE_BY_ID == /dev/disk/by-id/* && ${EXPECTED_WHOLE_BY_ID%/*} == /dev/disk/by-id ]] ||
    die "descriptor does not identify a canonical whole disk"
}

describe_disk() {
  parse_args describe "$@"
  read_descriptor
  printf 'DESCRIPTOR=%s\n' "$DESCRIPTOR"
  printf 'DISK=%s\n' "$DISK_NAME"
  printf 'DECLARED_DEVICE=%s\n' "$DECLARED_DEVICE"
  printf 'WHOLE_BY_ID=%s\n' "$EXPECTED_WHOLE_BY_ID"
  printf 'MAPPER=%s\n' "$MAPPER"
  printf 'MOUNTPOINT=%s\n' "$MOUNTPOINT"
  printf 'FS_TYPE=%s\n' "$FS_TYPE"
  printf 'KEY_FILE=%s\n' "$KEY_FILE"
}

resolve_declared_device() {
  local candidate type parent resolved
  candidate=$DECLARED_DEVICE
  if ! block_device_exists "$candidate" && [[ $candidate =~ -part[0-9]+$ ]]; then
    candidate=${candidate%-part*}
  fi
  block_device_exists "$candidate" || {
    echo "declared device is not present (including its whole-disk by-id path): $DECLARED_DEVICE" >&2
    return 1
  }

  candidate=$(canonical_path "$candidate") || return 1
  type=$(trim "$(lsblk -dnro TYPE -- "$candidate" 2>/dev/null || true)")
  case $type in
    disk)
      WHOLE_DEVICE=$candidate
      ;;
    part|partition)
      parent=$(trim "$(lsblk -dnro PKNAME -- "$candidate" 2>/dev/null || true)")
      [[ -n $parent ]] || {
        echo "could not resolve parent disk for $candidate" >&2
        return 1
      }
      WHOLE_DEVICE=/dev/$parent
      ;;
    *)
      echo "declared path resolves to unsupported block type '$type': $candidate" >&2
      return 1
      ;;
  esac

  block_device_exists "$WHOLE_DEVICE" || {
    echo "resolved whole disk is not a block device: $WHOLE_DEVICE" >&2
    return 1
  }
  WHOLE_DEVICE=$(canonical_path "$WHOLE_DEVICE") || return 1

  block_device_exists "$EXPECTED_WHOLE_BY_ID" || {
    echo "declared whole-disk by-id path is not present: $EXPECTED_WHOLE_BY_ID" >&2
    return 1
  }
  resolved=$(canonical_path "$EXPECTED_WHOLE_BY_ID") || return 1
  [[ $resolved == "$WHOLE_DEVICE" ]] || {
    echo "declared by-id identity changed: $EXPECTED_WHOLE_BY_ID -> $resolved, expected $WHOLE_DEVICE" >&2
    return 1
  }
  WHOLE_BY_ID=$EXPECTED_WHOLE_BY_ID
  DEVICE_TYPE=disk

  DEVICE_SERIAL=$(trim "$(lsblk -dnro SERIAL -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  DEVICE_WWN=$(trim "$(lsblk -dnro WWN -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  DEVICE_SIZE_BYTES=$(trim "$(lsblk -dnbo SIZE -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  if command -v udevadm >/dev/null 2>&1 && [[ -z $DEVICE_SERIAL || -z $DEVICE_WWN ]]; then
    local properties value
    properties=$(udevadm info --query=property --name="$WHOLE_DEVICE" 2>/dev/null || true)
    if [[ -z $DEVICE_SERIAL ]]; then
      value=$(printf '%s\n' "$properties" | while IFS='=' read -r key value; do
        [[ $key == ID_SERIAL ]] && printf '%s' "$value"
      done)
      DEVICE_SERIAL=$(trim "$value")
    fi
    if [[ -z $DEVICE_WWN ]]; then
      value=$(printf '%s\n' "$properties" | while IFS='=' read -r key value; do
        [[ $key == ID_WWN ]] && printf '%s' "$value"
      done)
      DEVICE_WWN=$(trim "$value")
    fi
  fi
}

children_for() {
  local node=$1 child child_type output
  output=$(lsblk -nrpo NAME,TYPE -- "$node" 2>/dev/null) || return 1
  while read -r child child_type; do
    [[ -n $child ]] || continue
    [[ $child == "$WHOLE_DEVICE" ]] && continue
    printf '%s\t%s\n' "$child" "$child_type"
  done <<< "$output"
}

mounts_for() {
  local node=$1 output status
  if output=$(findmnt -rn -S "$node" -o TARGET 2>&1); then
    [[ -n $output ]] && printf '%s\n' "$output"
    return 0
  else
    status=$?
    if ((status == 1)) && [[ -z $output ]]; then
      return 0
    fi
    [[ -n $output ]] && printf '%s\n' "$output" >&2
    return 1
  fi
}

mounts_for_tree() {
  local node=$1 child child_type children
  children=$(children_for "$node") || return 1
  mounts_for "$node" || return 1
  while IFS=$'\t' read -r child child_type; do
    [[ -n $child ]] || continue
    mounts_for "$child" || return 1
  done <<< "$children"
}

holders_for() {
  local node=$1 base holder
  base=${node##*/}
  [[ -d /sys/class/block/$base ]] || return 1
  for holder in /sys/class/block/"$base"/holders/*; do
    [[ -e $holder ]] || continue
    printf '%s\n' "${holder##*/}"
  done
}

holders_for_tree() {
  local node=$1 child child_type children
  children=$(children_for "$node") || return 1
  holders_for "$node"
  while IFS=$'\t' read -r child child_type; do
    [[ -n $child ]] || continue
    holders_for "$child"
  done <<< "$children"
}

stable_aliases_for() {
  local pattern=$1 candidate resolved
  for candidate in /dev/disk/by-id/$pattern; do
    [[ -e $candidate ]] || continue
    resolved=$(canonical_path "$candidate" 2>/dev/null || true)
    [[ $resolved == "$WHOLE_DEVICE" ]] && printf '%s\n' "$candidate"
  done
}

identity_token() {
  printf '%s|%s|%s|%s' "$WHOLE_BY_ID" "$DEVICE_SERIAL" "$DEVICE_WWN" "$DEVICE_SIZE_BYTES"
}

# The recorded token joins the four stable identity fields. On a mismatch,
# report each evidence field beside the value the target presents now.
report_target_evidence_diff() {
  [[ $WHOLE_BY_ID == "$EVIDENCE_TARGET_WHOLE_BY_ID" ]] ||
    printf 'TARGET_WHOLE_BY_ID evidence=%s current=%s\n' "$EVIDENCE_TARGET_WHOLE_BY_ID" "$WHOLE_BY_ID" >&2
  [[ $WHOLE_DEVICE == "$EVIDENCE_TARGET_WHOLE_DEVICE" ]] ||
    printf 'TARGET_WHOLE_DEVICE evidence=%s current=%s\n' "$EVIDENCE_TARGET_WHOLE_DEVICE" "$WHOLE_DEVICE" >&2
  [[ $DEVICE_SERIAL == "$EVIDENCE_TARGET_SERIAL" ]] ||
    printf 'TARGET_SERIAL evidence=%s current=%s\n' "$EVIDENCE_TARGET_SERIAL" "$DEVICE_SERIAL" >&2
  [[ $DEVICE_WWN == "$EVIDENCE_TARGET_WWN" ]] ||
    printf 'TARGET_WWN evidence=%s current=%s\n' "$EVIDENCE_TARGET_WWN" "$DEVICE_WWN" >&2
  [[ $DEVICE_SIZE_BYTES == "$EVIDENCE_TARGET_SIZE_BYTES" ]] ||
    printf 'TARGET_SIZE_BYTES evidence=%s current=%s\n' "$EVIDENCE_TARGET_SIZE_BYTES" "$DEVICE_SIZE_BYTES" >&2
}

report_identity() {
  local model
  model=$(trim "$(lsblk -dnro MODEL -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  printf 'DECLARED_DEVICE=%s\n' "$DECLARED_DEVICE"
  printf 'WHOLE_BY_ID=%s\n' "$WHOLE_BY_ID"
  printf 'WHOLE_DEVICE=%s\n' "$WHOLE_DEVICE"
  printf 'MODEL=%s\n' "$model"
  printf 'SIZE_BYTES=%s\n' "$DEVICE_SIZE_BYTES"
  printf 'SERIAL=%s\n' "$DEVICE_SERIAL"
  printf 'WWN=%s\n' "$DEVICE_WWN"
  printf 'DISK=%s\n' "$DISK_NAME"
}

inspect_source_mount() {
  local info target source fstype uuid extra nested
  SOURCE_MOUNT_TARGET=
  SOURCE_DEVICE=
  SOURCE_FSTYPE=
  SOURCE_UUID=

  if [[ ! -d $SOURCE_PATH || -L $SOURCE_PATH ]]; then
    fail_gate "source is not a real directory: $SOURCE_PATH"
    return 1
  fi
  SOURCE_REALPATH=$(canonical_path "$SOURCE_PATH" 2>/dev/null || true)
  if [[ -z $SOURCE_REALPATH ]]; then
    manual_gate "source canonical-path probe failed"
    return 1
  fi
  if [[ $SOURCE_REALPATH != "$SOURCE_PATH" ]]; then
    fail_gate "source path is not already canonical: $SOURCE_PATH -> $SOURCE_REALPATH"
    return 1
  fi
  if [[ $SOURCE_REALPATH == "$MOUNTPOINT" || $SOURCE_REALPATH == "$MOUNTPOINT/"* ]]; then
    fail_gate "source is the evaluated target mount or a child of it"
    return 1
  fi

  if ! info=$(findmnt -rn -T "$SOURCE_PATH" -o TARGET,SOURCE,FSTYPE,UUID 2>&1); then
    manual_gate "source mount probe failed"
    [[ -n $info ]] && printf '%s\n' "$info" >&2
    return 1
  fi
  read -r target source fstype uuid extra <<< "$info"
  if [[ -n ${extra-} || -z ${target-} || -z ${source-} || -z ${fstype-} ]]; then
    manual_gate "source mount probe returned ambiguous fields"
    return 1
  fi
  SOURCE_MOUNT_TARGET=$target
  SOURCE_DEVICE=$source
  SOURCE_FSTYPE=$fstype
  SOURCE_UUID=${uuid:--}
  if [[ $SOURCE_MOUNT_TARGET != "$SOURCE_PATH" ]]; then
    fail_gate "source is not a direct mount at $SOURCE_PATH"
  fi
  if [[ $SOURCE_FSTYPE == fuse.mergerfs || $SOURCE_FSTYPE == mergerfs ||
    $SOURCE_DEVICE == /srv/media/data || $SOURCE_DEVICE == *mergerfs* ]]; then
    fail_gate "source is a mergerfs or pooled namespace; a direct source mount is required"
  fi

  if ! nested=$(findmnt -rn -R "$SOURCE_PATH" -o TARGET 2>&1); then
    manual_gate "source nested-mount probe failed"
  else
    while IFS= read -r target; do
      [[ -n $target ]] || continue
      [[ $target == "$SOURCE_PATH" ]] || fail_gate "source contains nested mount: $target"
    done <<< "$nested"
  fi
}

measure_source() {
  local output value
  SOURCE_ST_DEV=
  SOURCE_APPARENT_BYTES=
  SOURCE_ALLOCATED_BYTES=

  if ! output=$(stat -c '%d' -- "$SOURCE_PATH" 2>&1); then
    manual_gate "source device-number probe failed"
  else
    value=$(trim "$output")
    if is_uint "$value"; then
      SOURCE_ST_DEV=$value
    else
      manual_gate "source device-number probe returned an invalid value"
    fi
  fi

  if ! output=$(du -sx --apparent-size -B1 -- "$SOURCE_PATH" 2>&1); then
    manual_gate "source apparent-byte measurement failed"
  else
    read -r value _ <<< "$output"
    if is_uint "$value"; then
      SOURCE_APPARENT_BYTES=$value
    else
      manual_gate "source apparent-byte measurement returned an invalid value"
    fi
  fi

  if ! output=$(du -sx -B1 -- "$SOURCE_PATH" 2>&1); then
    manual_gate "source allocated-byte measurement failed"
  else
    read -r value _ <<< "$output"
    if is_uint "$value"; then
      SOURCE_ALLOCATED_BYTES=$value
    else
      manual_gate "source allocated-byte measurement returned an invalid value"
    fi
  fi

  if [[ -n $SOURCE_ST_DEV && -n $SOURCE_APPARENT_BYTES && -n $SOURCE_ALLOCATED_BYTES ]]; then
    SOURCE_TOKEN=$(printf '%s\n' \
      "$SOURCE_PATH" "$SOURCE_REALPATH" "$SOURCE_MOUNT_TARGET" "$SOURCE_DEVICE" \
      "$SOURCE_FSTYPE" "$SOURCE_UUID" "$SOURCE_ST_DEV" \
      "$SOURCE_APPARENT_BYTES" "$SOURCE_ALLOCATED_BYTES" | sha256sum | cut -d' ' -f1)
    SOURCE_READY=true
    pass_gate "direct source identity and byte measurements are readable"
  else
    SOURCE_READY=false
  fi
}

inspect_source() {
  SOURCE_READY=false
  inspect_source_mount || true
  measure_source
}

probe_target_signatures() {
  local output wipefs_type status=0
  PARTITION_TABLE_SEEN=0
  RESIDUAL_SIGNATURES=
  output=$(wipefs -n --noheadings --output TYPE -- "$WHOLE_DEVICE" 2>&1) || status=$?
  while IFS= read -r wipefs_type; do
    wipefs_type=$(trim "$wipefs_type")
    [[ -n $wipefs_type ]] || continue
    case $wipefs_type in
      gpt|dos|PMBR|sgi|sun|atari)
        PARTITION_TABLE_SEEN=1
        printf 'PARTITION_TABLE type=%s\n' "$wipefs_type"
        ;;
      *)
        if [[ -n $RESIDUAL_SIGNATURES ]]; then
          RESIDUAL_SIGNATURES+=,
        fi
        RESIDUAL_SIGNATURES+=$wipefs_type
        ;;
    esac
  done <<< "$output"
  if ((status != 0)); then
    manual_gate "whole-disk signature/partition-table probe failed"
    return 1
  fi
  return 0
}

inspect_target() {
  local children mounted holders child child_type
  TARGET_CLEAR=false
  [[ -n $WHOLE_DEVICE ]] || {
    manual_gate "cannot inspect target without a resolved whole disk"
    return 1
  }

  local child_probe=0 mount_probe=0 holder_probe=0 signature_probe=0
  if ! children=$(children_for "$WHOLE_DEVICE"); then
    manual_gate "child inspection failed; target state is unknown"
    child_probe=1
  elif [[ -n $children ]]; then
    fail_gate "target has partition or device-mapper children; it is not empty"
    while IFS=$'\t' read -r child child_type; do
      [[ -n $child ]] && printf 'CHILD name=%s type=%s\n' "$child" "$child_type"
    done <<< "$children"
  else
    pass_gate "target disk has no kernel children"
  fi

  if ! mounted=$(mounts_for_tree "$WHOLE_DEVICE"); then
    manual_gate "mount inspection failed; target state is unknown"
    mount_probe=1
  elif [[ -z $mounted ]]; then
    pass_gate "target disk has no mounted child"
  else
    fail_gate "target disk or a child is mounted"
    printf '%s\n' "$mounted"
  fi

  if ! holders=$(holders_for_tree "$WHOLE_DEVICE"); then
    manual_gate "holder inspection failed; target state is unknown"
    holder_probe=1
  elif [[ -z $holders ]]; then
    pass_gate "target disk has no holders"
  else
    fail_gate "target disk has active holders"
    printf 'HOLDER name=%s\n' "$holders"
  fi

  # Always probe signatures, even when children exist. A child listing alone
  # must never suppress evidence of a stale whole-disk layout.
  if ! probe_target_signatures; then
    signature_probe=1
  fi
  if ((PARTITION_TABLE_SEEN)); then
    if [[ -z ${children-} && $child_probe -eq 0 ]]; then
      manual_gate "partition-table signature has no matching kernel children"
    elif [[ -z ${children-} ]]; then
      manual_gate "partition-table signature conflicts with unavailable children"
    else
      fail_gate "target has a partition-table signature"
    fi
  fi
  if [[ -n $RESIDUAL_SIGNATURES ]]; then
    fail_gate "target has existing signatures: $RESIDUAL_SIGNATURES"
  fi
  if ((child_probe == 0 && mount_probe == 0 && holder_probe == 0 &&
    signature_probe == 0 && PARTITION_TABLE_SEEN == 0)) && [[ -z ${children-} && -z ${mounted-} &&
    -z ${holders-} && -z $RESIDUAL_SIGNATURES ]]; then
    TARGET_CLEAR=true
    pass_gate "target has no children, mounts, holders, or recognized signatures"
  fi
}

check_capacity() {
  CAPACITY_READY=false
  TARGET_CAPACITY_BYTES=$DEVICE_SIZE_BYTES
  TARGET_REQUIRED_BYTES=
  if ! is_uint "$DEVICE_SIZE_BYTES" || ((DEVICE_SIZE_BYTES <= 0)); then
    manual_gate "target capacity measurement is unavailable"
    return
  fi
  if ! is_uint "$SOURCE_APPARENT_BYTES"; then
    manual_gate "source apparent-byte measurement is unavailable for capacity comparison"
    return
  fi
  TARGET_REQUIRED_BYTES=$((SOURCE_APPARENT_BYTES + MIN_HEADROOM_BYTES))
  if ((DEVICE_SIZE_BYTES < TARGET_REQUIRED_BYTES)); then
    fail_gate "target capacity is smaller than the source plus required headroom"
  else
    CAPACITY_READY=true
    pass_gate "target capacity covers the complete source and required headroom"
  fi
  printf 'SOURCE_APPARENT_BYTES=%s\n' "$SOURCE_APPARENT_BYTES"
  printf 'SOURCE_ALLOCATED_BYTES=%s\n' "$SOURCE_ALLOCATED_BYTES"
  printf 'TARGET_CAPACITY_BYTES=%s\n' "$TARGET_CAPACITY_BYTES"
  printf 'TARGET_REQUIRED_BYTES=%s\n' "$TARGET_REQUIRED_BYTES"
}

descriptor_sha256() {
  sha256sum -- "$DESCRIPTOR" | cut -d' ' -f1
}

evidence_path_safe() {
  local path=$1 parent parent_real
  [[ $path == /* ]] || die "evidence path must be absolute: $path"
  parent=$(dirname -- "$path")
  [[ -d $parent ]] || die "evidence parent does not exist: $parent"
  parent_real=$(canonical_path "$parent") || die "could not resolve evidence parent: $parent"
  [[ $parent_real != "$MOUNTPOINT" && $parent_real != "$MOUNTPOINT/"* ]] ||
    die "evidence must not be stored on or below the destination mount"
  if [[ -n $SOURCE_REALPATH ]]; then
    [[ $parent_real != "$SOURCE_REALPATH" && $parent_real != "$SOURCE_REALPATH/"* ]] ||
      die "evidence must not be stored on or below the source mount"
  fi
}

write_evidence() {
  [[ -n $EVIDENCE_PATH ]] || {
    manual_gate "no evidence path was supplied; rerun preflight with --evidence"
    return 1
  }
  evidence_path_safe "$EVIDENCE_PATH"
  local tmp
  umask 077
  tmp=$(mktemp "${EVIDENCE_PATH}.tmp.XXXXXX") || die "could not create evidence file"
  {
    printf 'EVIDENCE_VERSION=3\n'
    printf 'DESCRIPTOR_SHA256=%s\n' "$(descriptor_sha256)"
    printf 'DISK_NAME=%s\n' "$DISK_NAME"
    if [[ -z $SOURCE_PATH ]]; then
      printf 'SOURCE=none\n'
    else
      printf 'SOURCE=direct\n'
      cat <<EOF
SOURCE_PATH=$SOURCE_PATH
SOURCE_REALPATH=$SOURCE_REALPATH
SOURCE_MOUNT_TARGET=$SOURCE_MOUNT_TARGET
SOURCE_DEVICE=$SOURCE_DEVICE
SOURCE_FSTYPE=$SOURCE_FSTYPE
SOURCE_UUID=$SOURCE_UUID
SOURCE_ST_DEV=$SOURCE_ST_DEV
SOURCE_APPARENT_BYTES=$SOURCE_APPARENT_BYTES
SOURCE_ALLOCATED_BYTES=$SOURCE_ALLOCATED_BYTES
SOURCE_TOKEN=$SOURCE_TOKEN
EOF
    fi
    cat <<EOF
TARGET_WHOLE_BY_ID=$WHOLE_BY_ID
TARGET_WHOLE_DEVICE=$WHOLE_DEVICE
TARGET_SERIAL=$DEVICE_SERIAL
TARGET_WWN=$DEVICE_WWN
TARGET_SIZE_BYTES=$DEVICE_SIZE_BYTES
TARGET_TOKEN=$(identity_token)
TARGET_CLEAR=PASS
EOF
    if [[ -z $SOURCE_PATH ]]; then
      printf 'CAPACITY_CHECK=NOT_APPLICABLE\n'
    else
      printf 'CAPACITY_CHECK=PASS\n'
    fi
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$EVIDENCE_PATH"
  printf 'PREFLIGHT_EVIDENCE=%s\n' "$EVIDENCE_PATH"
}

preflight() {
  parse_args preflight "$@"
  read_descriptor
  GATE_FAILURES=0
  GATE_MANUALS=0
  TARGET_CLEAR=false
  SOURCE_READY=false
  CAPACITY_READY=false

  printf 'DISK %s PREFLIGHT (read-only)\n' "$DISK_NAME"
  printf 'No partitioning, filesystem, mount, copy, or pool mutation is performed.\n'
  if [[ -z $SOURCE_PATH ]]; then
    printf 'SOURCE=none (target identity and emptiness only; the evidence cannot authorize a copy)\n'
  fi
  if resolve_declared_device; then
    pass_gate "evaluated declaration resolves to its canonical whole-disk by-id path"
    report_identity
    if [[ -n $DEVICE_SERIAL ]]; then
      pass_gate "physical serial is readable"
    else
      manual_gate "physical serial is unavailable"
    fi
    if [[ -n $DEVICE_WWN ]]; then
      pass_gate "physical WWN is readable"
    else
      manual_gate "physical WWN is unavailable"
    fi
    if is_uint "$DEVICE_SIZE_BYTES" && ((DEVICE_SIZE_BYTES > 0)); then
      pass_gate "target byte size is readable"
    else
      manual_gate "target byte size is unavailable"
    fi
    local wwn_aliases serial_aliases
    wwn_aliases=$(stable_aliases_for 'wwn-*' || true)
    serial_aliases=$(stable_aliases_for 'ata-*'; stable_aliases_for 'scsi-*'; stable_aliases_for 'nvme-*'; stable_aliases_for 'usb-*' || true)
    if [[ -n $wwn_aliases ]]; then
      pass_gate "WWN by-id alias resolves to the target: $wwn_aliases"
    else
      manual_gate "no WWN by-id alias resolves to the target"
    fi
    if [[ -n $serial_aliases ]]; then
      pass_gate "serial by-id alias resolves to the target: $serial_aliases"
    else
      manual_gate "no non-WWN serial by-id alias resolves to the target"
    fi
  else
    manual_gate "evaluated declaration could not be resolved; target identity is unknown"
  fi

  if [[ -n $WHOLE_DEVICE ]]; then
    inspect_target
  else
    manual_gate "cannot inspect target without a resolved whole disk"
  fi
  local source_ready=false
  if [[ -n $SOURCE_PATH ]]; then
    inspect_source
    check_capacity
    [[ $SOURCE_READY == true && $CAPACITY_READY == true ]] && source_ready=true
  else
    # No source: nothing to measure or compare. The target size gate above
    # still applies, and the evidence records SOURCE=none.
    source_ready=true
    SOURCE_READY=true
  fi

  if ((GATE_FAILURES == 0 && GATE_MANUALS == 0)) &&
    [[ $TARGET_CLEAR == true && $source_ready == true ]]; then
    printf 'READ_ONLY_INVENTORY=PASS\n'
    printf 'FORMAT_TARGET_CLEAR=PASS\n'
    printf 'FORMAT_READINESS=PASS\n'
    printf 'FORMAT_TARGET_CONFIRMATION=%s\n' "$(identity_token)"
    write_evidence
    return 0
  fi
  printf 'READ_ONLY_INVENTORY=%s\n' "$([[ $SOURCE_READY == true ]] && printf PASS || printf FAIL)"
  printf 'FORMAT_TARGET_CLEAR=%s\n' "$([[ $TARGET_CLEAR == true ]] && printf PASS || printf FAIL)"
  printf 'FORMAT_READINESS=NOT_READY\n'
  return 2
}

read_evidence() {
  [[ -n $EVIDENCE_PATH ]] || die "--evidence is required"
  [[ -f $EVIDENCE_PATH && ! -L $EVIDENCE_PATH && -r $EVIDENCE_PATH ]] ||
    die "preflight evidence is not a regular readable file: $EVIDENCE_PATH"

  local key value
  declare -A seen=()
  EVIDENCE_VERSION=
  EVIDENCE_DESCRIPTOR_SHA256=
  EVIDENCE_DISK_NAME=
  EVIDENCE_SOURCE=
  EVIDENCE_SOURCE_PATH=
  EVIDENCE_SOURCE_REALPATH=
  EVIDENCE_SOURCE_MOUNT_TARGET=
  EVIDENCE_SOURCE_DEVICE=
  EVIDENCE_SOURCE_FSTYPE=
  EVIDENCE_SOURCE_UUID=
  EVIDENCE_SOURCE_ST_DEV=
  EVIDENCE_SOURCE_APPARENT_BYTES=
  EVIDENCE_SOURCE_ALLOCATED_BYTES=
  EVIDENCE_SOURCE_TOKEN=
  EVIDENCE_TARGET_WHOLE_BY_ID=
  EVIDENCE_TARGET_WHOLE_DEVICE=
  EVIDENCE_TARGET_SERIAL=
  EVIDENCE_TARGET_WWN=
  EVIDENCE_TARGET_SIZE_BYTES=
  EVIDENCE_TARGET_TOKEN=
  EVIDENCE_TARGET_CLEAR=
  EVIDENCE_CAPACITY_CHECK=
  while IFS='=' read -r key value; do
    [[ -n $key ]] || continue
    [[ -z ${seen[$key]+x} ]] || die "duplicate evidence field: $key"
    seen[$key]=1
    case $key in
      EVIDENCE_VERSION) EVIDENCE_VERSION=$value ;;
      DESCRIPTOR_SHA256) EVIDENCE_DESCRIPTOR_SHA256=$value ;;
      DISK_NAME) EVIDENCE_DISK_NAME=$value ;;
      SOURCE) EVIDENCE_SOURCE=$value ;;
      SOURCE_PATH) EVIDENCE_SOURCE_PATH=$value ;;
      SOURCE_REALPATH) EVIDENCE_SOURCE_REALPATH=$value ;;
      SOURCE_MOUNT_TARGET) EVIDENCE_SOURCE_MOUNT_TARGET=$value ;;
      SOURCE_DEVICE) EVIDENCE_SOURCE_DEVICE=$value ;;
      SOURCE_FSTYPE) EVIDENCE_SOURCE_FSTYPE=$value ;;
      SOURCE_UUID) EVIDENCE_SOURCE_UUID=$value ;;
      SOURCE_ST_DEV) EVIDENCE_SOURCE_ST_DEV=$value ;;
      SOURCE_APPARENT_BYTES) EVIDENCE_SOURCE_APPARENT_BYTES=$value ;;
      SOURCE_ALLOCATED_BYTES) EVIDENCE_SOURCE_ALLOCATED_BYTES=$value ;;
      SOURCE_TOKEN) EVIDENCE_SOURCE_TOKEN=$value ;;
      TARGET_WHOLE_BY_ID) EVIDENCE_TARGET_WHOLE_BY_ID=$value ;;
      TARGET_WHOLE_DEVICE) EVIDENCE_TARGET_WHOLE_DEVICE=$value ;;
      TARGET_SERIAL) EVIDENCE_TARGET_SERIAL=$value ;;
      TARGET_WWN) EVIDENCE_TARGET_WWN=$value ;;
      TARGET_SIZE_BYTES) EVIDENCE_TARGET_SIZE_BYTES=$value ;;
      TARGET_TOKEN) EVIDENCE_TARGET_TOKEN=$value ;;
      TARGET_CLEAR) EVIDENCE_TARGET_CLEAR=$value ;;
      CAPACITY_CHECK) EVIDENCE_CAPACITY_CHECK=$value ;;
      *) die "unknown evidence field: $key" ;;
    esac
  done < "$EVIDENCE_PATH"

  # Version 2 evidence predates format-only preflight and always records a
  # direct source. Version 3 states SOURCE=direct or SOURCE=none.
  case $EVIDENCE_VERSION in
    2)
      [[ -z ${seen[SOURCE]+x} ]] || die "version 2 preflight evidence must not carry SOURCE"
      EVIDENCE_SOURCE=direct
      ;;
    3)
      [[ $EVIDENCE_SOURCE == direct || $EVIDENCE_SOURCE == none ]] ||
        die "preflight evidence has an invalid SOURCE: ${EVIDENCE_SOURCE:-<missing>}"
      ;;
    *) die "unsupported preflight evidence version" ;;
  esac
  [[ $EVIDENCE_DESCRIPTOR_SHA256 == "$(descriptor_sha256)" ]] ||
    die "preflight evidence was generated from a different descriptor"
  [[ $EVIDENCE_DISK_NAME == "$DISK_NAME" ]] || die "preflight evidence names a different disk"
  [[ $EVIDENCE_TARGET_CLEAR == PASS ]] ||
    die "preflight evidence does not record a ready target"
  if [[ $EVIDENCE_SOURCE == direct ]]; then
    [[ $EVIDENCE_CAPACITY_CHECK == PASS ]] ||
      die "preflight evidence does not record a ready target"
    [[ -n $EVIDENCE_SOURCE_PATH && -n $EVIDENCE_SOURCE_TOKEN ]] ||
      die "preflight evidence lacks direct-source provenance"
  else
    [[ $EVIDENCE_CAPACITY_CHECK == NOT_APPLICABLE ]] ||
      die "SOURCE=none preflight evidence must record CAPACITY_CHECK=NOT_APPLICABLE"
    local field
    for field in SOURCE_PATH SOURCE_REALPATH SOURCE_MOUNT_TARGET SOURCE_DEVICE \
      SOURCE_FSTYPE SOURCE_UUID SOURCE_ST_DEV SOURCE_APPARENT_BYTES \
      SOURCE_ALLOCATED_BYTES SOURCE_TOKEN; do
      [[ -z ${seen[$field]+x} ]] || die "SOURCE=none preflight evidence must not carry $field"
    done
  fi
}

# quiesce, copy and normalize need a recorded direct source.
require_source_evidence() {
  [[ $EVIDENCE_SOURCE == direct ]] ||
    die "$1 requires preflight evidence with a direct source; this evidence records SOURCE=none"
}

assert_source_evidence_current() {
  SOURCE_PATH=$EVIDENCE_SOURCE_PATH
  [[ $SOURCE_PATH == "$EVIDENCE_SOURCE_REALPATH" ]] ||
    die "preflight source path is not canonical"
  SOURCE_READY=false
  GATE_FAILURES=0
  GATE_MANUALS=0
  inspect_source
  ((GATE_FAILURES == 0 && GATE_MANUALS == 0)) ||
    die "source provenance or byte measurement changed; rerun preflight after quiescing the source"
  [[ $SOURCE_READY == true ]] ||
    die "source provenance or byte measurement changed; rerun preflight after quiescing the source"
  [[ $SOURCE_REALPATH == "$EVIDENCE_SOURCE_REALPATH" &&
    $SOURCE_MOUNT_TARGET == "$EVIDENCE_SOURCE_MOUNT_TARGET" &&
    $SOURCE_DEVICE == "$EVIDENCE_SOURCE_DEVICE" &&
    $SOURCE_FSTYPE == "$EVIDENCE_SOURCE_FSTYPE" &&
    $SOURCE_UUID == "$EVIDENCE_SOURCE_UUID" &&
    $SOURCE_ST_DEV == "$EVIDENCE_SOURCE_ST_DEV" &&
    $SOURCE_APPARENT_BYTES == "$EVIDENCE_SOURCE_APPARENT_BYTES" &&
    $SOURCE_ALLOCATED_BYTES == "$EVIDENCE_SOURCE_ALLOCATED_BYTES" &&
    $SOURCE_TOKEN == "$EVIDENCE_SOURCE_TOKEN" ]] ||
    die "source provenance or byte measurement does not match preflight evidence"
}

assert_detached() {
  local children mounted holders
  children=$(children_for "$WHOLE_DEVICE") || die "could not inspect target children; refusing to format"
  [[ -z $children ]] || die "target has children; refusing to format"
  mounted=$(mounts_for_tree "$WHOLE_DEVICE") || die "could not inspect target mounts; refusing to format"
  [[ -z $mounted ]] || die "target or a child is mounted; refusing to format"
  holders=$(holders_for_tree "$WHOLE_DEVICE") || die "could not inspect target holders; refusing to format"
  [[ -z $holders ]] || die "target has holders; refusing to format"
}

assert_empty_signatures() {
  local output wipefs_type status=0
  output=$(wipefs -n --noheadings --output TYPE -- "$WHOLE_DEVICE" 2>/dev/null) || status=$?
  ((status == 0)) || die "whole-disk signature probe failed; refusing to format"
  while IFS= read -r wipefs_type; do
    wipefs_type=$(trim "$wipefs_type")
    [[ -n $wipefs_type ]] || continue
    die "$DISK_NAME has an existing signature ($wipefs_type); refusing to format"
  done <<< "$output"
}

assert_key_ready() {
  [[ -f $KEY_FILE && ! -L $KEY_FILE ]] || die "declared agenix key is not a regular file: $KEY_FILE"
  [[ -s $KEY_FILE ]] || die "declared agenix key is empty: $KEY_FILE"
  local owner mode mode_value
  read -r owner mode < <(stat -c '%u %a' -- "$KEY_FILE") || die "could not inspect agenix key permissions: $KEY_FILE"
  [[ $owner == 0 ]] || die "declared agenix key is not root-owned: $KEY_FILE"
  mode_value=$((8#$mode))
  (( (mode_value & 077) == 0 )) || die "declared agenix key is not root-private: $KEY_FILE"
}

read_quiescence_evidence() {
  [[ -n $QUIESCENCE_EVIDENCE ]] || die "--quiescence-evidence is required"
  [[ -f $QUIESCENCE_EVIDENCE && ! -L $QUIESCENCE_EVIDENCE && -r $QUIESCENCE_EVIDENCE ]] ||
    die "quiescence evidence is not a regular readable file"
  local key value
  declare -A seen=()
  QUIESCENCE_VERSION=
  QUIESCENCE_SOURCE_TOKEN=
  QUIESCENCE_WRITERS=
  QUIESCENCE_CONSISTENCY=
  while IFS='=' read -r key value; do
    [[ -n $key ]] || continue
    [[ -z ${seen[$key]+x} ]] || die "duplicate quiescence field: $key"
    seen[$key]=1
    case $key in
      EVIDENCE_VERSION) QUIESCENCE_VERSION=$value ;;
      SOURCE_TOKEN) QUIESCENCE_SOURCE_TOKEN=$value ;;
      WRITERS) QUIESCENCE_WRITERS=$value ;;
      INDEPENDENT_CONSISTENCY) QUIESCENCE_CONSISTENCY=$value ;;
      *) die "unknown quiescence field: $key" ;;
    esac
  done < "$QUIESCENCE_EVIDENCE"
  [[ $QUIESCENCE_VERSION == 1 ]] || die "unsupported quiescence evidence version"
  [[ $QUIESCENCE_WRITERS == STOPPED || $QUIESCENCE_CONSISTENCY == PASS ]] ||
    die "quiescence evidence does not establish stopped writers or independent consistency"
  [[ $QUIESCENCE_SOURCE_TOKEN == "$EVIDENCE_SOURCE_TOKEN" ]] ||
    die "quiescence evidence is bound to a different source snapshot"
}

inspect_destination_mount() {
  local info target source fstype uuid extra nested
  [[ -d $MOUNTPOINT && ! -L $MOUNTPOINT ]] ||
    die "destination is not a real mountpoint: $MOUNTPOINT"
  [[ $(canonical_path "$MOUNTPOINT") == "$MOUNTPOINT" ]] ||
    die "destination mountpoint is not canonical: $MOUNTPOINT"
  if ! info=$(findmnt -rn -T "$MOUNTPOINT" -o TARGET,SOURCE,FSTYPE,UUID 2>&1); then
    die "destination mount probe failed"
  fi
  read -r target source fstype uuid extra <<< "$info"
  [[ -z ${extra-} && $target == "$MOUNTPOINT" &&
    $source == "/dev/mapper/$MAPPER" && $fstype == "$FS_TYPE" ]] ||
    die "destination is not the evaluated direct XFS mount"
  if ! nested=$(findmnt -rn -R "$MOUNTPOINT" -o TARGET 2>&1); then
    die "destination nested-mount probe failed"
  fi
  while IFS= read -r target; do
    [[ -n $target && $target != "$MOUNTPOINT" ]] &&
      die "destination contains nested mount: $target"
  done <<< "$nested"
  DESTINATION_UUID=${uuid:--}
  DESTINATION_ST_DEV=$(stat -c '%d' -- "$MOUNTPOINT") ||
    die "destination device-number probe failed"
}

destination_free_bytes() {
  local output line free output_line
  if ! output=$(df -P -B1 -- "$MOUNTPOINT" 2>&1); then
    die "destination free-space probe failed"
  fi
  line=
  while IFS= read -r output_line; do
    [[ -n $output_line && $output_line != Filesystem* ]] && line=$output_line
  done <<< "$output"
  read -r _ _ _ free _ _ <<< "$line"
  is_uint "$free" || die "destination free-space probe returned an invalid value"
  ((free >= EVIDENCE_SOURCE_APPARENT_BYTES + MIN_HEADROOM_BYTES)) ||
    die "destination has insufficient free space for the measured source"
  printf 'DESTINATION_FREE_BYTES=%s\n' "$free"
}

destination_is_empty() {
  local entry
  shopt -s nullglob dotglob
  local entries=("$MOUNTPOINT"/*)
  shopt -u nullglob dotglob
  for entry in "${entries[@]}"; do
    [[ ${entry##*/} == . || ${entry##*/} == .. ]] && continue
    die "destination filesystem is not empty: $entry"
  done
}

verify_tree() {
  local output
  if ! output=$(rsync -aHAXSni --checksum --numeric-ids \
    --itemized-changes --out-format='%i %n%L' \
    "$SOURCE_PATH"/ "$SEED_ROOT"/ 2>&1); then
    die "copy verification rsync failed"
  fi
  [[ -z $output ]] || die "copy verification found missing or changed entries: $output"
  python3 - "$SOURCE_PATH" "$SEED_ROOT" <<'PY'
import os
import sys
from collections import defaultdict

source, target = sys.argv[1:3]

def entries(root):
    result = {}
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        names[:] = sorted(names)
        files[:] = sorted(files)
        for name in names + files:
            path = os.path.join(directory, name)
            result[os.path.relpath(path, root)] = os.lstat(path)
    return result

src = entries(source)
dst = entries(target)
if set(src) != set(dst):
    missing = sorted(set(src) - set(dst))
    extra = sorted(set(dst) - set(src))
    raise SystemExit(f"tree entries differ: missing={missing[:3]} extra={extra[:3]}")

src_links = defaultdict(set)
dst_links = defaultdict(set)
for relative, stat in src.items():
    other = dst[relative]
    if stat.st_mode & 0o170000 != other.st_mode & 0o170000:
        raise SystemExit(f"file type differs: {relative}")
    if os.path.islink(os.path.join(source, relative)):
        if os.readlink(os.path.join(source, relative)) != os.readlink(os.path.join(target, relative)):
            raise SystemExit(f"symlink target differs: {relative}")
    elif stat.st_mode & 0o170000 == 0o100000:
        if stat.st_size != other.st_size:
            raise SystemExit(f"file size differs: {relative}")
        if stat.st_size and stat.st_blocks * 512 < stat.st_size and other.st_blocks * 512 >= other.st_size:
            raise SystemExit(f"sparse file was expanded: {relative}")
        if stat.st_nlink > 1:
            src_links[(stat.st_dev, stat.st_ino)].add(relative)
            dst_links[(other.st_dev, other.st_ino)].add(relative)

if sorted(map(sorted, src_links.values())) != sorted(map(sorted, dst_links.values())):
    raise SystemExit("hardlink peer groups differ")
PY
}

copy_disk() {
  parse_args copy "$@"
  read_descriptor
  [[ $APPROVE_COPY == true ]] || die "copy requires --approve-copy"
  [[ -n $EVIDENCE_PATH ]] || die "copy requires --evidence"
  [[ -n $RECEIPT_PATH ]] || die "copy requires --receipt"
  read_evidence
  require_source_evidence copy
  read_quiescence_evidence
  [[ $QUIESCENCE_SOURCE_TOKEN == "$EVIDENCE_SOURCE_TOKEN" ]] || die "source provenance mismatch"
  SOURCE_PATH=$EVIDENCE_SOURCE_PATH
  resolve_declared_device || die "could not resolve the evaluated target"
  if [[ $(identity_token) != "$EVIDENCE_TARGET_TOKEN" ]]; then
    report_target_evidence_diff
    die "target identity no longer matches preflight evidence"
  fi
  inspect_destination_mount
  destination_free_bytes
  destination_is_empty
  assert_source_evidence_current
  [[ $SOURCE_TOKEN == "$QUIESCENCE_SOURCE_TOKEN" ]] ||
    die "source changed after quiescence evidence; rerun preflight"

  SEED_ROOT=$MOUNTPOINT/.seed
  [[ ! -e $SEED_ROOT && ! -L $SEED_ROOT ]] ||
    die "destination staging tree already exists; refusing to merge into it"
  mkdir -- "$SEED_ROOT"
  rsync -aHAXS --numeric-ids --info=progress2 -- "$SOURCE_PATH"/ "$SEED_ROOT"/
  verify_tree
  evidence_path_safe "$RECEIPT_PATH"
  local tmp
  umask 077
  tmp=$(mktemp "${RECEIPT_PATH}.tmp.XXXXXX") || die "could not create copy receipt"
  cat > "$tmp" <<EOF
COPY_RECEIPT_VERSION=1
SOURCE_PATH=$SOURCE_PATH
SOURCE_TOKEN=$SOURCE_TOKEN
TARGET_MOUNTPOINT=$MOUNTPOINT
TARGET_UUID=$DESTINATION_UUID
TARGET_ST_DEV=$DESTINATION_ST_DEV
SEED_ROOT=$SEED_ROOT
COPY_VERIFIED=PASS
EOF
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$RECEIPT_PATH"
  printf 'COPY_VERIFIED=PASS\n'
  printf 'COPY_RECEIPT=%s\n' "$RECEIPT_PATH"
  printf 'SEED_ROOT=%s\n' "$SEED_ROOT"
}

find_partition() {
  local candidate child child_type candidate_real candidate_type candidate_parent
  PARTITION=
  candidate=$DECLARED_DEVICE
  if block_device_exists "$candidate"; then
    candidate_real=$(canonical_path "$candidate" 2>/dev/null || true)
    candidate_type=$(trim "$(lsblk -dnro TYPE -- "$candidate_real" 2>/dev/null || true)")
    candidate_parent=$(trim "$(lsblk -dnro PKNAME -- "$candidate_real" 2>/dev/null || true)")
    if [[ $candidate_type == part || $candidate_type == partition ]] &&
      [[ /dev/$candidate_parent == "$WHOLE_DEVICE" ]]; then
      PARTITION=$candidate
      return
    fi
  fi
  while read -r child child_type; do
    if [[ $child_type == part || $child_type == partition ]]; then
      PARTITION=$child
      return
    fi
  done < <(lsblk -nrpo NAME,TYPE -- "$WHOLE_DEVICE" 2>/dev/null || true)
  [[ -n $PARTITION ]] || die "partition device did not appear after sgdisk"
}

format_disk() {
  parse_args format "$@"
  read_descriptor
  [[ -n $CONFIRM_TARGET ]] || die "format requires --confirm-target from preflight evidence"
  [[ $APPROVE_FORMAT == true ]] || die "format requires --approve-format"
  read_evidence
  [[ $EVIDENCE_TARGET_TOKEN == "$CONFIRM_TARGET" ]] ||
    die "confirmation does not match the recorded preflight target"
  assert_key_ready

  resolve_declared_device || die "could not resolve the evaluated declaration for $DISK_NAME"
  [[ $DEVICE_TYPE == disk ]] || die "declared target is not a whole disk"
  if [[ $(identity_token) != "$EVIDENCE_TARGET_TOKEN" ]]; then
    report_target_evidence_diff
    die "device identity does not match preflight evidence"
  fi
  assert_detached
  assert_empty_signatures
  if [[ $EVIDENCE_SOURCE == direct ]]; then
    assert_source_evidence_current
  fi
  printf 'FORMAT_TARGET_CLEAR=PASS\n'
  printf 'FRESH_IDENTITY_CONFIRMATION=%s\n' "$(identity_token)"

  # Repeat every target check after the explicit approval arguments have been
  # accepted. No stale evidence can authorize the first mutating command.
  resolve_declared_device || die "declared identity changed before mutation"
  if [[ $(identity_token) != "$EVIDENCE_TARGET_TOKEN" ]]; then
    report_target_evidence_diff
    die "device identity changed before mutation"
  fi
  assert_detached
  assert_empty_signatures

  sgdisk --zap-all "$WHOLE_DEVICE"
  sgdisk --new=1:0:0 --typecode=1:8309 "$WHOLE_DEVICE"

  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle
  fi
  find_partition
  cryptsetup luksFormat --type luks2 -- "$PARTITION"

  printf 'LUKS_FORMATTED_DEVICE=%s\n' "$PARTITION"
  printf 'Next: use the descriptor mapper and key path for the separately gated XFS and agenix keyslot realization.\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  command=${1-}
  shift || true
  case $command in
    describe) describe_disk "$@" ;;
    preflight) preflight "$@" ;;
    format) format_disk "$@" ;;
    copy) copy_disk "$@" ;;
    -h|--help|"") usage ;;
    *) die "unknown command: $command" ;;
  esac
fi
