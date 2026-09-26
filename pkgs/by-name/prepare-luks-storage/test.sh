#!/usr/bin/env bash
# Disposable fake-command coverage for the direct-source migration gates. It
# sources the real gate logic, fakes only system probes and mutators, and never
# opens a block device or copies real data.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
formatter=$script_dir/prepare-luks-storage.sh
tmp=$(mktemp -d)
mountpoint=$tmp/storage-clear/fixture
mkdir -p "$tmp/source" "$mountpoint"
trap 'rm -rf "$tmp"' EXIT
fake_bin=$tmp/bin
mkdir -p "$fake_bin"

cat > "$fake_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'lsblk %s\n' "$*" >> "$LOG"
case "$*" in
  "-dnro TYPE -- /dev/fake-disk") printf 'disk\n' ;;
  "-dnro TYPE -- /dev/fake-part1") printf 'part\n' ;;
  "-dnro PKNAME -- "*) printf 'fake-disk\n' ;;
  "-dnro SERIAL -- "*) [[ ${CASE-} != missing-serial ]] && printf 'SERIAL-4\n' ;;
  "-dnro WWN -- "*) [[ ${CASE-} != missing-wwn ]] && printf 'WWN-4\n' ;;
  "-dnbo SIZE -- "*)
    if [[ ${CASE-} == missing-size ]]; then printf ''; elif [[ ${CASE-} == small-capacity ]]; then printf '100\n'; else printf '12000000000000\n'; fi
    ;;
  "-dnro MODEL -- "*) printf 'fixture-disk\n' ;;
  "-nrpo NAME,TYPE -- "*)
    if [[ ${CASE-} == children || ${CASE-} == children-probe ]]; then
      [[ ${CASE-} != children-probe ]] && printf '/dev/fake-part1 part\n' || exit 2
    else
      printf ''
    fi
    ;;
  *) echo "unexpected lsblk args: $*" >&2; exit 2 ;;
esac
EOF

cat > "$fake_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'findmnt %s\n' "$*" >> "$LOG"
if [[ $* == "-rn -S /dev/fake-disk -o TARGET" ]]; then
  if [[ ${CASE-} == mount ]]; then printf '/mnt/fake\n'; exit 0; fi
  if [[ ${CASE-} == mount-probe ]]; then exit 2; fi
  exit 1
fi
if [[ $* == "-rn -T $SOURCE -o TARGET,SOURCE,FSTYPE,UUID" ]]; then
  [[ ${CASE-} != source-mount-probe ]] || exit 2
  if [[ ${CASE-} == source-pool ]]; then
    printf '%s /srv/media/data fuse.mergerfs -\n' "$SOURCE"
  elif [[ ${CASE-} == source-remounted ]]; then
    printf '%s /dev/fuse fuse.gocryptfs NEWUUID-9\n' "$SOURCE"
  elif [[ ${CASE-} == source-different-device ]]; then
    printf '%s /dev/other fuse.gocryptfs -\n' "$SOURCE"
  elif [[ ${CASE-} == source-different-fstype ]]; then
    printf '%s /dev/fuse fuse.other -\n' "$SOURCE"
  elif [[ ${CASE-} == source-moved ]]; then
    printf '%s-moved /dev/fuse fuse.gocryptfs -\n' "$SOURCE"
  else
    printf '%s /dev/fuse fuse.gocryptfs -\n' "$SOURCE"
  fi
  exit 0
fi
if [[ $* == "-rn -R $SOURCE -o TARGET" ]]; then
  [[ ${CASE-} != source-nested-probe ]] || exit 2
  printf '%s\n' "$SOURCE"
  [[ ${CASE-} != source-nested ]] || printf '%s/nested\n' "$SOURCE"
  exit 0
fi
if [[ $* == "-rn -T $MOUNTPOINT -o TARGET,SOURCE,FSTYPE,UUID" ]]; then
  [[ ${CASE-} != destination-mount-probe ]] || exit 2
  printf '%s /dev/mapper/crypt-fixture xfs UUID-4\n' "$MOUNTPOINT"
  exit 0
