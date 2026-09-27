#!/usr/bin/env bash
# Disposable coverage for the direct-source migration gates. It sources the
# real gate logic and fakes only block-device and mount probes and the format
# mutators. Copy and verify run the real rsync and python3 on a small fixture
# tree, and every external command line the tool uses is run through the real
# binary (or its --help) so option errors fail here. It never opens a block
# device.
set -Eeuo pipefail
trap 'echo "test.sh: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# Real tools, resolved before the fake directory is put on PATH.
REAL_RSYNC=$(command -v rsync) || { echo "test.sh needs the real rsync on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "test.sh needs the real python3 on PATH" >&2; exit 1; }
export REAL_RSYNC

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
  "-dnro PKNAME -- "*)
    if [[ ${CASE-} == partition-parent && $* == *fake-part1* ]]; then
      printf 'other-disk\n'
    else
      printf 'fake-disk\n'
    fi
    ;;
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
if [[ $* == "-rn -S /dev/fake-part1 -o TARGET" ]]; then
  [[ ${CASE-} == partition-mount ]] || exit 1
  printf '/mnt/fakeroot\n'
  exit 0
fi
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
elif [[ ${CASE-} == partition-signature && $* == *fake-part1* ]]; then
  printf 'xfs\n'
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
  printf '401\n'
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

# rsync is the real binary. The wrapper only logs, injects a transfer
# failure, or corrupts one byte after a real transfer, so option and behaviour
# errors still come from rsync itself.
cat > "$fake_bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'rsync %s\n' "$*" >> "$LOG"
dry_run=false
for arg in "$@"; do [[ $arg != --dry-run ]] || dry_run=true; done
if [[ ${CASE-} == rsync-copy-fail && $dry_run == false ]]; then
  echo "rsync: simulated transfer failure" >&2
  exit 23
