#!/usr/bin/env bash
# Disposable coverage for classify-legacy-media, run as root in a VM that has
# the media group (GID 505). The generic tool's descriptor, evidence, and
# copy-receipt readers run for real; only the block-device and mount probes
# are stubbed. Renames, ownership, modes, ACLs, and receipts run on a scratch
# directory with the real coreutils, findutils, acl and python3.
set -Eeuo pipefail
trap 'echo "classify-legacy-media test: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

: "${PREPARE_LUKS_STORAGE:?}" "${CLASSIFY_LEGACY_MEDIA:?}"
export PREPARE_LUKS_STORAGE CLASSIFY_LEGACY_MEDIA
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Traversable like the real mount root, so service identities reach pool/.
chmod 0755 "$tmp"
mountpoint=$tmp/storage-clear/disk
descriptor=$tmp/descriptor
cat > "$descriptor" <<EOF
VERSION=1
DISK_NAME=disk
DECLARED_DEVICE=/dev/disk/by-id/wwn-fixture-part1
MAPPER=crypt-disk
KEY_FILE=/run/agenix/luks-disk-key
MOUNTPOINT=$mountpoint
FS_TYPE=xfs
EOF

token=$(printf 'a%.0s' {1..64})
evidence=$tmp/preflight
cat > "$evidence" <<EOF
EVIDENCE_VERSION=3
DESCRIPTOR_SHA256=$(sha256sum "$descriptor" | cut -d' ' -f1)
DISK_NAME=disk
SOURCE=direct
SOURCE_PATH=/mnt/storage-clear/old
SOURCE_TOKEN=$token
TARGET_TOKEN=target-token
TARGET_CLEAR=PASS
CAPACITY_CHECK=PASS
EOF
quiescence=$tmp/quiescence
printf 'EVIDENCE_VERSION=2\nWRITERS=STOPPED\n' > "$quiescence"

receipt=$tmp/copy-receipt
write_receipt() {
  cat > "$receipt" <<EOF
COPY_RECEIPT_VERSION=2
EVIDENCE_SHA256=$(sha256sum "$evidence" | cut -d' ' -f1)
DESCRIPTOR_SHA256=$(sha256sum "$descriptor" | cut -d' ' -f1)
SOURCE_PATH=/mnt/storage-clear/old
SOURCE_TOKEN=$token
TARGET_MOUNTPOINT=$mountpoint
TARGET_UUID=UUID-D
TARGET_ST_DEV=$(stat -c %d "$tmp")
SEED_ROOT=$mountpoint/$1
VERIFIED_BY=verify
COPY_VERIFIED=PASS
EOF
}

file() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${2:-content}" > "$1"; }

outside=$tmp/outside.txt
# The old pool layout as a copy left it: owned by a service UID and the old,
# orphaned group 9000. It has hardlinks inside and across the canonical
# trees, symlinks that move with their targets or stay with them, a symlink
# out of the tree, a private file, named user and group ACL grants, and
# non-canonical content of every kind: files, empty directories, a symlink,
# a FIFO, and a name with a newline.
legacy_fixture() {
  local seed=$1 old
  rm -rf "$mountpoint"
  old=$mountpoint/$seed/medialibrary
  file "$old/movies/film.mkv" film
  chmod 0640 "$old/movies/film.mkv"
  ln -s film.mkv "$old/movies/alias.mkv"
  file "$old/tv/show/e01.mkv" episode
  chmod 0600 "$old/tv/show/e01.mkv"
  mkdir -p "$old/downloads/usenet/complete"
  ln "$old/movies/film.mkv" "$old/downloads/usenet/complete/film.mkv"
  file "$old/movies/shared-with-staging.mkv" shared
  file "$old/dewey-incoming/marker" dewey
  file "$old/staging/marker" staging
  ln "$old/movies/shared-with-staging.mkv" "$old/staging/hardlink.mkv"
  ln -s marker "$old/staging/link"
  ln -s ../staging/marker "$old/dewey-incoming/to-staging"
  mkdir -p "$old/staging/empty/nested"
  mkfifo "$old/staging/fifo"
  file "$old/staging/weird"$'\n'"name" weird
  file "$old/music/album/track.flac" music
  file "$outside" outside
  chmod 0644 "$outside"
  chgrp 9000 "$outside"
  ln -s "$outside" "$old/movies/outside-link"
  chown -hR 6100:9000 "$mountpoint/$seed"
  # Grants the copy preserved from the old disk: a named outsider user, a
  # named outsider group, and a named default entry.
  setfacl -m u:6300:rw "$old/movies/film.mkv"
  setfacl -m d:u:6300:rwx "$old/movies"
  setfacl -m g:6400:rx,d:g:6400:rx "$old/tv/show"
  setfacl -m g:6400:r "$old/tv/show/e01.mkv"
  setfacl -m u:6300:r "$old/staging/marker"
}