fi
if [[ $* == "-rn -R $MOUNTPOINT -o TARGET" ]]; then
  [[ ${CASE-} != destination-nested-probe ]] || exit 2
  printf '%s\n' "$MOUNTPOINT"
  exit 0
fi
echo "unexpected findmnt args: $*" >&2
exit 2
EOF

cat > "$fake_bin/udevadm" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'udevadm %s\n' "$*" >> "$LOG"
if [[ $* == *'--query=property'* ]]; then
  [[ ${CASE-} != missing-serial ]] && printf 'ID_SERIAL=SERIAL-4\n'
  [[ ${CASE-} != missing-wwn ]] && printf 'ID_WWN=WWN-4\n'
fi
EOF

cat > "$fake_bin/wipefs" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'wipefs %s\n' "$*" >> "$LOG"
if [[ ${CASE-} == signature ]]; then
  printf 'ext4\n'
elif [[ ${CASE-} == partition-table ]]; then
  printf 'gpt\n'
elif [[ ${CASE-} == signature-probe ]]; then
  exit 2
fi
EOF

cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'stat %s\n' "$*" >> "$LOG"
if [[ ${CASE-} == source-stat-probe ]]; then exit 2; fi
if [[ $* == "-c %d -- $SOURCE" ]]; then
  if [[ ${CASE-} == source-remounted ]]; then printf '777\n'; else printf '400\n'; fi
  exit 0
fi
if [[ $* == "-c %d -- $MOUNTPOINT" ]]; then printf '401\n'; exit 0; fi
printf '0 400\n'
EOF

cat > "$fake_bin/du" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'du %s\n' "$*" >> "$LOG"
[[ ${CASE-} != source-du-probe ]] || exit 2
if [[ $* == *--apparent-size* ]]; then printf '100 %s\n' "$SOURCE"; else printf '80 %s\n' "$SOURCE"; fi
EOF

cat > "$fake_bin/df" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'df %s\n' "$*" >> "$LOG"
[[ ${CASE-} != destination-free-probe ]] || exit 2
printf 'Filesystem 1-blocks Used Available Capacity Mounted on\n'
if [[ ${CASE-} == destination-small ]]; then
  printf '/dev/mapper/crypt-fixture 20000000000000 100 50 1%% %s\n' "$MOUNTPOINT"
else
  printf '/dev/mapper/crypt-fixture 20000000000000 100 14000000000000 1%% %s\n' "$MOUNTPOINT"
fi
EOF

cat > "$fake_bin/sgdisk" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'sgdisk %s\n' "$*" >> "$LOG"
[[ ${CASE-} != sgdisk-fail ]]
[[ $1 != --new=* ]] || : > "$LOG.partition"
EOF

cat > "$fake_bin/cryptsetup" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'cryptsetup %s\n' "$*" >> "$LOG"
EOF

cat > "$fake_bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'rsync %s\n' "$*" >> "$LOG"
if [[ ${CASE-} == rsync-copy-fail && $* != *--checksum* ]]; then exit 2; fi
if [[ ${CASE-} == rsync-verify-diff && $* == *--checksum* ]]; then printf '>f++++++++ changed\n'; fi
EOF

cat > "$fake_bin/python3" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'python3 %s\n' "$*" >> "$LOG"
cat >/dev/null
EOF