fi
status=0
"$REAL_RSYNC" "$@" || status=$?
if [[ ${CASE-} == rsync-verify-diff && $dry_run == false && $status == 0 ]]; then
  target=${!#}
  corrupt_one_byte "$target/medialibrary/tv/sparse.bin"
fi
exit "$status"
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

# Flip one byte in place and keep the size and mtime, so only a content
# checksum can see the change.
corrupt_one_byte() {
  local file=$1 stamp byte
  stamp=$(mktemp)
  touch -r "$file" "$stamp"
  byte=$(head -c 1 "$file")
  if [[ $byte == X ]]; then byte=Y; else byte=X; fi
  printf '%s' "$byte" | dd of="$file" bs=1 count=1 conv=notrunc status=none
  touch -r "$stamp" "$file"
  rm -f "$stamp"
}
export -f corrupt_one_byte

# Small source tree: a file with a hardlink
# peer in another directory, a sparse file, a symlink, an empty directory, and
# a user xattr where the filesystem allows it.
lib=$source_dir/medialibrary
mkdir -p "$lib/movies" "$lib/tv" "$lib/downloads" "$lib/staging" "$lib/dewey-incoming"
printf 'hello migration\n' > "$lib/movies/film.mkv"
ln "$lib/movies/film.mkv" "$lib/downloads/film.mkv"
truncate -s 8M "$lib/tv/sparse.bin"
printf 'z' | dd of="$lib/tv/sparse.bin" bs=1 seek=$((8 * 1024 * 1024 - 1)) conv=notrunc status=none
ln -s ../movies/film.mkv "$lib/staging/link"
if (($(stat -c %b "$lib/tv/sparse.bin") * 512 >= 8 * 1024 * 1024)); then
  echo "note: the fixture filesystem allocated the sparse file; sparse preservation is not exercised" >&2
fi
XATTR_FIXTURE=false
if python3 -c 'import os, sys; os.setxattr(sys.argv[1], "user.homelab", b"fixture")' \
  "$lib/movies/film.mkv" 2>/dev/null; then
  XATTR_FIXTURE=true
else
  echo "note: the fixture filesystem refuses user xattrs; xattr preservation is not exercised" >&2
fi

# Names, types, modes, owners, sizes, and mtimes of the fixture tree. Block
# counts are left out: some filesystems (ZFS) update them after the write.
tree_state() {
  find "$mountpoint" -printf '%P %y %m %U:%G %s %T@\n' | LC_ALL=C sort
}

# Check a seed tree that real rsync wrote: content, hardlink peers, sparse
# representation, symlink, and xattr.
assert_seed_matches_source() {
  local seed=$1/medialibrary
  cmp -s "$lib/movies/film.mkv" "$seed/movies/film.mkv"
  [[ $(stat -c %i "$seed/movies/film.mkv") == "$(stat -c %i "$seed/downloads/film.mkv")" ]]
  [[ $(stat -c %s "$seed/tv/sparse.bin") == $((8 * 1024 * 1024)) ]]
  # A sparse source must stay sparse. Some filesystems (APFS) allocate the
  # source fully; then there is no hole to preserve.
  if (($(stat -c %b "$lib/tv/sparse.bin") * 512 < 8 * 1024 * 1024)); then
    (($(stat -c %b "$seed/tv/sparse.bin") * 512 < 8 * 1024 * 1024))
  fi
  [[ $(readlink "$seed/staging/link") == ../movies/film.mkv ]]
  [[ -d $seed/dewey-incoming ]]
  if [[ $XATTR_FIXTURE == true ]]; then
    [[ $(python3 -c 'import os, sys; print(os.getxattr(sys.argv[1], "user.homelab").decode())' \
      "$seed/movies/film.mkv") == fixture ]]
  fi
}

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
    [[ ${CASE-} == partition-holders && $1 == /dev/fake-part1 ]] && printf 'fixture-holder\n' 
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
  local status=0
  grep -q -- "$1" "$2" || status=$?
  if ((status == 0)); then
    echo "unexpected match for '$1' in $2" >&2
    exit 1
  elif ((status != 1)); then
    echo "grep failed ($status) looking for '$1' in $2" >&2
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
    if [[ $name == sgdisk-fail || $name == partition-mount || $name == partition-holders || $name == partition-signature ]]; then
      # These cases deliberately reach sgdisk; the refusal must still stop
      # before cryptsetup luksFormat.
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

# A partition that appears with a mount, a holder, or a leftover signature is
# refused after sgdisk ran but before luksFormat writes it.
for refusal in partition-mount partition-holders partition-signature; do
  run_format_case "$refusal" fail
done
grep -q 'partition is mounted' "$tmp/format-partition-mount.log.out"
grep -q 'partition has holders' "$tmp/format-partition-holders.log.out"
grep -q 'has an existing signature' "$tmp/format-partition-signature.log.out"

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
  local receipt=${RECEIPT_OVERRIDE-$tmp/receipt-$name} log=$tmp/copy-$name.log rc=0
  rm -f "$log" "$log.partition"
  [[ $name == receipt-exists ]] || rm -f "$receipt"
  [[ $name != receipt-exists ]] || : > "$receipt"
  rm -rf "$mountpoint/migration" "$mountpoint/unsafe"
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
grep -q 'copy rsync failed (exit 23)' "$tmp/copy-rsync-copy-fail.log.out"
[[ ! -e $tmp/receipt-rsync-copy-fail ]]
# Real transfer, then one byte of the seed is flipped: the real checksum dry
# run must report it, print the differing entry, and write no receipt.
QUIESCENCE=$quiescence run_copy_case rsync-verify-diff fail
grep -q 'copy verification found missing or changed entries' "$tmp/copy-rsync-verify-diff.log.out"
grep -q 'medialibrary/tv/sparse.bin' "$tmp/copy-rsync-verify-diff.log.out"
[[ ! -e $tmp/receipt-rsync-verify-diff ]]
QUIESCENCE=$quiescence COPY_EVIDENCE=$no_source_evidence run_copy_case no-source-copy fail
grep -q 'records SOURCE=none' "$tmp/copy-no-source-copy.log.out"
# A pre-existing or relative receipt path is refused before the staging tree
# or any copied bytes are created.
QUIESCENCE=$quiescence run_copy_case receipt-exists fail
grep -q 'copy receipt already exists' "$tmp/copy-receipt-exists.log.out"
[[ ! -e $mountpoint/migration ]]
QUIESCENCE=$quiescence RECEIPT_OVERRIDE=receipt-relative.out run_copy_case receipt-relative fail
unset RECEIPT_OVERRIDE
grep -q 'evidence path must be absolute' "$tmp/copy-receipt-relative.log.out"
[[ ! -e $mountpoint/migration ]]

QUIESCENCE=$quiescence run_copy_case success pass
grep -q "^SEED_ROOT=$mountpoint/migration\$" "$tmp/receipt-success"
grep -q '^VERIFIED_BY=copy$' "$tmp/receipt-success"
# End to end with the real rsync and python3: the copy preserved the tree.
assert_seed_matches_source "$mountpoint/migration"
grep -q -- '--itemize-changes' "$tmp/copy-success.log"

run_quiesce_case() {
  local name=$1 expected=$2 writers=${3-stopped}
  local quiescence_out=$tmp/quiescence-$name log=$tmp/quiesce-$name.log rc=0
  rm -f "$quiescence_out" "$log"
  rm -rf "$mountpoint/migration"
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
v2_quiescence=$LAST_QUIESCENCE

# A source that drifts after v2 quiescence is refused at copy.
run_quiesce_case pre-drift pass
drift_quiescence=$LAST_QUIESCENCE
QUIESCENCE=$LAST_QUIESCENCE run_copy_case source-remounted fail

# v1 quiescence keeps the old binding: it still refuses the remounted source.
QUIESCENCE=$quiescence run_copy_case source-remounted fail

# verify: recover a copy whose transfer finished but whose verification failed
# or never ran. The seed is written by the real rsync; verify runs the real
# checksum dry run and python3 tree check.
prepare_seed() {
  local name=$1
  rm -rf "$mountpoint"
  mkdir -p "$mountpoint/$name"
  "$REAL_RSYNC" -aHAXS --numeric-ids -- "$source_dir"/ "$mountpoint/$name"/
}

run_verify_case() {
  local name=$1 expected=$2 case_name=${3-$1}
  local receipt=$tmp/verify-$name.receipt log=$tmp/verify-$name.log rc=0 before after
  rm -f "$log"
  [[ $name == receipt-exists ]] || rm -f "$receipt"
  before=$(tree_state)
  if CASE=$case_name LOG=$log PATH="$fake_bin:$PATH" RECEIPT=$receipt \
    EVIDENCE=${VERIFY_EVIDENCE-$base_evidence} QUIESCENCE=${VERIFY_QUIESCENCE-$quiescence} \
    APPROVE=${VERIFY_APPROVE-yes} HOOK=${VERIFY_HOOK-} bash -c '
      set -euo pipefail
      source "$SCRIPT"
      fixture_setup
      # Another run or operator acts while this verification is running.
      if [[ -n $HOOK ]]; then
        eval "real_verify_tree() $(declare -f verify_tree | tail -n +2)"
        verify_tree() {
          real_verify_tree
          case $HOOK in
            receipt-appears) printf "another run\n" > "$RECEIPT" ;;
            evidence-replaced) printf "\n" >> "$EVIDENCE" ;;
          esac
        }
      fi
      args=(--descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE"
        --quiescence-evidence "$QUIESCENCE" --receipt "$RECEIPT")
      [[ $APPROVE != yes ]] || args+=(--approve-verify)
      parse_args verify "${args[@]}"
      verify_disk
    ' >"$log.out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  after=$(tree_state)
  [[ $before == "$after" ]] || { echo "verify changed the destination: $name" >&2; return 1; }
  assert_no_format_mutator "$log"
  if [[ $expected == pass ]]; then
    [[ $rc -eq 0 && -s $receipt ]] || { cat "$log.out" >&2; return 1; }
    [[ $(stat -c %a "$receipt") == 600 ]]
    grep -q '^COPY_RECEIPT_VERSION=2$' "$receipt"
    grep -q '^COPY_VERIFIED=PASS$' "$receipt"
    grep -q '^VERIFIED_BY=verify$' "$receipt"
    # verify never writes: rsync ran only as a dry run.
    refute_grep '^rsync .*-aHAXS --numeric-ids --info=progress2' "$log"
  else
    [[ $rc -ne 0 ]] || { cat "$log.out" >&2; echo "verify fixture unexpectedly passed: $name" >&2; return 1; }
    if [[ $name != receipt-exists && $name != receipt-appears ]]; then
      [[ ! -e $receipt ]] || { echo "verify refusal wrote a receipt: $name" >&2; return 1; }
    fi
  fi
}