# Named ACL entries (user:ID: or group:ID:, access or default) below $1.
named_acl() { find "$1" ! -type l -print0 | xargs -0 getfacl -cpn -- | grep -E '^(default:)?(user|group):[^:]+:' || true; }
as_outsider_user() { setpriv --reuid 6300 --regid 6300 --groups 6300 -- "$@" 2>/dev/null; }
as_outsider_group() { setpriv --reuid 6400 --regid 6400 --groups 6400 -- "$@" 2>/dev/null; }

tree_state() {
  find "$mountpoint" -printf '%P %y %m %U:%G %i %n\n' | LC_ALL=C sort
  getfacl -Rcp "$mountpoint" 2>/dev/null
}

entries() { (cd "$1" && find . -mindepth 1 -maxdepth 1 -printf '%P\n' | LC_ALL=C sort | paste -sd, -); }

run() {
  local log=$1
  shift
  bash -c '
    set -euo pipefail
    source "$CLASSIFY_LEGACY_MEDIA"
    assert_direct_storage_mountpoint() { return 0; }
    resolve_declared_device() { return 0; }
    identity_token() { printf "%s\n" "${IDENTITY:-target-token}"; }
    report_target_evidence_diff() { :; }
    inspect_destination_mount() {
      DESTINATION_UUID=${MOUNTED_UUID:-UUID-D}
      DESTINATION_ST_DEV=$(stat -c %d -- "$MOUNTPOINT")
    }
    if [[ ${SKIP_SYMLINK_CHECK-} == 1 ]]; then
      # Stand-in for a plan that missed a symlink it should have blocked.
      classify_symlinks() { printf "SYMLINKS 0\n"; }
    fi
    if [[ ${LOSE-} == 1 ]]; then
      # Something removes a preserved object while classify runs.
      eval "real_mkdir_shared() $(declare -f classify_mkdir_shared | tail -n +2)"
      classify_mkdir_shared() {
        real_mkdir_shared "$@"
        rm -f -- "$MOUNTPOINT/migration/medialibrary/staging/marker"
      }
    fi
    "$@"
  ' classify-legacy-media "$@" --descriptor "$descriptor" --group 505 >"$log" 2>&1
}

classes=(--library-class movies --library-class tv)
plan() { run "$1" plan_disk --evidence "$evidence" --receipt "$receipt" "${classes[@]}"; }
classify() {
  run "$1" classify_disk --evidence "$evidence" --quiescence-evidence "$quiescence" \
    --receipt "$receipt" "${classes[@]}" "${@:2}"
}

refuses() {
  local name=$1 pattern=$2 before
  shift 2
  before=$(tree_state)
  if "$@"; then
    cat "$tmp/$name.log" >&2
    echo "unexpectedly passed: $name" >&2
    exit 1
  fi
  grep -q -- "$pattern" "$tmp/$name.log" || { cat "$tmp/$name.log" >&2; exit 1; }
  [[ $(tree_state) == "$before" ]] || { echo "refusal changed the disk: $name" >&2; exit 1; }
}