for fake in "$fake_bin"/*; do
  {
    printf '#!%s\n' "$BASH"
    tail -n +2 "$fake"
  } > "$fake.new"
  mv "$fake.new" "$fake"
done
chmod +x "$fake_bin"/*

descriptor=$tmp/descriptor
cat > "$descriptor" <<EOF
VERSION=1
DISK_NAME=fixture
DECLARED_DEVICE=/dev/disk/by-id/wwn-fixture-part1
MAPPER=crypt-fixture
KEY_FILE=/run/agenix/luks-fixture-key
MOUNTPOINT=$mountpoint
FS_TYPE=xfs
EOF

confirm="/dev/disk/by-id/wwn-fixture|SERIAL-4|WWN-4|12000000000000"
source_dir=$tmp/source
export SCRIPT=$formatter FIXTURE_DESCRIPTOR=$descriptor SOURCE=$source_dir MOUNTPOINT=$mountpoint
export tmp

fixture_setup() {
  block_device_exists() {
    case $1 in
      /dev/disk/by-id/wwn-fixture|/dev/fake-disk) return 0 ;;
      /dev/disk/by-id/wwn-fixture-part1|/dev/fake-part1) [[ -e $LOG.partition ]] ;;
      *) return 1 ;;
    esac
  }
  canonical_path() {
    case $1 in
      /dev/disk/by-id/wwn-fixture)
        if [[ ${CASE-} == wrong-identity ]]; then printf '/dev/other-disk\n'; return; fi
        [[ ${CASE-} != partition-alias ]] && printf '/dev/fake-disk\n' || printf '/dev/fake-part1\n'
        ;;
      /dev/disk/by-id/wwn-fixture-part1) printf '/dev/fake-part1\n' ;;
      /dev/fake-disk|/dev/fake-part1|"$SOURCE"|"$MOUNTPOINT"|"$tmp") printf '%s\n' "$1" ;;
      *) return 1 ;;
    esac
  }
  stable_aliases_for() {
    [[ ${CASE-} != missing-wwn || $1 != wwn-* ]] && printf '/dev/disk/by-id/wwn-fixture\n'
  }
  holders_for_tree() {
    [[ ${CASE-} != holders-probe ]] || return 1
    [[ ${CASE-} == holders ]] && printf 'fixture-holder\n'
    return 0
  }
  assert_key_ready() { [[ ${CASE-} != key-missing ]]; }
  # The fixture mountpoint lives under $tmp. The production prefix check stays
  # real for the mountpoint-confinement refusal case and is stubbed elsewhere.
  if [[ ${CASE-} != mountpoint-confinement ]]; then
    assert_direct_storage_mountpoint() { return 0; }
  fi
}
export -f fixture_setup

# `! grep` does not trip `set -e`; fail explicitly when a pattern is present.
refute_grep() {
  if grep -q -- "$1" "$2"; then
    echo "unexpected match for '$1' in $2" >&2
    exit 1
  fi
}

assert_no_format_mutator() {
  local log=$1 line
  [[ -f $log ]] || return 0
  while IFS= read -r line; do
    case $line in
      sgdisk\ *|cryptsetup\ *)
        echo "fixture reached a format mutator: $line" >&2
        return 1
        ;;
    esac
  done < "$log"
}

run_preflight_case() {
  local name=$1 expected=$2 with_source=${3-yes} case_name=${4-$1}
  local evidence=$tmp/$name.evidence log=$tmp/$name.log
  local descriptor_path=$descriptor rc=0
  [[ $name != wrong-identity ]] || {
    descriptor_path=$tmp/wrong-descriptor
    sed 's#DECLARED_DEVICE=.*#DECLARED_DEVICE=/dev/sdX#' "$descriptor" > "$descriptor_path"
  }
  rm -f "$evidence" "$log" "$log.partition"
  if CASE=$case_name LOG=$log EVIDENCE=$evidence FIXTURE_DESCRIPTOR=$descriptor_path PATH="$fake_bin:$PATH" \
    WITH_SOURCE=$with_source bash -c '
      set -euo pipefail
      source "$SCRIPT"
      fixture_setup
      args=(--descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE")
      [[ $WITH_SOURCE != yes ]] || args+=(--source "$SOURCE")
      parse_args preflight "${args[@]}"
      preflight
    ' >"$log.out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ $expected == pass ]]; then
    [[ $rc -eq 0 && -s $evidence ]] || { cat "$log.out" >&2; return 1; }
  else
    [[ $rc -ne 0 ]] || { echo "preflight fixture unexpectedly passed: $name" >&2; return 1; }
    assert_no_format_mutator "$log"
  fi
}

# Read-only preflight: direct source provenance, stable identity, target
# emptiness, signature/partition-table evidence, measurements, and capacity.
run_preflight_case success pass
base_evidence=$tmp/success.evidence
for refusal in \
  wrong-identity partition-alias missing-serial missing-wwn missing-size \
  children children-probe mount mount-probe holders holders-probe signature \
  partition-table signature-probe source-mount-probe source-pool source-nested \
  source-nested-probe source-stat-probe source-du-probe small-capacity \
  mountpoint-confinement; do
  run_preflight_case "$refusal" fail
done
grep -q '^EVIDENCE_VERSION=3$' "$base_evidence"
grep -q '^SOURCE=direct$' "$base_evidence"
grep -q '^CAPACITY_CHECK=PASS$' "$base_evidence"

# Format-only preflight: without --source, only target identity and emptiness
# are checked. The evidence records SOURCE=none and no source fields.
run_preflight_case no-source pass no success
no_source_evidence=$tmp/no-source.evidence
grep -q '^SOURCE=none$' "$no_source_evidence"
grep -q '^CAPACITY_CHECK=NOT_APPLICABLE$' "$no_source_evidence"
grep -q '^TARGET_CLEAR=PASS$' "$no_source_evidence"
refute_grep '^SOURCE_' "$no_source_evidence"
refute_grep '^du ' "$tmp/no-source.log"
grep -q '^SOURCE=none' "$tmp/no-source.log.out"
for refusal in children signature holders missing-wwn; do
  run_preflight_case "no-source-$refusal" fail no "$refusal"
  [[ ! -e $tmp/no-source-$refusal.evidence ]]
done

# Readiness flags are string booleans. A probe that leaves one false without a
# counted FAIL or MANUAL must still refuse format readiness.
for gate_flags in inspect_target inspect_source check_capacity; do
  gate_evidence=$tmp/gate-flags-$gate_flags.evidence
  gate_log=$tmp/gate-flags-$gate_flags.log
  rm -f "$gate_evidence" "$gate_log"
  if CASE=success GATE_STUB=$gate_flags LOG=$gate_log EVIDENCE=$gate_evidence \
    FIXTURE_DESCRIPTOR=$descriptor PATH="$fake_bin:$PATH" \
    bash -c '
      set -euo pipefail
      source "$SCRIPT"
      fixture_setup
      case $GATE_STUB in
        inspect_target) inspect_target() { :; } ;;
        inspect_source) inspect_source() { SOURCE_APPARENT_BYTES=100; } ;;
        check_capacity) check_capacity() { :; } ;;
      esac
      parse_args preflight --descriptor "$FIXTURE_DESCRIPTOR" --source "$SOURCE" --evidence "$EVIDENCE"
      preflight
    ' >"$gate_log.out" 2>&1; then
    gate_rc=0
  else
    gate_rc=$?
  fi
  if [[ $gate_rc -ne 2 || -e $gate_evidence ]] ||
    ! grep -q '^FORMAT_READINESS=NOT_READY$' "$gate_log.out"; then
    cat "$gate_log.out" >&2
    echo "gate-flags/$gate_flags: expected FORMAT_READINESS=NOT_READY, exit 2, no evidence (rc=$gate_rc)" >&2
    exit 1
  fi
done

source_token=
while IFS='=' read -r key value; do

  [[ $key == SOURCE_TOKEN ]] && source_token=$value
done < "$base_evidence"
export CONFIRM=$confirm EVIDENCE=$base_evidence
quiescence=$tmp/quiescence
printf 'EVIDENCE_VERSION=1\nSOURCE_TOKEN=%s\nWRITERS=STOPPED\n' "$source_token" > "$quiescence"

run_format_case() {
  local name=$1 expected=$2 approve=${3-yes} evidence=${4-$base_evidence}
  local log=$tmp/format-$name.log rc=0
  rm -f "$log" "$log.partition"
  if CASE=$name LOG=$log EVIDENCE=$evidence PATH="$fake_bin:$PATH" APPROVE=$approve \
    bash -c '
      set -euo pipefail
      source "$SCRIPT"
      fixture_setup
      if [[ ${APPROVE-yes} == yes ]]; then
        parse_args format --descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE" \
          --confirm-target "$CONFIRM" --approve-format
      else
        parse_args format --descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE" \
          --confirm-target "$CONFIRM"
      fi
      format_disk
    ' >"$log.out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ $expected == pass ]]; then
    [[ $rc -eq 0 ]] || { cat "$log.out" >&2; return 1; }
  else
    [[ $rc -ne 0 ]] || { echo "format fixture unexpectedly passed: $name" >&2; return 1; }
    if [[ $name == sgdisk-fail ]]; then
      # This case deliberately reaches sgdisk; its failure must still stop
      # before cryptsetup.
      grep -q '^sgdisk ' "$log" && ! grep -q '^cryptsetup ' "$log"
    else
      assert_no_format_mutator "$log"
    fi
  fi
}
stale_evidence=$tmp/stale.evidence
sed 's/^TARGET_TOKEN=.*/TARGET_TOKEN=stale-token/' "$base_evidence" > "$stale_evidence"
run_format_case stale-evidence fail yes "$stale_evidence"