prepare_seed migration
run_verify_case seed pass
grep -q "^SEED_ROOT=$mountpoint/migration\$" "$tmp/verify-seed.receipt"
grep -q -- '--itemize-changes' "$tmp/verify-seed.log"
# Success with version 2 quiescence.
VERIFY_QUIESCENCE=$v2_quiescence run_verify_case v2-quiescence pass
# Success with version 2 preflight evidence (no SOURCE field), as on a host
# that ran preflight with an earlier build.
VERIFY_EVIDENCE=$tmp/v2.evidence run_verify_case v2-evidence pass
# A receipt already exists: refuse and leave it untouched.
printf 'COPY_RECEIPT_VERSION=2\n' > "$tmp/verify-receipt-exists.receipt"
run_verify_case receipt-exists fail
grep -q 'copy receipt already exists' "$tmp/verify-receipt-exists.log.out"
[[ $(cat "$tmp/verify-receipt-exists.receipt") == COPY_RECEIPT_VERSION=2 ]]
# Anything besides the one migration tree: refuse.
prepare_seed migration
: > "$mountpoint/extra"
run_verify_case extra-entry fail
grep -q 'must contain only migration; found: extra,migration' "$tmp/verify-extra-entry.log.out"
# A staging tree under another name is not verified.
prepare_seed .seed
run_verify_case other-name fail
grep -q 'must contain only migration; found: .seed' "$tmp/verify-other-name.log.out"
rm -rf "$mountpoint"
mkdir -p "$mountpoint"
run_verify_case empty-destination fail
grep -q 'found: <empty>' "$tmp/verify-empty-destination.log.out"
# The source changed after quiescence: refuse before reading the seed.
prepare_seed migration
VERIFY_QUIESCENCE=$drift_quiescence run_verify_case source-changed fail source-remounted
grep -q 'source changed after quiescence evidence' "$tmp/verify-source-changed.log.out"
refute_grep '^rsync ' "$tmp/verify-source-changed.log"
# One byte differs in the seed (same size and mtime): the checksum dry run
# must catch it, list the entry, and write no receipt.
prepare_seed migration
corrupt_one_byte "$mountpoint/migration/medialibrary/tv/sparse.bin"
run_verify_case checksum-differs fail
grep -q 'copy verification found missing or changed entries' "$tmp/verify-checksum-differs.log.out"
grep -q 'medialibrary/tv/sparse.bin' "$tmp/verify-checksum-differs.log.out"
# Missing approval and SOURCE=none evidence are refused.
prepare_seed migration
VERIFY_APPROVE=no run_verify_case missing-approval fail
grep -q 'verify requires --approve-verify' "$tmp/verify-missing-approval.log.out"
VERIFY_EVIDENCE=$no_source_evidence run_verify_case no-source fail
grep -q 'records SOURCE=none' "$tmp/verify-no-source.log.out"
# A receipt that another run publishes while this one verifies is refused,
# never replaced.
prepare_seed migration
VERIFY_HOOK=receipt-appears run_verify_case receipt-appears fail
grep -q 'appeared during this operation' "$tmp/verify-receipt-appears.log.out"
[[ $(cat "$tmp/verify-receipt-appears.receipt") == "another run" ]]
# Preflight evidence replaced while verification runs: record nothing.
cp "$base_evidence" "$tmp/replaced.evidence"
VERIFY_EVIDENCE=$tmp/replaced.evidence VERIFY_HOOK=evidence-replaced \
  run_verify_case evidence-replaced fail
