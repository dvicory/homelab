#!/usr/bin/env bash
# Runs the packaged prepare-luks-storage against disposable QEMU SCSI disks, as
# root in a test VM. Nothing is faked: every storage probe, measurement,
# partitioning, LUKS and transfer command the tool runs is the real binary on
# a real (virtual) block device.
#
# Each call to a traced tool from the packaged script passes through a shell
# function that records the calling function, the arguments and the exit
# status, then runs the real binary unchanged. CALL_SITES lists every call of
# those tools in the packaged script, parsed from its syntax tree at build
# time. The run fails unless every listed call site ran and every traced call
# succeeded, so an unsupported option, unknown output column or typo fails
# here even where the tool hides the command's status with `|| true` or falls
# back to udev.
set -Eeuo pipefail
trap 'echo "prepare-luks-storage runtime: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

: "${PREPARE_LUKS_STORAGE:?}" "${CALL_SITES:?}" "${TRACED_TOOLS:?}"
tool=$PREPARE_LUKS_STORAGE
work=$(mktemp -d)
export TOOL_TRACE=$work/trace
: > "$TOOL_TRACE"
# Disposable test passphrase for throwaway disks; not a deployed credential.
passphrase=disposable-test-passphrase

fail() {
  echo "prepare-luks-storage runtime: $*" >&2
  exit 1
}

# Record one call and pass the real tool's stdin, stdout, stderr and status
# through. BASH_SOURCE[2] and FUNCNAME[2] name the script and function that
# called the tool's shim; BASH_LINENO[1] is the line, for diagnostics only.
trace_call() {
  local name=$1 rc=0 err args
  shift
  err=$(mktemp)
  command "$name" "$@" 2> "$err" || rc=$?
  args=$(printf '%s\x1f' "$@")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${BASH_SOURCE[2]}" "${FUNCNAME[2]}" "${BASH_LINENO[1]}" \
    "$name" "$rc" "$(wc -c < "$err")" "$args" >> "$TOOL_TRACE"
  { printf '%q ' "$name" "$@"; printf '=> %s\n' "$rc"; cat "$err"; } >> "$TOOL_TRACE.log"
  cat "$err" >&2
  rm -f "$err"
  return "$rc"
}

# Run the packaged tool with shims for the traced tools. The shims exist only
# in this subshell's environment, so the harness's own commands are untraced.
traced() (
  local name
  for name in $TRACED_TOOLS; do
    eval "$name() { trace_call $name \"\$@\"; }"
    export -f "${name?}"
  done
  export -f trace_call
  "$tool" "$@"
)

# run NAME EXPECTED_STATUS SUBCOMMAND ARGS... (stdin is passed through)
run() {
  local name=$1 expected=$2 rc=0
  shift 2
  traced "$@" > "$work/$name.out" 2>&1 || rc=$?
  if [[ $rc != "$expected" ]]; then
    cat "$work/$name.out" >&2
    fail "$name: prepare-luks-storage $1 exited $rc, expected $expected"
  fi
}

field() { sed -n "s/^$1=//p" "$2"; }

mutator_calls() { awk -F'\t' '$4 == "sgdisk" || $4 == "cryptsetup"' "$TOOL_TRACE" | wc -l; }

udevadm settle