export CONFIRM=$confirm EVIDENCE=$base_evidence
for refusal in \
  missing-approval confirmation-mismatch partition-alias missing-serial \
  missing-wwn missing-size children children-probe mount mount-probe holders \
  holders-probe signature signature-probe key-missing source-pool \
  source-du-probe; do
  if [[ $refusal == confirmation-mismatch ]]; then
    CONFIRM=wrong-confirmation run_format_case "$refusal" fail
    CONFIRM=$confirm
  else
    if [[ $refusal == missing-approval ]]; then
      run_format_case "$refusal" fail no
    else
      run_format_case "$refusal" fail
    fi
  fi
done
run_format_case sgdisk-fail fail
run_format_case success pass

# SOURCE=none evidence authorizes format without probing any source.
run_format_case no-source-format pass yes "$no_source_evidence"
grep -q '^cryptsetup luksFormat' "$tmp/format-no-source-format.log"
refute_grep '^du ' "$tmp/format-no-source-format.log"
# Tampered SOURCE=none evidence that carries a source field is refused.
{ cat "$no_source_evidence"; printf 'SOURCE_PATH=%s\n' "$source_dir"; } > "$tmp/no-source-tampered.evidence"
run_format_case no-source-tampered fail yes "$tmp/no-source-tampered.evidence"
grep -q 'must not carry SOURCE_PATH' "$tmp/format-no-source-tampered.log.out"
# Version 2 evidence, written before SOURCE existed, still means a direct source.
grep -v '^SOURCE=' "$base_evidence" | sed 's/^EVIDENCE_VERSION=3$/EVIDENCE_VERSION=2/' > "$tmp/v2.evidence"
run_format_case v2-evidence pass yes "$tmp/v2.evidence"
{ cat "$tmp/v2.evidence"; printf 'SOURCE=none\n'; } > "$tmp/v2-with-source.evidence"
run_format_case v2-evidence-with-source fail yes "$tmp/v2-with-source.evidence"