grep -q 'preflight evidence changed during this operation' "$tmp/verify-evidence-replaced.log.out"

# The tree check compares hardlink peer groups on both sides, including a link
# that exists only in the copy between two files with identical bytes and
# metadata.
tree_check() {
  TREE_SOURCE=$1 TREE_COPY=$2 bash -c '
    set -euo pipefail
    source "$SCRIPT"
    SOURCE_PATH=$TREE_SOURCE
    SEED_ROOT=$TREE_COPY
    verify_tree
  ' >"$tmp/tree-check.out" 2>&1
}
links=$tmp/hardlink-check
rm -rf "$links"
mkdir -p "$links/source"
printf 'identical bytes\n' > "$links/source/a"
printf 'identical bytes\n' > "$links/source/b"
touch -r "$links/source/a" "$links/source/b"
"$REAL_RSYNC" -aHAXS --numeric-ids -- "$links/source"/ "$links/copy"/
tree_check "$links/source" "$links/copy" || { cat "$tmp/tree-check.out" >&2; exit 1; }
ln -f "$links/copy/a" "$links/copy/b"
if tree_check "$links/source" "$links/copy"; then
  echo "verification accepted a hardlink that exists only in the copy" >&2
  exit 1
fi

# read_copy_receipt: the strict reader a disk-specific classification step
# sources before it renames anything. The receipt from the successful copy
# case above is the reference.
v2_receipt=$tmp/receipt-success
grep -q '^COPY_RECEIPT_VERSION=2$' "$v2_receipt"
grep -q "^EVIDENCE_SHA256=$(sha256sum -- "$base_evidence" | cut -d' ' -f1)\$" "$v2_receipt"