# plan is read-only and describes exactly what classify would do.
legacy_fixture .earlier-seed
write_receipt .earlier-seed
before=$(tree_state)
plan "$tmp/plan.log" || { cat "$tmp/plan.log" >&2; exit 1; }
[[ $(tree_state) == "$before" ]]
for line in "TOP drwxr-xr-x 6100:9000 $mountpoint/.earlier-seed" \
  "MOVE medialibrary/downloads -> pool/downloads (4 objects)" \
  "MOVE medialibrary/movies -> pool/library/movies (5 objects)" \
  "MOVE medialibrary/tv -> pool/library/tv (3 objects)" \
  "STAYS migration/medialibrary" "STAYS migration/medialibrary/dewey-incoming" \
  "STAYS migration/medialibrary/music" "STAYS migration/medialibrary/staging" \
  "CROSS_TREE_HARDLINKS 1" "SYMLINKS 4" \
  'SYMLINK "medialibrary/staging/link" -> "marker"' \
  'SYMLINK "medialibrary/movies/alias.mkv" -> "film.mkv"' \
  "CLASSIFY_READY=yes"; do
  grep -qxF -- "$line" "$tmp/plan.log" || { cat "$tmp/plan.log" >&2; echo "plan lacks: $line" >&2; exit 1; }
done
! grep -q '^BLOCKED' "$tmp/plan.log"

# A collision, an existing pool/ and a symlink at a known path block
# classification: plan says why, classify refuses without changing anything.
file "$mountpoint/.earlier-seed/library/tv/other-show/e01.mkv" other
plan "$tmp/plan-collision.log"
grep -qx 'BLOCKED collision: library/tv medialibrary/tv all hold files for pool/library/tv' "$tmp/plan-collision.log"
grep -qx 'CLASSIFY_READY=no' "$tmp/plan-collision.log"
refuses collision 'classification is blocked' classify "$tmp/collision.log" --approve-classify
rm -rf "$mountpoint/.earlier-seed/library"
mkdir "$mountpoint/pool"
plan "$tmp/plan-pool.log"
grep -qx 'BLOCKED pool/ already exists' "$tmp/plan-pool.log"
refuses existing-pool 'classification is blocked' classify "$tmp/existing-pool.log" --approve-classify
rmdir "$mountpoint/pool"
mv "$mountpoint/.earlier-seed/medialibrary/tv" "$tmp/tv-away"
ln -s "$tmp/tv-away" "$mountpoint/.earlier-seed/medialibrary/tv"
refuses symlink-entry 'classification is blocked' classify "$tmp/symlink-entry.log" --approve-classify
grep -qx 'BLOCKED medialibrary/tv is not a real directory; it cannot move to pool/library/tv' "$tmp/symlink-entry.log"

# A relative symlink whose target would land on the other side of the
# pool/ / migration/ boundary: plan names it, classify refuses before any
# rename. So does one whose target would move out from under it into pool/.
legacy_fixture .earlier-seed
ln -s ../movies/film.mkv "$mountpoint/.earlier-seed/medialibrary/staging/crossing"
ln -s ../../../movies/film.mkv "$mountpoint/.earlier-seed/medialibrary/downloads/usenet/complete/sibling"
plan "$tmp/plan-crossing.log"
grep -qx 'BLOCKED symlink "medialibrary/staging/crossing" would dangle after classification' "$tmp/plan-crossing.log"
grep -qx 'BLOCKED symlink "medialibrary/downloads/usenet/complete/sibling" would dangle after classification' "$tmp/plan-crossing.log"
grep -qx 'CLASSIFY_READY=no' "$tmp/plan-crossing.log"
refuses crossing 'classification is blocked' classify "$tmp/crossing.log" --approve-classify
[[ ! -e $mountpoint/migration && ! -e $mountpoint/pool ]]