run_copy_case() {
  local name=$1 expected=$2 approve=${3-yes}
  local receipt=$tmp/receipt-$name log=$tmp/copy-$name.log rc=0
  rm -f "$receipt" "$log" "$log.partition"
  rm -rf "$mountpoint/.seed" "$mountpoint/unsafe"
  [[ $name != destination-nonempty ]] || : > "$mountpoint/unsafe"
  if CASE=$name LOG=$log PATH="$fake_bin:$PATH" APPROVE=$approve RECEIPT=$receipt EVIDENCE=${COPY_EVIDENCE-$EVIDENCE} \
    bash -c '
      set -euo pipefail
      source "$SCRIPT"
      fixture_setup
      if [[ ${APPROVE-yes} == yes ]]; then
        parse_args copy --descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE" \
          --quiescence-evidence "$QUIESCENCE" --receipt "$RECEIPT" --approve-copy
      else
        parse_args copy --descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE" \
          --quiescence-evidence "$QUIESCENCE" --receipt "$RECEIPT"
      fi
      copy_disk
    ' >"$log.out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ $expected == pass ]]; then
    [[ $rc -eq 0 && -s $receipt ]] || { cat "$log.out" >&2; return 1; }
    [[ ! -e $mountpoint/unsafe ]]
    assert_no_format_mutator "$log"
  else
    [[ $rc -ne 0 ]] || { echo "copy fixture unexpectedly passed: $name" >&2; return 1; }
    assert_no_format_mutator "$log"
  fi
}