run_receipt_case() {
  local name=$1 expected=$2 receipt=$3
  local log=$tmp/receipt-$name.log rc=0
  rm -f "$log"
  if CASE=${RECEIPT_CASE-success} LOG=$log PATH="$fake_bin:$PATH" RECEIPT=$receipt \
    EVIDENCE=${RECEIPT_EVIDENCE-$base_evidence} bash -c '
      set -euo pipefail
      source "$SCRIPT"
      fixture_setup
      parse_args read --descriptor "$FIXTURE_DESCRIPTOR" --evidence "$EVIDENCE" --receipt "$RECEIPT"
      read_descriptor
      read_evidence
      inspect_destination_mount
      read_copy_receipt
      printf "READ_SEED_ROOT=%s\n" "$RECEIPT_SEED_ROOT"
    ' >"$log.out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ $expected == pass ]]; then
    [[ $rc -eq 0 ]] || { cat "$log.out" >&2; return 1; }
  else
    [[ $rc -ne 0 ]] || { cat "$log.out" >&2; echo "receipt fixture unexpectedly passed: $name" >&2; return 1; }
  fi
  assert_no_format_mutator "$log"
}

run_receipt_case copy pass "$v2_receipt"
grep -q "^READ_SEED_ROOT=$mountpoint/migration\$" "$tmp/receipt-copy.log.out"
run_receipt_case verify pass "$tmp/verify-seed.receipt"
# The staging root is taken from the receipt, so one written by an earlier
# build under another direct child of the mountpoint is still readable.
sed "s#^SEED_ROOT=.*#SEED_ROOT=$mountpoint/.earlier-seed#" "$v2_receipt" > "$tmp/receipt-earlier-seed"
run_receipt_case earlier-seed pass "$tmp/receipt-earlier-seed"
grep -q "^READ_SEED_ROOT=$mountpoint/.earlier-seed\$" "$tmp/receipt-earlier-seed.log.out"
for seed_root in "$mountpoint/nested/migration" "$tmp/migration" "$mountpoint" "$mountpoint/.." "$mountpoint/"; do
  sed "s#^SEED_ROOT=.*#SEED_ROOT=$seed_root#" "$v2_receipt" > "$tmp/receipt-bad-seed"
  run_receipt_case bad-seed-root fail "$tmp/receipt-bad-seed"
  grep -q 'seed root is not a direct child' "$tmp/receipt-bad-seed-root.log.out"
