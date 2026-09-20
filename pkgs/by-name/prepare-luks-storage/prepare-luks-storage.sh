#!/usr/bin/env bash
# prepare-luks-storage — inspect a declared disk or create its LUKS2 container.
#
# `preflight` is read-only. `format` is destructive and requires the exact
# whole-disk by-id path printed by preflight plus an explicit format approval.
# The script never accepts a volatile /dev/sdX path.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  prepare-luks-storage preflight --disk NAME --declared-device /dev/disk/by-id/...
  prepare-luks-storage format --disk NAME \
    --declared-device /dev/disk/by-id/... \
    --confirm-device /dev/disk/by-id/... \
    --key-file /run/agenix/luks-NAME-key --mapper crypt-NAME \
    --approve-format

preflight options:
  --disk NAME                    declared disk name (required)
  --declared-device PATH         exact evaluated /dev/disk/by-id path

format options:
  --disk NAME                    declared disk name (required)
  --declared-device PATH         exact evaluated declaration path (required)
  --confirm-device PATH          exact whole-disk path from preflight
  --mapper NAME                  LUKS mapper name (required)
  --key-file PATH                existing agenix key path (required)
  --approve-format               explicit destructive approval
EOF
  exit 64
}

die() { echo "ERROR: $*" >&2; exit 1; }
trim() {
  local value=${1-}
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

DISK_NAME=
DECLARED_DEVICE=
CONFIRM_DEVICE=
MAPPER=
KEY_FILE=
APPROVE_FORMAT=false

WHOLE_DEVICE=
WHOLE_BY_ID=
DEVICE_SERIAL=
DEVICE_WWN=
DEVICE_TYPE=
PARTITION=
GATE_FAILURES=0
GATE_MANUALS=0

pass_gate() { printf 'PASS  %s\n' "$*"; }
fail_gate() { printf 'FAIL  %s\n' "$*"; GATE_FAILURES=$((GATE_FAILURES + 1)); }
manual_gate() { printf 'MANUAL %s\n' "$*"; GATE_MANUALS=$((GATE_MANUALS + 1)); }

parse_args() {
  local command=${1-}
  shift || true
  while (($#)); do
    case $1 in
      --disk)
        (($# >= 2)) || die "$command: --disk needs a value"
        DISK_NAME=$2
        shift 2
        ;;
      --declared-device)
        (($# >= 2)) || die "$command: --declared-device needs a value"
        DECLARED_DEVICE=$2
        shift 2
        ;;
      --confirm-device)
        (($# >= 2)) || die "$command: --confirm-device needs a value"
        CONFIRM_DEVICE=$2
        shift 2
        ;;
      --mapper)
        (($# >= 2)) || die "$command: --mapper needs a value"
        MAPPER=$2
        shift 2
        ;;
      --key-file)
        (($# >= 2)) || die "$command: --key-file needs a value"
        KEY_FILE=$2
        shift 2
        ;;
      --approve-format)
        APPROVE_FORMAT=true
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
  [[ -n $DISK_NAME ]] || die "$command requires --disk NAME"
}

# Resolve either a present partition path or the whole-disk by-id path implied
# by a not-yet-created -partN declaration. This is intentionally strict: a
# stable by-id name is required before any device identity is considered.
resolve_declared_device() {
  local declared=$1
  local candidate type parent

  [[ $declared == /dev/disk/by-id/* && ${declared%/*} == /dev/disk/by-id ]] || {
    echo "declared device is not a canonical /dev/disk/by-id path: $declared" >&2
    return 1
  }

  candidate=$declared
  if [[ ! -b $candidate ]]; then
    if [[ $candidate =~ -part[0-9]+$ ]]; then
      candidate=${candidate%-part[0-9]*}
    fi
  fi
  [[ -b $candidate ]] || {
    echo "declared device is not present (including its whole-disk by-id path): $declared" >&2
    return 1
  }

  candidate=$(readlink -f -- "$candidate") || return 1
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

  [[ -b $WHOLE_DEVICE ]] || {
    echo "resolved whole disk is not a block device: $WHOLE_DEVICE" >&2
    return 1
  }
  WHOLE_DEVICE=$(readlink -f -- "$WHOLE_DEVICE") || return 1
  DEVICE_TYPE=disk

  # Prefer WWN, then serial-bearing by-id names. Never invent identity from a
  # path string; the symlink must resolve to the same whole disk.
  WHOLE_BY_ID=
  local pattern resolved
  for pattern in wwn-* scsi-* ata-* nvme-* usb-*; do
    for candidate in /dev/disk/by-id/$pattern; do
      [[ -e $candidate ]] || continue
      resolved=$(readlink -f -- "$candidate" 2>/dev/null || true)
      if [[ $resolved == "$WHOLE_DEVICE" ]]; then
        WHOLE_BY_ID=$candidate
        break 2
      fi
    done
  done
  [[ -n $WHOLE_BY_ID ]] || {
    echo "no whole-disk by-id link resolves to $WHOLE_DEVICE" >&2
    return 1
  }

  DEVICE_SERIAL=$(trim "$(lsblk -dnro SERIAL -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  DEVICE_WWN=$(trim "$(lsblk -dnro WWN -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  if command -v udevadm >/dev/null 2>&1; then
    local properties value
    properties=$(udevadm info --query=property --name="$WHOLE_DEVICE" 2>/dev/null || true)
    if [[ -z $DEVICE_SERIAL ]]; then
      value=$(printf '%s\n' "$properties" | while IFS='=' read -r key val; do
        if [[ $key == ID_SERIAL ]]; then
          printf '%s' "$val"
        fi
      done)
      DEVICE_SERIAL=$(trim "$value")
    fi
    if [[ -z $DEVICE_WWN ]]; then
      value=$(printf '%s\n' "$properties" | while IFS='=' read -r key val; do
        if [[ $key == ID_WWN ]]; then
          printf '%s' "$val"
        fi
      done)
      DEVICE_WWN=$(trim "$value")
    fi
  fi

  return 0
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
  local node=$1 output
  if output=$(findmnt -rn -S "$node" -o TARGET 2>&1); then
    [[ -n $output ]] && printf '%s\n' "$output"
    return 0
  fi
  [[ -z $output ]] && return 0
  printf '%s\n' "$output" >&2
  return 1
}
mounts_for_tree() {
  local node=$1 child child_type
  mounts_for "$node" || return 1
  while IFS=$'\t' read -r child child_type; do
    [[ -n $child ]] || continue
    mounts_for "$child" || return 1
  done < <(children_for "$node")
}
holders_for_tree() {
  local node=$1 child child_type
  holders_for "$node"
  while IFS=$'\t' read -r child child_type; do
    [[ -n $child ]] || continue
    holders_for "$child"
  done < <(children_for "$node")
}


holders_for() {
  local node=$1 base holder
  base=${node##*/}
  for holder in /sys/class/block/"$base"/holders/*; do
    [[ -e $holder ]] || continue
    printf '%s\n' "${holder##*/}"
  done
}

stable_aliases_for() {
  local pattern=$1 candidate resolved
  for candidate in /dev/disk/by-id/$pattern; do
    [[ -e $candidate ]] || continue
    resolved=$(readlink -f -- "$candidate" 2>/dev/null || true)
    [[ $resolved == "$WHOLE_DEVICE" ]] && printf '%s\n' "$candidate"
  done
}

report_identity() {
  local model size
  model=$(trim "$(lsblk -dnro MODEL -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  size=$(trim "$(lsblk -dnro SIZE -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  printf 'DECLARED_DEVICE=%s\n' "$DECLARED_DEVICE"
  printf 'CONFIRM_DEVICE=%s\n' "$WHOLE_BY_ID"
  printf 'WHOLE_DEVICE=%s\n' "$WHOLE_DEVICE"
  printf 'MODEL=%s\n' "$model"
  printf 'SIZE=%s\n' "$size"
  printf 'SERIAL=%s\n' "$DEVICE_SERIAL"
  printf 'WWN=%s\n' "$DEVICE_WWN"
  printf 'DISK=%s\n' "$DISK_NAME"
}





preflight() {
  parse_args preflight "$@"
  [[ -n $DECLARED_DEVICE ]] || die "preflight requires --declared-device"

  printf 'DISK %s PREFLIGHT (read-only)\n' "$DISK_NAME"
  printf 'No partitioning, filesystem, mount, pool, or state mutation is performed.\n'
  if resolve_declared_device "$DECLARED_DEVICE"; then
    pass_gate "declared $DISK_NAME resolves to a whole disk by-id path"
    report_identity
    if [[ -n $DEVICE_SERIAL ]]; then
      pass_gate "physical serial is readable"
    else
      fail_gate "physical serial is unavailable"
    fi
    if [[ -n $DEVICE_WWN ]]; then
      pass_gate "physical WWN is readable"
    else
      fail_gate "physical WWN is unavailable"
    fi
    local wwn_aliases serial_aliases
    wwn_aliases=$(stable_aliases_for 'wwn-*' || true)
    serial_aliases=$(stable_aliases_for 'ata-*'; stable_aliases_for 'scsi-*'; stable_aliases_for 'nvme-*'; stable_aliases_for 'usb-*' || true)
    if [[ -n $wwn_aliases ]]; then
      pass_gate "WWN by-id alias resolves to the target: $wwn_aliases"
    else
      fail_gate "no WWN by-id alias resolves to the target"
    fi
    if [[ -n $serial_aliases ]]; then
      pass_gate "serial by-id alias resolves to the target: $serial_aliases"
    else
      manual_gate "no non-WWN serial by-id alias resolves to the target"
    fi
  else
    fail_gate "declared $DISK_NAME device could not be resolved"
  fi

  if [[ -n $WHOLE_DEVICE ]]; then
    local children child child_type mounted holders wipefs_output wipefs_type
    local wipefs_status=0 partition_table_seen=0 residual_signature=
    if ! children=$(children_for "$WHOLE_DEVICE"); then
      fail_gate "child inspection failed; format readiness is unknown"
      children=$'probe-error\tunknown'
    fi
    if [[ -z $children ]]; then
      pass_gate "target disk has no children"
    else
      fail_gate "target disk is not empty; whole-disk formatting is refused"
      while IFS=$'\t' read -r child child_type; do
        [[ -n $child ]] && printf 'CHILD name=%s type=%s\n' "$child" "$child_type"
      done <<< "$children"
    fi

    if ! mounted=$(mounts_for_tree "$WHOLE_DEVICE"); then
      fail_gate "mount inspection failed; format readiness is unknown"
    elif [[ -z $mounted ]]; then
      pass_gate "target disk has no mounted child"
    else
      fail_gate "target disk or a child is mounted"
      printf '%s\n' "$mounted"
    fi
    holders=$(holders_for_tree "$WHOLE_DEVICE")
    if [[ -z $holders ]]; then
      pass_gate "target disk has no holders"
    else
      fail_gate "target disk has active holders"
      printf 'HOLDER name=%s\n' "$holders"
    fi

    wipefs_output=$(wipefs -n --noheadings --output TYPE -- "$WHOLE_DEVICE" 2>/dev/null) || wipefs_status=$?
    while IFS= read -r wipefs_type; do
      wipefs_type=$(trim "$wipefs_type")
      [[ -n $wipefs_type ]] || continue
      case $wipefs_type in
        gpt|dos|PMBR|sgi|sun|atari)
          partition_table_seen=1
          printf 'PARTITION_TABLE type=%s\n' "$wipefs_type"
          ;;
        *)
          residual_signature=$wipefs_type
          ;;
      esac
    done <<< "$wipefs_output"
    if ((wipefs_status != 0)); then
      manual_gate "whole-disk signature/partition-table probe failed"
    elif ((partition_table_seen)); then
      fail_gate "$DISK_NAME has a partition-table signature; expected an empty target"
    elif [[ -n $residual_signature ]]; then
      fail_gate "$DISK_NAME has an existing filesystem signature: $residual_signature"
    else
      pass_gate "$DISK_NAME has no filesystem or partition-table signatures"
    fi
  else
    fail_gate "cannot inspect $DISK_NAME emptiness without a target disk"
  fi

  if [[ -n $WHOLE_DEVICE && -n $DEVICE_SERIAL && -n $DEVICE_WWN ]]; then
    printf 'READ_ONLY_INVENTORY=PASS\n'
  else
    printf 'READ_ONLY_INVENTORY=FAIL\n'
  fi
  if ((GATE_FAILURES == 0 && GATE_MANUALS == 0)); then
    printf 'EMPTY=PASS\n'
    printf 'FORMAT_READINESS=PASS\n'
  else
    printf 'EMPTY=FAIL\n'
    printf 'FORMAT_READINESS=NOT_READY\n'
  fi
  ((GATE_FAILURES == 0 && GATE_MANUALS == 0)) || return 2
}

resolve_confirm_device() {
  [[ $CONFIRM_DEVICE == /dev/disk/by-id/* && ${CONFIRM_DEVICE%/*} == /dev/disk/by-id ]] || die "--confirm-device must be a canonical /dev/disk/by-id whole-disk path"
  [[ -b $CONFIRM_DEVICE ]] || die "confirmed device is not a block device: $CONFIRM_DEVICE"
  [[ $CONFIRM_DEVICE != *-part[0-9]* ]] || die "--confirm-device must name the whole disk, not a partition"
  WHOLE_DEVICE=$(readlink -f -- "$CONFIRM_DEVICE") || die "could not resolve $CONFIRM_DEVICE"
  DEVICE_TYPE=$(trim "$(lsblk -dnro TYPE -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  [[ $DEVICE_TYPE == disk ]] || die "confirmed path is not a whole disk: $CONFIRM_DEVICE"
  DEVICE_SERIAL=$(trim "$(lsblk -dnro SERIAL -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  DEVICE_WWN=$(trim "$(lsblk -dnro WWN -- "$WHOLE_DEVICE" 2>/dev/null || true)")
  if command -v udevadm >/dev/null 2>&1 && [[ -z $DEVICE_SERIAL || -z $DEVICE_WWN ]]; then
    local properties value
    properties=$(udevadm info --query=property --name="$WHOLE_DEVICE" 2>/dev/null || true)
    if [[ -z $DEVICE_SERIAL ]]; then
      value=$(printf '%s\n' "$properties" | while IFS='=' read -r key val; do
        if [[ $key == ID_SERIAL ]]; then
          printf '%s' "$val"
        fi
      done)
      DEVICE_SERIAL=$(trim "$value")
    fi
    if [[ -z $DEVICE_WWN ]]; then
      value=$(printf '%s\n' "$properties" | while IFS='=' read -r key val; do
        if [[ $key == ID_WWN ]]; then
          printf '%s' "$val"
        fi
      done)
      DEVICE_WWN=$(trim "$value")
    fi
  fi
  [[ -n $DEVICE_SERIAL ]] || die "serial is unavailable for $CONFIRM_DEVICE"
  [[ -n $DEVICE_WWN ]] || die "WWN is unavailable for $CONFIRM_DEVICE"
}

assert_detached() {
  local children child child_type mounted holders
  if ! children=$(children_for "$WHOLE_DEVICE"); then
    die "could not inspect target children; refusing to format"
  fi
  [[ -z $children ]] || die "target has children; refusing to format a non-empty destination"
  if ! mounted=$(mounts_for_tree "$WHOLE_DEVICE"); then
    die "could not inspect target mounts; refusing to format"
  fi
  [[ -z $mounted ]] || die "target or a child is mounted; refusing to format"
  holders=$(holders_for_tree "$WHOLE_DEVICE")
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

find_partition() {
  local candidate child child_type candidate_real candidate_type candidate_parent
  PARTITION=
  candidate="${CONFIRM_DEVICE}-part1"
  if [[ -b $candidate ]]; then
    candidate_real=$(readlink -f -- "$candidate" 2>/dev/null || true)
    candidate_type=$(trim "$(lsblk -dnro TYPE -- "$candidate_real" 2>/dev/null || true)")
    candidate_parent=$(trim "$(lsblk -dnro PKNAME -- "$candidate_real" 2>/dev/null || true)")
    if [[ $candidate_type == part || $candidate_type == partition ]] && [[ /dev/$candidate_parent == "$WHOLE_DEVICE" ]]; then
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
  [[ -n $DECLARED_DEVICE ]] || die "format requires --declared-device"
  [[ -n $CONFIRM_DEVICE ]] || die "format requires --confirm-device"
  [[ -n $MAPPER ]] || die "format requires --mapper"
  [[ -n $KEY_FILE ]] || die "format requires --key-file"
  [[ $APPROVE_FORMAT == true ]] || die "format requires --approve-format"
  [[ -r $KEY_FILE ]] || die "agenix key is not readable: $KEY_FILE"

  local declared_whole
  resolve_declared_device "$DECLARED_DEVICE" ||
    die "could not resolve declared device: $DECLARED_DEVICE"
  declared_whole=$WHOLE_DEVICE
  resolve_confirm_device
  [[ $WHOLE_DEVICE == "$declared_whole" ]] ||
    die "declared device and confirmed device resolve to different whole disks"
  assert_detached
  assert_empty_signatures
  printf 'FORMAT_TARGET=%s\n' "$CONFIRM_DEVICE"
  printf 'WHOLE_DEVICE=%s\n' "$WHOLE_DEVICE"
  printf 'SERIAL=%s\n' "$DEVICE_SERIAL"
  printf 'WWN=%s\n' "$DEVICE_WWN"
  sgdisk --zap-all "$WHOLE_DEVICE"
  sgdisk --new=1:0:0 --typecode=1:8309 "$WHOLE_DEVICE"

  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle
  fi
  find_partition
  cryptsetup luksFormat --type luks2 -- "$PARTITION"

  printf 'LUKS_FORMATTED_DEVICE=%s\n' "$PARTITION"
  printf 'Next: xfs-format must open this container with the recovery passphrase, create XFS, and add %s as the agenix keyslot.\n' "$KEY_FILE"
}

command=${1-}
shift || true
case $command in
  preflight) preflight "$@" ;;
  format) format_disk "$@" ;;
  -h|--help|"") usage ;;
  *) die "unknown command: $command" ;;
esac