# Disk A: partition-declared target for the full migration lifecycle.
# Disk B: no WWN, so the tool's udev fallback runs and preflight refuses.
# Disk C: whole-disk declaration, so format finds the new partition by listing
#         the disk's children.
a_whole=/dev/disk/by-id/wwn-0x5000c500000a0001
c_whole=/dev/disk/by-id/wwn-0x5000c500000c0003
b_whole=
for link in /dev/disk/by-id/*PR44NOWWNB*; do
  [[ $link == *-part* ]] || { b_whole=$link; break; }
done
for disk in "$a_whole" "$b_whole" "$c_whole"; do
  [[ -b $disk ]] || { ls -l /dev/disk/by-id >&2; fail "fixture disk is missing: ${disk:-PR44NOWWNB}"; }
done

descriptor() {
  local name=$1 device=$2
  cat > "$work/$name.descriptor" <<EOF
VERSION=1
DISK_NAME=$name
DECLARED_DEVICE=$device
MAPPER=crypt-$name
KEY_FILE=/run/agenix/luks-$name-key
MOUNTPOINT=/mnt/storage-clear/$name
FS_TYPE=xfs
EOF
  install -d -m 0700 /run/agenix
  head -c 64 /dev/urandom > "/run/agenix/luks-$name-key"
  chmod 0400 "/run/agenix/luks-$name-key"
}
descriptor pr44a "$a_whole-part1"
descriptor pr44b "$b_whole"
descriptor pr44c "$c_whole"

# A direct source mount with a hardlink pair, a symlink and a sparse file.
source=/srv/legacy-source
mkdir -p "$source"
mount -t tmpfs -o size=64m legacy-source "$source"
mkdir -p "$source/media/tv"
printf 'episode\n' > "$source/media/tv/e01.mkv"
ln "$source/media/tv/e01.mkv" "$source/media/tv/e01-link.mkv"
ln -s e01.mkv "$source/media/tv/latest.mkv"
truncate -s 8M "$source/media/tv/sparse.bin"

# --- A: preflight, format, realize, refuse, quiesce, copy, verify ----------
a_evidence=/run/pr44a-preflight
run a-preflight 0 preflight --descriptor "$work/pr44a.descriptor" \
  --source "$source" --evidence "$a_evidence"
# The evidence records the disk's physical identity, not a udev fallback.
a_node=$(readlink -f "$a_whole")
[[ $(field TARGET_SERIAL "$a_evidence") == PR44TARGETA ]] || fail "disk A serial not recorded"
[[ $(field TARGET_WWN "$a_evidence") == 0x5000c500000a0001 ]] || fail "disk A WWN not recorded"
[[ $(field TARGET_SIZE_BYTES "$a_evidence") == "$(blockdev --getsize64 "$a_node")" ]] ||
  fail "disk A size not recorded"

printf '%s\n' "$passphrase" | run a-format 0 format --descriptor "$work/pr44a.descriptor" \
  --evidence "$a_evidence" --confirm-target "$(field TARGET_TOKEN "$a_evidence")" --approve-format
a_part=$a_whole-part1
[[ $(lsblk -nro NAME,TYPE "$a_node" | awk '$2 == "part"' | wc -l) == 1 ]] || fail "disk A should have one partition"
[[ $(lsblk -dno PARTTYPE "$a_part") == ca7d7ccb-63ed-4c53-861c-1742536059cc ]] ||
  fail "disk A partition is not typed Linux LUKS"
cryptsetup isLuks --type luks2 "$a_part" || fail "disk A partition is not LUKS2"

# The separately gated realization from the runbook.
printf '%s\n' "$passphrase" | cryptsetup open "$a_part" crypt-pr44a
if blkid /dev/mapper/crypt-pr44a; then fail "new LUKS mapping already has a filesystem"; fi
mkfs.xfs -q /dev/mapper/crypt-pr44a
cryptsetup close crypt-pr44a
printf '%s\n' "$passphrase" | cryptsetup luksAddKey "$a_part" /run/agenix/luks-pr44a-key
cryptsetup open --key-file /run/agenix/luks-pr44a-key "$a_part" crypt-pr44a
mkdir -p /mnt/storage-clear/pr44a
mount /dev/mapper/crypt-pr44a /mnt/storage-clear/pr44a

# The realized, mounted disk is not a format target: preflight refuses and a
# replayed format stops before sgdisk or cryptsetup runs.
run a-preflight-in-use 2 preflight --descriptor "$work/pr44a.descriptor" \
  --evidence /run/pr44a-preflight-in-use
[[ ! -e /run/pr44a-preflight-in-use ]] || fail "refused preflight wrote evidence"
luks_uuid=$(cryptsetup luksUUID "$a_part")
mutators=$(mutator_calls)
printf '%s\n' "$passphrase" | run a-format-in-use 1 format --descriptor "$work/pr44a.descriptor" \
  --evidence "$a_evidence" --confirm-target "$(field TARGET_TOKEN "$a_evidence")" --approve-format
[[ $(mutator_calls) == "$mutators" ]] || fail "refused format ran sgdisk or cryptsetup"
[[ $(cryptsetup luksUUID "$a_part") == "$luks_uuid" ]] || fail "refused format changed the LUKS header"
mountpoint -q /mnt/storage-clear/pr44a || fail "refused format disturbed the mount"

run a-quiesce 0 quiesce --descriptor "$work/pr44a.descriptor" --evidence "$a_evidence" \
  --quiescence-evidence /run/pr44a-quiescence --writers-stopped
run a-copy 0 copy --descriptor "$work/pr44a.descriptor" --evidence "$a_evidence" \
  --quiescence-evidence /run/pr44a-quiescence --receipt /run/pr44a-receipt --approve-copy
[[ $(field COPY_VERIFIED /run/pr44a-receipt) == PASS ]] || fail "copy did not record verification"
run a-verify 0 verify --descriptor "$work/pr44a.descriptor" --evidence "$a_evidence" \
  --quiescence-evidence /run/pr44a-quiescence --receipt /run/pr44a-verify-receipt --approve-verify
[[ $(field VERIFIED_BY /run/pr44a-verify-receipt) == verify ]] || fail "verify did not record itself"

# --- B: no WWN anywhere; preflight refuses ----------------------------------
run b-preflight 2 preflight --descriptor "$work/pr44b.descriptor" --evidence /run/pr44b-preflight
[[ ! -e /run/pr44b-preflight ]] || fail "disk B preflight wrote evidence without a WWN"

# --- C: whole-disk declaration; format locates the new partition -----------
c_evidence=/run/pr44c-preflight
run c-preflight 0 preflight --descriptor "$work/pr44c.descriptor" --evidence "$c_evidence"
[[ $(field SOURCE "$c_evidence") == none ]] || fail "disk C evidence should record SOURCE=none"
printf '%s\n' "$passphrase" | run c-format 0 format --descriptor "$work/pr44c.descriptor" \
  --evidence "$c_evidence" --confirm-target "$(field TARGET_TOKEN "$c_evidence")" --approve-format
cryptsetup isLuks --type luks2 "$c_whole-part1" || fail "disk C partition is not LUKS2"

# --- Every call site ran, and every traced call succeeded -------------------
if ! python3 - "$CALL_SITES" "$TOOL_TRACE" "$tool" <<'PY'; then
import json
import sys

sites_path, trace_path, tool = sys.argv[1:]
with open(sites_path) as handle:
    sites = [json.loads(line) for line in handle]
ran = set()
errors = []
with open(trace_path) as handle:
    for record in handle:
        caller, function, line, name, rc, errbytes, args = record.rstrip("\n").split("\t", 6)
        argv = args.split("\x1f")[:-1]
        where = f"{name} in {function} (line {line}): {' '.join(argv)}"
        if caller != tool:
            errors.append(f"traced call from outside the packaged tool: {caller}: {where}")
            continue
        matches = [
            site for site in sites
            if (site["function"], site["tool"]) == (function, name)
            and argv[:len(site["prefix"])] == site["prefix"]
        ]
        if len(matches) != 1:
            errors.append(f"traced call matches {len(matches)} parsed call sites: {where}")
            continue
        ran.add(matches[0]["line"])
        # findmnt exits 1 without output when a device has no mount.
        if rc != "0" and not (name == "findmnt" and rc == "1" and errbytes == "0"):
            errors.append(f"real {name} exited {rc}: {where}")
for site in sites:
    if site["line"] not in ran:
        errors.append(f"call site never ran: line {site['line']} {site['tool']} in {site['function']}")
for error in errors:
    print(error, file=sys.stderr)
print(f"{len(sites)} call sites; {len(ran)} ran; {len(errors)} errors", file=sys.stderr)
sys.exit(1 if errors else 0)
PY
  echo "--- traced calls ---" >&2
  cat "$TOOL_TRACE.log" >&2
  fail "real-tool call-site check failed"
fi
echo "prepare-luks-storage runtime: every call site ran and every real call succeeded"