# If plan ever missed such a symlink, the preservation proof still catches
# the changed relationship after the renames and writes no classify receipt.
rm "$mountpoint/.earlier-seed/medialibrary/downloads/usenet/complete/sibling"
SKIP_SYMLINK_CHECK=1 classify "$tmp/missed-symlink.log" --approve-classify &&
  { echo "changed symlink relationship not detected" >&2; exit 1; }
grep -q "symlink resolves differently: 'medialibrary/staging/crossing'" "$tmp/missed-symlink.log"
[[ ! -e $mountpoint/migration/.receipts/classify ]]

# Other refusals leave the disk unchanged.
legacy_fixture .earlier-seed
refuses no-approval 'requires --approve-classify' classify "$tmp/no-approval.log"
refuses plan-approval 'plan takes no approval flag' \
  run "$tmp/plan-approval.log" plan_disk --evidence "$evidence" --receipt "$receipt" "${classes[@]}" --approve-classify
IDENTITY=other-token refuses other-disk 'target identity no longer matches' \
  classify "$tmp/other-disk.log" --approve-classify
MOUNTED_UUID=other refuses other-uuid 'does not match mounted UUID' \
  classify "$tmp/other-uuid.log" --approve-classify
sed -i 's/^COPY_VERIFIED=PASS$/COPY_VERIFIED=FAIL/' "$receipt"
refuses failed-copy 'COPY_VERIFIED=PASS' classify "$tmp/failed-copy.log" --approve-classify
write_receipt .earlier-seed
printf '\n' >> "$evidence"
refuses other-evidence 'bound to different preflight evidence' \
  classify "$tmp/other-evidence.log" --approve-classify
sed -i '$d' "$evidence"
refuses share-first 'requires a passing classify receipt' \
  run "$tmp/share-first.log" share_disk --approve-share

# A lost object is caught: classify fails its preservation proof and writes
# no classify receipt.
LOSE=1 classify "$tmp/lose.log" --approve-classify && { echo "lost object not detected" >&2; exit 1; }
grep -q "missing: 'medialibrary/staging/marker'" "$tmp/lose.log"
grep -q 'did not preserve every object' "$tmp/lose.log"
[[ ! -e $mountpoint/migration/.receipts/classify ]]

