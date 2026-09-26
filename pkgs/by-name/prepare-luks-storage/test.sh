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
    if [[ ${CASE-} == children-probe ]]; then exit 2; fi
    if [[ ${CASE-} == children || ${CASE-} == holders-probe-child ]]; then
      printf '/dev/fake-part1 part\n'
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
if [[ $* == "-c %d -- $MOUNTPOINT/"* ]]; then
  if [[ ${CASE-} == cross-device && $* == *"/medialibrary/tv" ]]; then
    printf '999\n'
  else
    printf '401\n'
  fi
  exit 0
fi
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
  holders_for() {
    case ${CASE-} in
      holders-probe|holders-probe-root) [[ $1 == /dev/fake-disk ]] && return 1 ;;
      holders-probe-child) [[ $1 == /dev/fake-part1 ]] && return 1 ;;
    esac
    [[ ${CASE-} == holders && $1 == /dev/fake-disk ]] && printf 'fixture-holder\n'
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
  local rc=0
  rm -f "$evidence" "$log" "$log.partition"
  [[ $name != wrong-identity ]] || : > "$log.partition"
  if CASE=$case_name LOG=$log EVIDENCE=$evidence FIXTURE_DESCRIPTOR=$descriptor PATH="$fake_bin:$PATH" \
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
  children children-probe mount mount-probe holders holders-probe \
  holders-probe-root holders-probe-child signature \
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

# The wrong-identity fixture resolves the declared partition to one disk while
# its whole-disk by-id alias resolves to another, so the identity gate is the
# refusal — not descriptor parsing.
grep -q 'declared by-id identity changed' "$tmp/wrong-identity.log.out"
# A failed holder probe on the root or on a child must surface as MANUAL, not
# a silent "no holders" pass.
grep -q 'holder inspection failed' "$tmp/holders-probe-root.log.out"
grep -q 'holder inspection failed' "$tmp/holders-probe-child.log.out"

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

# normalize: same-filesystem renames of the verified seed into the target
# layout. Real mv/mkdir/rmdir run on the fixture directory; the receipt from
# the successful copy case above is a version 2 receipt.
v2_receipt=$tmp/receipt-success
grep -q '^COPY_RECEIPT_VERSION=2$' "$v2_receipt"
grep -q "^EVIDENCE_SHA256=$(sha256sum -- "$base_evidence" | cut -d' ' -f1)\$" "$v2_receipt"
grep -q "^SEED_ROOT=$mountpoint/.seed\$" "$v2_receipt"
# Exactly the format written by the copy tool before receipts carried digests
# and before staging moved to .seed: the staging root has a legacy name.
v1_receipt=$tmp/receipt-v1
cat > "$v1_receipt" <<EOF
COPY_RECEIPT_VERSION=1
SOURCE_PATH=$source_dir
SOURCE_TOKEN=$source_token
TARGET_MOUNTPOINT=$mountpoint
TARGET_UUID=UUID-4
TARGET_ST_DEV=401
SEED_ROOT=$mountpoint/.media4-seed
COPY_VERIFIED=PASS
EOF

normalize_fixture() {
  local seed=${1-.seed} name
  local old_root=$mountpoint/$seed/medialibrary
  rm -rf "$mountpoint"
  mkdir -p "$mountpoint"
  for name in dewey-incoming downloads movies staging tv; do
    mkdir -p "$old_root/$name"
    chmod 0755 "$old_root/$name"
    printf '%s\n' "$name" > "$old_root/$name/marker"
  done
  chmod 0775 "$old_root/movies" "$old_root/tv"
}

# Names, types, modes, owners, sizes, and mtimes of the fixture tree. Block
# counts are left out: some filesystems (ZFS) update them after the write.
tree_state() {
  find "$mountpoint" -printf '%P %y %m %U:%G %s %T@\n' | LC_ALL=C sort
}