done
run_receipt_case missing fail "$tmp/no-such-receipt"
grep -q 'not a regular readable file' "$tmp/receipt-missing.log.out"
sed 's/^COPY_VERIFIED=PASS$/COPY_VERIFIED=FAIL/' "$v2_receipt" > "$tmp/receipt-failed"
run_receipt_case failed fail "$tmp/receipt-failed"
grep -v '^COPY_VERIFIED=' "$v2_receipt" > "$tmp/receipt-unverified"
run_receipt_case unverified fail "$tmp/receipt-unverified"
{ cat "$v2_receipt"; printf 'EXTRA=1\n'; } > "$tmp/receipt-unknown"
run_receipt_case unknown-field fail "$tmp/receipt-unknown"
{ cat "$v2_receipt"; printf 'COPY_VERIFIED=PASS\n'; } > "$tmp/receipt-duplicate"
run_receipt_case duplicate-field fail "$tmp/receipt-duplicate"
sed 's/^COPY_RECEIPT_VERSION=2$/COPY_RECEIPT_VERSION=1/' "$v2_receipt" > "$tmp/receipt-v1"
run_receipt_case version-1 fail "$tmp/receipt-v1"
grep -q 'unsupported or missing copy receipt version: 1' "$tmp/receipt-version-1.log.out"
sed 's/^EVIDENCE_SHA256=.*/EVIDENCE_SHA256=0000/' "$v2_receipt" > "$tmp/receipt-other-evidence"
run_receipt_case other-evidence fail "$tmp/receipt-other-evidence"
grep -q 'bound to different preflight evidence' "$tmp/receipt-other-evidence.log.out"
sed 's/^DESCRIPTOR_SHA256=.*/DESCRIPTOR_SHA256=0000/' "$v2_receipt" > "$tmp/receipt-other-descriptor"
run_receipt_case other-descriptor fail "$tmp/receipt-other-descriptor"
grep -q 'bound to a different descriptor' "$tmp/receipt-other-descriptor.log.out"
sed 's/^VERIFIED_BY=.*/VERIFIED_BY=someone/' "$v2_receipt" > "$tmp/receipt-verified-by"
run_receipt_case verified-by fail "$tmp/receipt-verified-by"
sed 's/^TARGET_UUID=.*/TARGET_UUID=OTHER/' "$v2_receipt" > "$tmp/receipt-other-uuid"
run_receipt_case other-uuid fail "$tmp/receipt-other-uuid"
grep -q 'does not match mounted UUID' "$tmp/receipt-other-uuid.log.out"
sed "s#^TARGET_MOUNTPOINT=.*#TARGET_MOUNTPOINT=/elsewhere#" "$v2_receipt" > "$tmp/receipt-other-mount"
run_receipt_case other-mount fail "$tmp/receipt-other-mount"
grep -q 'names a different target mountpoint' "$tmp/receipt-other-mount.log.out"
# The receipt is bound to the evidence bytes, so evidence from another run
# does not authorize it.
RECEIPT_EVIDENCE=$stale_evidence run_receipt_case stale-evidence fail "$v2_receipt"

# Real option sets. Every external command line the tool runs is either run
# for real here (on scratch files) or, where that needs a block device, run
# against a non-device so the real binary still parses its options and output
# columns. REQUIRE_REAL_TOOL_CHECKS=1 (the Nix check) makes a missing tool a
# failure instead of a skip.
opt_root=$tmp/options
mkdir -p "$opt_root/src/d" "$opt_root/dst"
printf 'x\n' > "$opt_root/src/d/f"

require_in_script() {
  grep -qF -- "$1" "$formatter" || { echo "tool no longer runs: $1 (update test.sh)" >&2; exit 1; }
}

have_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  if [[ ${REQUIRE_REAL_TOOL_CHECKS-} == 1 ]]; then
    echo "real tool missing: $1" >&2
    exit 1
  fi
  echo "note: $1 is not installed; its option check is skipped" >&2
  return 1
}

# Fail if the real binary rejects an option, action, or output column. The
# command may fail for other reasons (no such device).
assert_options_parse() {
  local output
  output=$("$@" 2>&1 </dev/null) || true
  if grep -qiE 'unrecognized option|unknown option|invalid option|unknown column|unknown action|requires an argument|try .*--help' <<< "$output"; then
    printf 'real %s rejected its options: %s\n%s\n' "$1" "$*" "$output" >&2
    exit 1
  fi
}

# rsync: the exact option arrays from the tool, as dry runs on a tiny tree.
# rsync must be invoked only through those arrays.
while IFS= read -r line; do
  [[ $line == *'"${RSYNC_COPY_ARGS[@]}"'* || $line == *'"${RSYNC_VERIFY_ARGS[@]}"'* ]] ||
    { echo "rsync invoked outside the checked option arrays: $line" >&2; exit 1; }