# classify: rename-only, nothing lost, provenance in migration/.receipts.
legacy_fixture .earlier-seed
# The copied named grants work before share: that is what share must end.
as_outsider_user cat "$mountpoint/.earlier-seed/medialibrary/movies/film.mkv" >/dev/null
as_outsider_group cat "$mountpoint/.earlier-seed/medialibrary/tv/show/e01.mkv" >/dev/null
objects=$(find "$mountpoint/.earlier-seed" -printf . | wc -c)
film_inode=$(stat -c %i "$mountpoint/.earlier-seed/medialibrary/movies/film.mkv")
shared_inode=$(stat -c %i "$mountpoint/.earlier-seed/medialibrary/movies/shared-with-staging.mkv")
classify "$tmp/classify.log" --approve-classify || { cat "$tmp/classify.log" >&2; exit 1; }
grep -qx "VERIFIED_OBJECTS=$objects" "$tmp/classify.log"
[[ $(entries "$mountpoint") == migration,pool ]]
[[ $(entries "$mountpoint/pool") == downloads,library ]]
[[ $(entries "$mountpoint/pool/library") == movies,tv ]]
[[ $(entries "$mountpoint/migration") == .receipts,medialibrary ]]
[[ $(entries "$mountpoint/migration/medialibrary") == dewey-incoming,music,staging ]]
[[ $(entries "$mountpoint/migration/.receipts") == classify,copy-receipt,inventory-after-migration,inventory-after-pool,inventory-before,moves,plan,preflight-evidence,quiescence-evidence ]]
grep -qx "VERIFIED_OBJECTS=$objects" "$mountpoint/migration/.receipts/classify"
grep -qx 'MOVED=medialibrary/tv|library/tv' "$mountpoint/migration/.receipts/classify"
[[ $(wc -l < "$mountpoint/migration/.receipts/inventory-before") -eq $objects ]]
cmp -s "$receipt" "$mountpoint/migration/.receipts/copy-receipt"
cmp -s "$evidence" "$mountpoint/migration/.receipts/preflight-evidence"
cmp -s "$quiescence" "$mountpoint/migration/.receipts/quiescence-evidence"
[[ $(stat -c %i "$mountpoint/pool/library/movies/film.mkv") == "$film_inode" ]]
[[ $(stat -c %i "$mountpoint/pool/downloads/usenet/complete/film.mkv") == "$film_inode" ]]
[[ $(stat -c %i "$mountpoint/migration/medialibrary/staging/hardlink.mkv") == "$shared_inode" ]]
[[ $(stat -c %i "$mountpoint/pool/library/movies/shared-with-staging.mkv") == "$shared_inode" ]]
# Symlinks kept together, and moved together with their target, still work.
[[ $(readlink "$mountpoint/migration/medialibrary/staging/link") == marker ]]
[[ $(cat "$mountpoint/migration/medialibrary/staging/link") == staging ]]
[[ $(cat "$mountpoint/migration/medialibrary/dewey-incoming/to-staging") == staging ]]
[[ $(cat "$mountpoint/pool/library/movies/alias.mkv") == film ]]
[[ $(readlink "$mountpoint/pool/library/movies/outside-link") == "$outside" ]]
[[ -p $mountpoint/migration/medialibrary/staging/fifo ]]
[[ -d $mountpoint/migration/medialibrary/staging/empty/nested ]]
[[ $(cat "$mountpoint/migration/medialibrary/staging/weird"$'\n'"name") == weird ]]
[[ $(stat -c %a:%u:%g "$mountpoint/pool") == 2770:0:505 ]]
[[ $(getfacl -cpd "$mountpoint/pool/library" | grep . | paste -sd, -) == user::rwx,group::rwx,mask::rwx,other::--- ]]
[[ $(stat -c %a "$mountpoint/migration/.receipts") == 700 ]]
# Moved content keeps its owners and modes until the separate share step.
[[ $(stat -c %a:%u:%g "$mountpoint/pool/library/movies/film.mkv") == 660:6100:9000 ]]
[[ -n $(named_acl "$mountpoint/pool") ]]
refuses rerun 'classification is blocked' classify "$tmp/rerun.log" --approve-classify

# share: owners kept, group 505, group read/write, setgid directories with
# the group-only default ACL, no world access; symlinks not followed;
# migration/ untouched.
# Everything in migration/ except the classifier's own receipts.
migration_state() {
  # staging/hardlink.mkv is the same object as a promoted pool/ file; it is
  # checked on its own below.
  (cd "$mountpoint/migration" && find . \( -path ./.receipts -o -path ./medialibrary/staging/hardlink.mkv \) -prune -o -printf '%P %y %m %U:%G\n' | LC_ALL=C sort &&
    find . \( -path ./.receipts -o -path ./medialibrary/staging/hardlink.mkv \) -prune -o ! -type l -print0 | LC_ALL=C sort -z | xargs -0 getfacl -p --)
}
migration_before=$(migration_state)
refuses share-no-approval 'requires --approve-share' run "$tmp/share-no-approval.log" share_disk
run "$tmp/share.log" share_disk --approve-share || { cat "$tmp/share.log" >&2; exit 1; }
grep -qx 'SHARED=PASS' "$mountpoint/migration/.receipts/share"
[[ $(stat -c %a:%u:%g "$mountpoint/pool/library/movies/film.mkv") == 660:6100:505 ]]
[[ $(stat -c %a:%u:%g "$mountpoint/pool/library/tv/show/e01.mkv") == 660:6100:505 ]]
[[ $(stat -c %a:%u:%g "$mountpoint/pool/library/tv/show") == 2770:6100:505 ]]
[[ $(getfacl -cpd "$mountpoint/pool/library/tv/show" | grep . | paste -sd, -) == user::rwx,group::rwx,mask::rwx,other::--- ]]
[[ -z $(find "$mountpoint/pool" ! -type l ! -group 505 -print -quit) ]]
[[ -z $(find "$mountpoint/pool" ! -type l -perm /0007 -print -quit) ]]
[[ $(stat -c %a:%g "$outside") == 644:9000 ]]
[[ $(migration_state) == "$migration_before" ]]
[[ $(stat -c %a:%g "$mountpoint/migration/medialibrary/staging/hardlink.mkv") == 660:505 ]]
# The copied named grants are gone from pool/, access and default alike,
# and the outsiders they named are refused; migration/ keeps its own.
[[ -z $(named_acl "$mountpoint/pool") ]]
[[ $(getfacl -cpn "$mountpoint/pool/library/movies" | grep . | paste -sd, -) == user::rwx,group::rwx,other::---,default:user::rwx,default:group::rwx,default:mask::rwx,default:other::--- ]]
if as_outsider_user cat "$mountpoint/pool/library/movies/film.mkv"; then
  echo "a named user grant survived share" >&2
  exit 1