export QUIESCENCE=$quiescence RECEIPT=$tmp/receipt-success
run_copy_case missing-approval fail no
printf 'EVIDENCE_VERSION=1\nSOURCE_TOKEN=wrong\nWRITERS=STOPPED\n' > "$tmp/bad-quiescence"
QUIESCENCE=$tmp/bad-quiescence run_copy_case stale-quiescence fail
QUIESCENCE=$quiescence run_copy_case destination-nonempty fail
QUIESCENCE=$quiescence run_copy_case source-pool fail
QUIESCENCE=$quiescence run_copy_case rsync-copy-fail fail
QUIESCENCE=$quiescence run_copy_case rsync-verify-diff fail
QUIESCENCE=$quiescence COPY_EVIDENCE=$no_source_evidence run_copy_case no-source-copy fail
grep -q 'records SOURCE=none' "$tmp/copy-no-source-copy.log.out"
QUIESCENCE=$quiescence run_copy_case success pass
grep -q "^SEED_ROOT=$mountpoint/.seed\$" "$tmp/receipt-success"

run_quiesce_case() {
  local name=$1 expected=$2 writers=${3-stopped}
  local quiescence_out=$tmp/quiescence-$name log=$tmp/quiesce-$name.log rc=0
  rm -f "$quiescence_out" "$log"
  rm -rf "$mountpoint/.seed"
  [[ $name != quiesce-exists ]] || printf 'EVIDENCE_VERSION=2\nWRITERS=STOPPED\n' > "$quiescence_out"
  if CASE=$name LOG=$log PATH="$fake_bin:$PATH" QUIESCENT=$quiescence_out WRITERS=$writers \
    bash -c '
      set -euo pipefail
      source "$SCRIPT"
      fixture_setup
      args=(--descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE"
        --quiescence-evidence "$QUIESCENT")
      case $WRITERS in
        stopped) args+=(--writers-stopped) ;;
        independent) args+=(--independent-consistency) ;;
        none) ;;
      esac
      parse_args quiesce "${args[@]}"
      quiesce_source
    ' >"$log.out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ $expected == pass ]]; then
    [[ $rc -eq 0 && -s $quiescence_out ]] || { cat "$log.out" >&2; return 1; }
    LAST_QUIESCENCE=$quiescence_out
  else
    [[ $rc -ne 0 ]] || { echo "quiesce fixture unexpectedly passed: $name" >&2; return 1; }
    [[ $name == quiesce-exists || ! -e $quiescence_out ]]
  fi
}

# v2 quiescence re-stabilizes a FUSE-remounted source (new st_dev/UUID, same
# filesystem identity) and copy accepts the fresh token.
run_quiesce_case source-remounted pass
grep -q '^EVIDENCE_VERSION=2$' "$LAST_QUIESCENCE"
grep -q '^WRITERS=STOPPED$' "$LAST_QUIESCENCE"
grep -q 'SOURCE_ST_DEV preflight=400 current=777' "$tmp/quiesce-source-remounted.log.out"
grep -q 'SOURCE_UUID preflight=- current=NEWUUID-9' "$tmp/quiesce-source-remounted.log.out"
QUIESCENCE=$LAST_QUIESCENCE run_copy_case source-remounted pass

# v2 still pins filesystem identity, capacity, and single-shot evidence.
for refusal in source-different-device source-different-fstype source-moved   destination-small; do
  run_quiesce_case "$refusal" fail
done
run_quiesce_case quiesce-exists fail
run_quiesce_case no-assertion fail none
EVIDENCE=$no_source_evidence run_quiesce_case no-source-quiesce fail
grep -q 'records SOURCE=none' "$tmp/quiesce-no-source-quiesce.log.out"
run_quiesce_case independent pass

# A source that drifts after v2 quiescence is refused at copy.
run_quiesce_case pre-drift pass
QUIESCENCE=$LAST_QUIESCENCE run_copy_case source-remounted fail

# v1 quiescence keeps the old binding: it still refuses the remounted source.
QUIESCENCE=$quiescence run_copy_case source-remounted fail