done < <(grep -E '(^|[;&|(]|\$\()[[:space:]]*rsync[[:space:]]' "$formatter")
refute_grep '--itemized-changes' "$formatter"
(
  source "$formatter"
  "$REAL_RSYNC" "${RSYNC_COPY_ARGS[@]}" --dry-run -- "$opt_root/src"/ "$opt_root/dst"/ >/dev/null
  output=$("$REAL_RSYNC" "${RSYNC_VERIFY_ARGS[@]}" -- "$opt_root/src"/ "$opt_root/dst"/)
  # The destination is empty, so the dry run must itemize the missing file.
  grep -q 'd/f' <<< "$output"
  [[ -z $(find "$opt_root/dst" -mindepth 1) ]]
)

# coreutils, run for real.
require_in_script "stat -c '%d' --"
stat -c '%d' -- "$opt_root/src" >/dev/null
require_in_script "stat -c '%u %a' --"
stat -c '%u %a' -- "$opt_root/src/d/f" >/dev/null
require_in_script 'du -sx --apparent-size -B1 --'
du -sx --apparent-size -B1 -- "$opt_root/src" >/dev/null
require_in_script 'du -sx -B1 --'
du -sx -B1 -- "$opt_root/src" >/dev/null
require_in_script 'df -P -B1 --'
df -P -B1 -- "$opt_root/src" >/dev/null
require_in_script 'readlink -f --'
readlink -f -- "$opt_root/src" >/dev/null

# util-linux, gptfdisk, cryptsetup, udev.
if have_tool lsblk; then
  for columns in TYPE PKNAME SERIAL WWN MODEL; do
    require_in_script "lsblk -dnro $columns --"
    assert_options_parse lsblk -dnro "$columns" -- /dev/null
  done
  require_in_script 'lsblk -dnbo SIZE --'
  assert_options_parse lsblk -dnbo SIZE -- /dev/null
  require_in_script 'lsblk -nrpo NAME,TYPE --'
  assert_options_parse lsblk -nrpo NAME,TYPE -- /dev/null
fi
if have_tool findmnt; then
  require_in_script 'findmnt -rn -S "$node" -o TARGET'
  assert_options_parse findmnt -rn -S /dev/null -o TARGET
  require_in_script '-o TARGET,SOURCE,FSTYPE,UUID'
  assert_options_parse findmnt -rn -T "$opt_root/src" -o TARGET,SOURCE,FSTYPE,UUID
  require_in_script 'findmnt -rn -R "$SOURCE_PATH" -o TARGET'
  assert_options_parse findmnt -rn -R "$opt_root/src" -o TARGET
fi
if have_tool wipefs; then
  require_in_script 'wipefs -n --noheadings --output TYPE --'
  : > "$opt_root/blank.img"
  wipefs -n --noheadings --output TYPE -- "$opt_root/blank.img" >/dev/null
fi
if have_tool sgdisk; then
  # A scratch image file, never a device.
  truncate -s 64M "$opt_root/disk.img"
  require_in_script 'sgdisk --zap-all "$WHOLE_DEVICE"'
  sgdisk --zap-all "$opt_root/disk.img" >/dev/null
  require_in_script 'sgdisk --new=1:0:0 --typecode=1:8309 "$WHOLE_DEVICE"'
  sgdisk --new=1:0:0 --typecode=1:8309 "$opt_root/disk.img" >/dev/null
fi
if have_tool cryptsetup; then
  # Without a terminal and with no confirmation on stdin, luksFormat stops at
  # its prompt; only its option parsing is exercised.
  require_in_script 'cryptsetup luksFormat --type luks2 --'
  assert_options_parse cryptsetup luksFormat --type luks2 -- "$opt_root/blank.img"
  refute_grep 'LUKS' "$opt_root/blank.img"
fi
if have_tool udevadm; then
  require_in_script 'udevadm info --query=property --name='
  assert_options_parse udevadm info --query=property --name=/dev/null
  require_in_script 'udevadm settle'
  udevadm settle --help >/dev/null
fi
echo "prepare-luks-storage test.sh: all cases passed"