fi
if as_outsider_group cat "$mountpoint/pool/library/tv/show/e01.mkv"; then
  echo "a named group grant survived share" >&2
  exit 1
fi
getfacl -cpn "$mountpoint/migration/medialibrary/staging/marker" | grep -qx 'user:6300:r--'
# Without the directory in the way, the file itself grants the outsider nothing.
[[ $(getfacl -cpn "$mountpoint/pool/library/movies/film.mkv" | grep . | paste -sd, -) == user::rw-,group::rw-,other::--- ]]
# Two service UIDs sharing 505 can both work with the content; an identity
# outside the group cannot, and new content inherits the sharing.
setpriv --reuid 6100 --regid 6100 --groups 505 -- sh -c "printf x >> '$mountpoint/pool/library/movies/film.mkv'"
setpriv --reuid 6200 --regid 6200 --groups 505 -- sh -c \
  "umask 022; printf y >> '$mountpoint/pool/library/tv/show/e01.mkv' && echo new > '$mountpoint/pool/library/tv/show/e02.mkv'"
[[ $(stat -c %a:%g "$mountpoint/pool/library/tv/show/e02.mkv") == 660:505 ]]
[[ -z $(named_acl "$mountpoint/pool/library/tv/show/e02.mkv") ]]
if setpriv --reuid 6300 --regid 6300 --groups 6300 -- cat "$mountpoint/pool/library/tv/show/e01.mkv" 2>/dev/null; then
  echo "an identity without the media group read shared content" >&2
  exit 1
fi
refuses share-rerun 'share already ran' run "$tmp/share-rerun.log" share_disk --approve-share

# A copy made straight into migration/ whose source also has empty canonical
# skeletons beside the old layout: the content moves, the skeletons stay in
# migration/, and nothing is deleted.
legacy_fixture migration
mkdir -p "$mountpoint/migration/library/movies" "$mountpoint/migration/library/tv" \
  "$mountpoint/migration/downloads/usenet/incomplete" "$mountpoint/migration/downloads/torrents"
write_receipt migration
objects=$(find "$mountpoint/migration" -printf . | wc -c)
plan "$tmp/plan-skeletons.log"
grep -qx 'KEEP downloads -> migration/downloads (empty duplicate)' "$tmp/plan-skeletons.log"
classify "$tmp/skeletons.log" --approve-classify || { cat "$tmp/skeletons.log" >&2; exit 1; }
grep -qx "VERIFIED_OBJECTS=$objects" "$tmp/skeletons.log"
[[ $(entries "$mountpoint/pool/library") == movies,tv ]]
[[ -e $mountpoint/pool/downloads/usenet/complete/film.mkv ]]
[[ -d $mountpoint/migration/library/tv && -d $mountpoint/migration/downloads/torrents ]]
[[ $(entries "$mountpoint/migration") == .receipts,downloads,library,medialibrary ]]

echo "classify-legacy-media test: all cases passed"