run_normalize_case() {
  local name=$1 expected=$2 receipt_source=${3-$v2_receipt} approve=${4-yes}
  local receipt=$tmp/norm-$name.receipt log=$tmp/normalize-$name.log rc=0
  local evidence=${NORMALIZE_EVIDENCE-$base_evidence} before after
  rm -f "$receipt" "$receipt.normalized" "$log"
  [[ $receipt_source == none ]] || cp "$receipt_source" "$receipt"
  before=$(tree_state)
  if CASE=$name LOG=$log PATH="$fake_bin:$PATH" APPROVE=$approve RECEIPT=$receipt EVIDENCE=$evidence \
    LAYOUT_ARG=${NORMALIZE_LAYOUT-legacy-medialibrary} \
    bash -c '
      set -euo pipefail
      source "$SCRIPT"
      fixture_setup
      args=(--descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE" --receipt "$RECEIPT")
      [[ $LAYOUT_ARG == none ]] || args+=(--layout "$LAYOUT_ARG")
      [[ $APPROVE != yes ]] || args+=(--approve-normalize)
      parse_args normalize "${args[@]}"
      normalize_disk
    ' >"$log.out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  after=$(tree_state)
  if [[ $expected == pass ]]; then
    [[ $rc -eq 0 && -s $receipt.normalized ]] || { cat "$log.out" >&2; return 1; }
  else
    [[ $rc -ne 0 ]] || { cat "$log.out" >&2; echo "normalize fixture unexpectedly passed: $name" >&2; return 1; }
    [[ $before == "$after" ]] || { echo "normalize refusal changed the destination: $name" >&2; return 1; }
    [[ ! -e $receipt.normalized ]] || { echo "normalize refusal wrote a receipt: $name" >&2; return 1; }
  fi
  assert_no_format_mutator "$log"
}

entries_of() {
  (
    shopt -s dotglob nullglob
    cd -- "$1"
    local names=(*)
    IFS=,
    printf '%s' "${names[*]}"
  )
}

assert_normalized_layout() {
  local receipt=$1
  [[ $(LC_ALL=C entries_of "$mountpoint") == downloads,legacy,library ]]
  [[ $(LC_ALL=C entries_of "$mountpoint/library") == movies,tv ]]
  [[ $(LC_ALL=C entries_of "$mountpoint/legacy") == dewey-incoming,staging ]]
  [[ $(cat "$mountpoint/library/movies/marker") == movies ]]
  [[ $(cat "$mountpoint/library/tv/marker") == tv ]]
  [[ $(cat "$mountpoint/downloads/marker") == downloads ]]
  [[ $(cat "$mountpoint/legacy/dewey-incoming/marker") == dewey-incoming ]]
  [[ $(cat "$mountpoint/legacy/staging/marker") == staging ]]
  [[ $(stat -c %a "$mountpoint/library") == 755 ]]
  [[ $(stat -c %a "$mountpoint/legacy") == 755 ]]
  [[ $(stat -c %a "$mountpoint/library/movies") == 775 ]]
  [[ $(stat -c %a "$mountpoint/library/tv") == 775 ]]
  [[ $(stat -c %a "$mountpoint/downloads") == 755 ]]
  [[ $(stat -c %a "$receipt.normalized") == 600 ]]
  grep -q '^NORMALIZED=PASS$' "$receipt.normalized"
  grep -q '^ROOT_ENTRIES=downloads,legacy,library$' "$receipt.normalized"
  grep -q '^LIBRARY_ENTRIES=movies,tv$' "$receipt.normalized"
  grep -q '^LEGACY_ENTRIES=dewey-incoming,staging$' "$receipt.normalized"
  grep -q '^LAYOUT=legacy-medialibrary$' "$receipt.normalized"
}

# Success with a version 2 receipt, then every re-run refuses.
normalize_fixture
run_normalize_case success pass
assert_normalized_layout "$tmp/norm-success.receipt"
grep -q '^LEGACY_ENTRIES=dewey-incoming,staging$' "$tmp/normalize-success.log.out"
# Same receipt: the normalize receipt already exists.
cp "$tmp/norm-success.receipt.normalized" "$tmp/success.normalized.keep"
if CASE=success LOG=$tmp/rerun.log PATH="$fake_bin:$PATH" RECEIPT=$tmp/norm-success.receipt \
  bash -c 'source "$SCRIPT"; fixture_setup
    parse_args normalize --descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE" \
      --receipt "$RECEIPT" --layout legacy-medialibrary --approve-normalize
    normalize_disk' >"$tmp/rerun.log.out" 2>&1; then
  echo "normalize re-run with the same receipt unexpectedly passed" >&2
  exit 1
fi
grep -q 'normalize receipt already exists' "$tmp/rerun.log.out"
cmp -s "$tmp/norm-success.receipt.normalized" "$tmp/success.normalized.keep"
# Fresh receipt path: the normalized layout is not the untouched seed.
run_normalize_case rerun-after-success fail
grep -q 'destination root must contain only .seed; found: downloads,legacy,library' \
  "$tmp/normalize-rerun-after-success.log.out"
assert_normalized_layout "$tmp/norm-success.receipt"

grep -q "^SEED_ROOT=$mountpoint/.seed\$" "$tmp/norm-success.receipt.normalized"

# Legacy staging root: a version 1 receipt whose SEED_ROOT is .media4-seed,
# checked against version 2 preflight evidence (no SOURCE field). This is the
# state of a copy started with an earlier build; normalize takes the staging
# root from the receipt, not from a constant.
normalize_fixture .media4-seed
NORMALIZE_EVIDENCE=$tmp/v2.evidence run_normalize_case legacy-seed-receipt pass "$v1_receipt"
assert_normalized_layout "$tmp/norm-legacy-seed-receipt.receipt"
grep -q "^SEED_ROOT=$mountpoint/.media4-seed\$" "$tmp/norm-legacy-seed-receipt.receipt.normalized"
[[ ! -e $mountpoint/.media4-seed ]]
# The same legacy receipt against current (version 3) evidence.
normalize_fixture .media4-seed
run_normalize_case legacy-receipt pass "$v1_receipt"
assert_normalized_layout "$tmp/norm-legacy-receipt.receipt"
# The receipt names the legacy root, but the disk holds .seed: refuse.
normalize_fixture
run_normalize_case legacy-receipt-wrong-seed fail "$v1_receipt"
grep -q 'destination root must contain only .media4-seed; found: .seed' \
  "$tmp/normalize-legacy-receipt-wrong-seed.log.out"
# SEED_ROOT must be a direct child of the descriptor mountpoint.
for seed_root in "$mountpoint/nested/.seed" "$tmp/.seed" "$mountpoint" "$mountpoint/.." "$mountpoint/"; do
  normalize_fixture
  sed "s#^SEED_ROOT=.*#SEED_ROOT=$seed_root#" "$v1_receipt" > "$tmp/receipt-v1-bad-seed"
  run_normalize_case bad-seed-root fail "$tmp/receipt-v1-bad-seed"
  grep -q 'seed root is not a direct child' "$tmp/normalize-bad-seed-root.log.out"
done

# Layout selection: required, and unknown names are refused before any change.
normalize_fixture
NORMALIZE_LAYOUT=none run_normalize_case missing-layout fail
grep -q 'normalize requires --layout' "$tmp/normalize-missing-layout.log.out"
NORMALIZE_LAYOUT=flat run_normalize_case unknown-layout fail
grep -q 'unknown layout: flat' "$tmp/normalize-unknown-layout.log.out"
# SOURCE=none evidence never authorizes normalize.
NORMALIZE_EVIDENCE=$no_source_evidence run_normalize_case no-source-normalize fail
grep -q 'records SOURCE=none' "$tmp/normalize-no-source-normalize.log.out"

# Receipt refusals.
normalize_fixture
run_normalize_case missing-approval fail "$v2_receipt" no
run_normalize_case missing-receipt fail none
sed 's/^COPY_VERIFIED=PASS$/COPY_VERIFIED=FAIL/' "$v2_receipt" > "$tmp/receipt-failed"
run_normalize_case failed-receipt fail "$tmp/receipt-failed"
grep -v '^COPY_VERIFIED=' "$v2_receipt" > "$tmp/receipt-unverified"
run_normalize_case unverified-receipt fail "$tmp/receipt-unverified"
{ cat "$v2_receipt"; printf 'EXTRA=1\n'; } > "$tmp/receipt-unknown"
run_normalize_case unknown-receipt-field fail "$tmp/receipt-unknown"
{ cat "$v2_receipt"; printf 'COPY_VERIFIED=PASS\n'; } > "$tmp/receipt-duplicate"
run_normalize_case duplicate-receipt-field fail "$tmp/receipt-duplicate"
sed 's/^EVIDENCE_SHA256=.*/EVIDENCE_SHA256=0000/' "$v2_receipt" > "$tmp/receipt-other-evidence"
run_normalize_case other-evidence fail "$tmp/receipt-other-evidence"
grep -q 'bound to different preflight evidence' "$tmp/normalize-other-evidence.log.out"
normalize_fixture .media4-seed
sed 's/^TARGET_UUID=.*/TARGET_UUID=OTHER/' "$v1_receipt" > "$tmp/receipt-v1-other-uuid"
run_normalize_case legacy-receipt-other-uuid fail "$tmp/receipt-v1-other-uuid"
grep -q 'does not match mounted UUID' "$tmp/normalize-legacy-receipt-other-uuid.log.out"
sed "s#^SOURCE_PATH=.*#SOURCE_PATH=/elsewhere#" "$v1_receipt" > "$tmp/receipt-v1-other-source"
run_normalize_case legacy-receipt-other-source fail "$tmp/receipt-v1-other-source"
grep -q 'source path does not match' "$tmp/normalize-legacy-receipt-other-source.log.out"
normalize_fixture
NORMALIZE_EVIDENCE=$stale_evidence run_normalize_case stale-target fail
grep -q 'target identity no longer matches' "$tmp/normalize-stale-target.log.out"

# Layout refusals leave the destination untouched.
normalize_fixture
mkdir "$mountpoint/.seed/medialibrary/music"
run_normalize_case unexpected-extra-entry fail
grep -q 'found: dewey-incoming,downloads,movies,music,staging,tv' \
  "$tmp/normalize-unexpected-extra-entry.log.out"

normalize_fixture
rm -rf "$mountpoint/.seed/medialibrary/staging"
run_normalize_case unexpected-missing-entry fail
grep -q 'found: dewey-incoming,downloads,movies,tv' "$tmp/normalize-unexpected-missing-entry.log.out"

normalize_fixture
mkdir "$mountpoint/.seed/other"
run_normalize_case unexpected-seed-root fail
grep -q 'expected medialibrary, found: medialibrary,other' "$tmp/normalize-unexpected-seed-root.log.out"

normalize_fixture
rm -rf "$mountpoint/.seed/medialibrary/staging"
: > "$mountpoint/.seed/medialibrary/staging"
run_normalize_case entry-not-directory fail

normalize_fixture
rm -rf "$mountpoint/.seed/medialibrary/tv"
mkdir "$tmp/elsewhere-tv"
ln -s "$tmp/elsewhere-tv" "$mountpoint/.seed/medialibrary/tv"
run_normalize_case symlink-entry fail
grep -q 'unexpected symlink: .*/medialibrary/tv' "$tmp/normalize-symlink-entry.log.out"

normalize_fixture
run_normalize_case cross-device fail
grep -q 'different device (999, mountpoint 401)' "$tmp/normalize-cross-device.log.out"

# Existing destinations and a partially completed earlier run.
for existing in library legacy downloads; do
  normalize_fixture
  mkdir "$mountpoint/$existing"
  run_normalize_case "existing-$existing" fail
  grep -q "destination root must contain only .seed; found: .seed,$existing" \
    "$tmp/normalize-existing-$existing.log.out"
done
normalize_fixture
mkdir -m 0755 "$mountpoint/library" "$mountpoint/legacy"
mv -T "$mountpoint/.seed/medialibrary/movies" "$mountpoint/library/movies"
run_normalize_case partial-run fail
grep -q 'found: .seed,legacy,library (an earlier normalize may have stopped partway' \
  "$tmp/normalize-partial-run.log.out"
