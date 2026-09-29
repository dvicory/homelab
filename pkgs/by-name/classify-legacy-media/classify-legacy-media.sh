# classify-legacy-media: after a verified seed copy, move the media content
# whose place is known into the disk's pool/ tree, and keep everything else,
# unchanged, in its migration/ holding area.
#
# This is migration tooling for disks copied from the old media pool. It is
# not part of prepare-luks-storage and is deleted once the last old disk is
# converted.
#
#   classify-legacy-media plan --descriptor FILE --evidence FILE \
#     --receipt FILE --group GID --library-class NAME...
#   classify-legacy-media classify --descriptor FILE --evidence FILE \
#     --quiescence-evidence FILE --receipt FILE --group GID \
#     --library-class NAME... --approve-classify
#   classify-legacy-media share --descriptor FILE --group GID --approve-share
#
# plan is read-only. It prints what is on the disk, what classify would
# move, what would stay in migration/, every symlink, and whatever blocks
# classification. A symlink blocks it when the renames would make it dangle
# or resolve to a different object; classify never rewrites symlinks.
#
# Known content, relative to the copied source root:
#
#   library/CLASS, medialibrary/CLASS  -> pool/library/CLASS
#   downloads, medialibrary/downloads  -> pool/downloads
#
# CLASS is each --library-class. Everything else stays in migration/ at its
# source-relative path; unrecognized content is not an error. When two
# sources name one destination and only one holds files, that one moves and
# the other stays in migration/; when both hold files, classify refuses.
#
# classify only renames (mv --no-copy, never replacing a destination) and
# never deletes. It renames the copied root to migration/ if the copy used
# another name, then moves the known content into pool/. Before any rename it
# records every object's path, type, device, inode and link count, and what
# each symlink resolves to; afterwards it proves each object is still
# present, with the same identity, at its expected place under pool/ or
# migration/, and that each symlink into this filesystem still resolves to
# the same object. The evidence, copy receipt, plan, inventories and a
# classify receipt go to migration/.receipts/.
#
# share runs once, after classify, on pool/: ACLs the copy preserved are
# removed, owners stay, the group gains read/write, directories get setgid
# and a group-only default ACL, and nothing is world-accessible; no named
# user or group entry remains. It does not follow symlinks and never walks
# migration/; a file hardlinked into both trees is one canonical object, so
# its migration/ name shows the change too (plan counts these as
# CROSS_TREE_HARDLINKS). It is not part of routine activation.
#
# The wrapper defines PREPARE_LUKS_STORAGE before this text; its identity,
# evidence, and receipt checks are sourced from there.

# shellcheck source=/dev/null
source "$PREPARE_LUKS_STORAGE"

CLASSIFY_GROUP=
CLASSIFY_APPROVED=
CLASSIFY_CLASSES=()
RECEIPTS_NAME=.receipts
SHARED_DEFAULT_ACL=d:u::rwx,d:g::rwx,d:m::rwx,d:o::---

# Python shared by plan and the preservation proof: where classify puts each
# object, and what a path resolves to before or after classify.
CLASSIFY_PY_COMMON=$(cat <<'PY'
import json, os, stat, sys

def under(path, root):
    return path == root or path.startswith(root + "/")

def expected(mount, moves, rel):
    """Where the object at rel (relative to the copied root) ends up."""
    for source, destination in moves:
        if rel == source or rel.startswith(source + "/"):
            return os.path.join(mount, "pool", destination + rel[len(source):])
    return os.path.join(mount, "migration", rel) if rel else os.path.join(mount, "migration")

def planned(mount, seed, moves, receipts, path):
    """The current path of whatever will be at path after classify: "new"
    for a directory classify creates, None when nothing will be there."""
    pool, migration = os.path.join(mount, "pool"), os.path.join(mount, "migration")
    if under(path, pool):
        if path in (pool, os.path.join(pool, "library")):
            return "new"
        for source, destination in moves:
            if under(path, os.path.join(pool, destination)):
                return os.path.join(seed, source) + path[len(os.path.join(pool, destination)):]
        return None
    if under(path, migration):
        rel = path[len(migration) + 1:]
        if under(rel, receipts):
            return "new"
        if any(under(rel, source) for source, _ in moves):
            return None
        return os.path.join(seed, rel) if rel else seed
    return None if under(path, seed) else path

def resolve(path, lookup):
    """Follow path as the kernel would, in the tree lookup describes.
    Returns the object's identity, or None if the path dangles."""
    todo, current, hops = list(reversed(path.split("/"))), "/", 0
    while todo:
        part = todo.pop()
        if part in ("", "."):
            continue
        if part == "..":
            current = os.path.dirname(current)
            continue
        candidate = os.path.join(current, part)
        real = lookup(candidate)
        if real is None:
            return None
        if real != "new":
            try:
                st = os.lstat(real)
            except OSError:
                return None
            if stat.S_ISLNK(st.st_mode):
                hops += 1
                if hops > 40:
                    return None
                text = os.readlink(real)
                if text.startswith("/"):
                    current = "/"
                todo.extend(reversed(text.split("/")))
                continue
            if any(p not in ("", ".") for p in todo) and not stat.S_ISDIR(st.st_mode):
                return None
        current = candidate
    real = lookup(current) if current != "/" else "/"
    if real == "new":
        return ["new", current]
    try:
        st = os.lstat(real)
    except (OSError, TypeError):
        return None
    return [st.st_dev, st.st_ino]
PY
)

classify_python() {
  local body=$1
  shift
  python3 - "$@" <<< "$CLASSIFY_PY_COMMON"$'\n'"$body"
}

classify_usage() {
  sed -n '/^#   classify-legacy-media plan/,/^#   classify-legacy-media share/p' "${BASH_SOURCE[0]}" |
    sed 's/^# \{0,1\}//' >&2
  exit 64
}

# DESCRIPTOR is read by the sourced tool's read_descriptor.
# shellcheck disable=SC2034
classify_parse() {
  while (($#)); do
    case $1 in
      --descriptor) DESCRIPTOR=${2-}; shift 2 ;;
      --evidence) EVIDENCE_PATH=${2-}; shift 2 ;;
      --quiescence-evidence) QUIESCENCE_EVIDENCE=${2-}; shift 2 ;;
      --receipt) RECEIPT_PATH=${2-}; shift 2 ;;
      --group) CLASSIFY_GROUP=${2-}; shift 2 ;;
      --library-class) CLASSIFY_CLASSES+=("${2-}"); shift 2 ;;
      --approve-classify|--approve-share) CLASSIFY_APPROVED=$1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ $CLASSIFY_GROUP =~ ^[0-9]+$ ]] || die "--group needs a numeric group ID"
}

# rename(2) only: fail instead of copying, and never replace a destination.
classify_rename() {
  mv -T --no-copy --update=none-fail -- "$1" "$2" || die "rename failed: $1 -> $2"
}

classify_mkdir_shared() {
  mkdir -- "$1"
  chown "0:$CLASSIFY_GROUP" -- "$1"
  chmod 2770 -- "$1"
  setfacl -m "$SHARED_DEFAULT_ACL" -- "$1"
}

# True when a tree holds no files: only (possibly nested) directories.
classify_skeleton() {
  [[ -z $(find "$1" -mindepth 1 ! -type d -print -quit) ]]
}

# Check the target and read the copy receipt; sets SEED to the copied root.
classify_open() {
  read_descriptor
  read_evidence
  require_source_evidence classify
  resolve_declared_device || die "could not resolve the evaluated target"
  if [[ $(identity_token) != "$EVIDENCE_TARGET_TOKEN" ]]; then
    report_target_evidence_diff
    die "target identity no longer matches preflight evidence"
  fi
  inspect_destination_mount
  read_copy_receipt
  SEED=$RECEIPT_SEED_ROOT
}

# Work out the plan without changing anything. Sets CLASSIFY_MOVES
# ("source|destination", relative to SEED and pool/), CLASSIFY_KEPT (known
# sources that stay in migration/), CLASSIFY_BLOCKERS, and prints the plan.
classify_plan() {
  local destination source class entry
  local -a destinations=(downloads)
  local -A sources_for=()
  sources_for[downloads]="downloads medialibrary/downloads"
  for class in "${CLASSIFY_CLASSES[@]}"; do
    [[ $class =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid library class: $class"
    destinations+=("library/$class")
    sources_for[library/$class]="library/$class medialibrary/$class"
  done
  CLASSIFY_MOVES=()
  CLASSIFY_KEPT=()
  CLASSIFY_BLOCKERS=()

  printf 'MOUNTPOINT=%s\n' "$MOUNTPOINT"
  printf 'SEED_ROOT=%s\n' "$SEED"
  while IFS= read -r -d '' entry; do
    printf 'TOP %s\n' "$(stat -c '%A %u:%g %n' -- "$entry")"
    [[ $entry == "$SEED" ]] && continue
    case ${entry##*/} in
      pool|migration) CLASSIFY_BLOCKERS+=("${entry##*/}/ already exists") ;;
      *) CLASSIFY_BLOCKERS+=("unexpected top-level entry ${entry##*/}") ;;
    esac
  done < <(find "$MOUNTPOINT" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  if [[ ! -d $SEED || -L $SEED ]]; then
    CLASSIFY_BLOCKERS+=("copied root $SEED is not a real directory")
  else
    [[ ! -e $SEED/$RECEIPTS_NAME && ! -L $SEED/$RECEIPTS_NAME ]] ||
      CLASSIFY_BLOCKERS+=("copied root already has a $RECEIPTS_NAME entry")
    # inspect_destination_mount has already refused nested mounts.

    for destination in "${destinations[@]}"; do
      local -a present=() with_files=() candidates=()
      read -ra candidates <<< "${sources_for[$destination]}"
      for source in "${candidates[@]}"; do
        [[ -e $SEED/$source || -L $SEED/$source ]] || continue
        if [[ -L $SEED/$source || ! -d $SEED/$source ]]; then
          CLASSIFY_BLOCKERS+=("$source is not a real directory; it cannot move to pool/$destination")
          continue
        fi
        if [[ $(stat -c %d -- "$SEED/$source") != "$DESTINATION_ST_DEV" ]]; then
          CLASSIFY_BLOCKERS+=("$source is on another filesystem")
          continue
        fi
        present+=("$source")
        classify_skeleton "$SEED/$source" || with_files+=("$source")
      done
      ((${#present[@]})) || continue
      if ((${#with_files[@]} > 1)); then
        CLASSIFY_BLOCKERS+=("collision: ${with_files[*]} all hold files for pool/$destination")
        continue
      fi
      local keep=${with_files[0]-${present[0]}}
      CLASSIFY_MOVES+=("$keep|$destination")
      for source in "${present[@]}"; do
        [[ $source == "$keep" ]] || CLASSIFY_KEPT+=("$source")
      done
    done
    ((${#CLASSIFY_MOVES[@]})) || CLASSIFY_BLOCKERS+=("no known media content under $SEED")

    local move
    for move in "${CLASSIFY_MOVES[@]}"; do
      source=${move%%|*}
      printf 'MOVE %s -> pool/%s (%s objects)\n' "$source" "${move#*|}" \
        "$(find "$SEED/$source" -printf . | wc -c)"
    done
    for source in "${CLASSIFY_KEPT[@]}"; do
      printf 'KEEP %s -> migration/%s (empty duplicate)\n' "$source" "$source"
    done
    # Everything outside a moved tree stays in migration/; list it two
    # levels deep so the operator sees what remains unclassified.
    while IFS= read -r -d '' entry; do
      local relative=${entry#"$SEED"/} moved=false
      for move in "${CLASSIFY_MOVES[@]}"; do
        source=${move%%|*}
        if [[ $relative == "$source" || $relative == "$source"/* ]]; then
          moved=true
        fi
      done
      [[ $moved == true ]] || printf 'STAYS migration/%s\n' "$relative"
    done < <(find "$SEED" -mindepth 1 -maxdepth 2 -print0 | LC_ALL=C sort -z)
    printf 'INVENTORY %s\n' "$(find "$SEED" -printf '%y\n' | LC_ALL=C sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')"
    printf 'HARDLINKED_FILES %s\n' "$(find "$SEED" -type f -links +1 -printf . | wc -c)"
    # A file hardlinked both inside a moved tree and elsewhere is one object
    # with a name in pool/ and a name in migration/; share changes it too.
    local -a moved_roots=()
    for move in "${CLASSIFY_MOVES[@]}"; do moved_roots+=("${move%%|*}"); done
    printf 'CROSS_TREE_HARDLINKS %s\n' "$(python3 - "$SEED" "${moved_roots[@]}" <<'PY'
import os, sys
seed, roots = sys.argv[1], sys.argv[2:]
inside, outside = set(), set()
for directory, names, files in os.walk(seed):
    for name in files:
        path = os.path.join(directory, name)
        st = os.lstat(path)
        if st.st_nlink < 2:
            continue
        rel = os.path.relpath(path, seed)
        moved = any(rel == r or rel.startswith(r + "/") for r in roots)
        (inside if moved else outside).add(st.st_ino)
print(len(inside & outside))
PY
)"
    local symlinks line
    symlinks=$(classify_symlinks) || die "could not check symlinks"
    while IFS= read -r line; do
      case $line in
        "BLOCKED "*) CLASSIFY_BLOCKERS+=("${line#BLOCKED }") ;;
        *) printf '%s\n' "$line" ;;
      esac
    done <<< "$symlinks"
  fi
  for entry in "${CLASSIFY_BLOCKERS[@]}"; do
    printf 'BLOCKED %s\n' "$entry"
  done
  if ((${#CLASSIFY_BLOCKERS[@]})); then
    printf 'CLASSIFY_READY=no\n'
  else
    printf 'CLASSIFY_READY=yes\n'
  fi
}

# List every symlink under SEED, and a BLOCKED line for each one the planned
# renames would make dangle or resolve to a different object. classify never
# rewrites a symlink, so such a symlink blocks classification.
classify_symlinks() {
  classify_python "$(cat <<'PY'
seed, mount = (os.path.realpath(a) for a in sys.argv[1:3])
receipts = sys.argv[3]
moves = [m.split("|", 1) for m in sys.argv[4:]]
count = 0
for directory, names, files in os.walk(seed):
    names.sort(); files.sort()
    for name in names + files:
        path = os.path.join(directory, name)
        if not os.path.islink(path):
            continue
        count += 1
        rel = os.path.relpath(path, seed)
        print("SYMLINK " + json.dumps(rel) + " -> " + json.dumps(os.readlink(path)))
        before = resolve(path, lambda p: p)
        after = resolve(expected(mount, moves, rel),
                        lambda p: planned(mount, seed, moves, receipts, p))
        if before != after:
            change = "dangle" if after is None else "resolve to a different object"
            print("BLOCKED symlink " + json.dumps(rel) + " would " + change + " after classification")
print("SYMLINKS %d" % count)
PY
)" "$SEED" "$MOUNTPOINT" "$RECEIPTS_NAME" "${CLASSIFY_MOVES[@]}"
}

# Record every object below $1 as one JSON line: path relative to $1, type,
# device, inode, and link count, and for a symlink the identity of the
# object it resolves to (null if it dangles).
classify_inventory() {
  classify_python "$(cat <<'PY'
root = sys.argv[1]
def kind(mode):
    for test, name in ((stat.S_ISDIR, "d"), (stat.S_ISREG, "f"), (stat.S_ISLNK, "l"),
                       (stat.S_ISFIFO, "p"), (stat.S_ISSOCK, "s"), (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b")):
        if test(mode):
            return name
    return "?"
def emit(path):
    st = os.lstat(path)
    rel = os.path.relpath(path, root)
    entry = {"path": "" if rel == "." else rel, "type": kind(st.st_mode),
             "dev": st.st_dev, "ino": st.st_ino, "nlink": st.st_nlink}
    if entry["type"] == "l":
        entry["target"] = resolve(os.path.realpath(os.path.dirname(path)) + "/" + os.path.basename(path),
                                  lambda p: p)
    print(json.dumps(entry))
emit(root)
for directory, names, files in os.walk(root, followlinks=False):
    names.sort(); files.sort()
    for name in names + files:
        emit(os.path.join(directory, name))
PY
)" "$1"
}

# Prove the rename-only transition: every object in the before inventory is
# at its expected place under pool/ or migration/ with the same device, inode
# and type (and link count, for non-directories), every symlink whose target
# was on this filesystem (or that dangled) resolves to the same object, and
# nothing else is there apart from the classifier's own receipts and
# structural directories.
classify_verify() {
  local before=$1 moves=$2
  classify_python "$(cat <<'PY'
mount, before_path, moves_path, receipts = sys.argv[1:5]
moves = [line.rstrip("\n").split("|", 1) for line in open(moves_path) if line.strip()]
mount_dev = os.stat(mount).st_dev
def expected_at(rel):
    return expected(mount, moves, rel)
before = [json.loads(line) for line in open(before_path)]
problems = []
for entry in before:
    target = expected_at(entry["path"])
    try:
        st = os.lstat(target)
    except FileNotFoundError:
        problems.append(f"missing: {entry['path']!r} (expected at {target!r})")
        continue
    if (st.st_dev, st.st_ino) != (entry["dev"], entry["ino"]):
        problems.append(f"different object: {entry['path']!r} at {target!r}")
    elif entry["type"] != "d" and st.st_nlink != entry["nlink"]:
        problems.append(f"link count changed: {entry['path']!r} {entry['nlink']} -> {st.st_nlink}")
    elif entry["type"] == "l" and (entry["target"] is None or entry["target"][0] == mount_dev):
        now = resolve(os.path.realpath(os.path.dirname(target)) + "/" + os.path.basename(target), lambda p: p)
        if now != entry["target"]:
            problems.append(f"symlink resolves differently: {entry['path']!r} at {target!r}")
# Nothing extra: walk pool/ and migration/, skipping only what classify made.
made = {os.path.join(mount, "pool"), os.path.join(mount, "pool", "library"),
        os.path.join(mount, "migration", receipts)}
expected_paths = {expected_at(entry["path"]) for entry in before}
for top in ("pool", "migration"):
    for directory, names, files in os.walk(os.path.join(mount, top), followlinks=False):
        if directory == os.path.join(mount, "migration"):
            names[:] = [n for n in names if n != receipts]
        for path in [directory] + [os.path.join(directory, n) for n in names + files]:
            if path not in made and path not in expected_paths:
                problems.append(f"unexpected: {path!r}")
for problem in problems[:20]:
    print(problem, file=sys.stderr)
if problems:
    sys.exit(f"lossless check failed: {len(problems)} problem(s)")
print(f"VERIFIED_OBJECTS={len(before)}")
PY
)" "$MOUNTPOINT" "$before" "$moves" "$RECEIPTS_NAME"
}

plan_disk() {
  classify_parse "$@"
  [[ -z $CLASSIFY_APPROVED ]] || die "plan takes no approval flag"
  [[ -n $EVIDENCE_PATH && -n $RECEIPT_PATH ]] || die "plan requires --evidence and --receipt"
  ((${#CLASSIFY_CLASSES[@]})) || die "plan requires at least one --library-class"
  classify_open
  classify_plan
}

classify_disk() {
  classify_parse "$@"
  [[ $CLASSIFY_APPROVED == --approve-classify ]] || die "classify requires --approve-classify"
  [[ -n $EVIDENCE_PATH && -n $QUIESCENCE_EVIDENCE && -n $RECEIPT_PATH ]] ||
    die "classify requires --evidence, --quiescence-evidence, and --receipt"
  ((${#CLASSIFY_CLASSES[@]})) || die "classify requires at least one --library-class"
  [[ -f $QUIESCENCE_EVIDENCE && ! -L $QUIESCENCE_EVIDENCE ]] ||
    die "quiescence evidence is not a regular file: $QUIESCENCE_EVIDENCE"
  classify_open

  local work move
  work=$(mktemp -d) || die "could not create a work directory"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$work'" EXIT
  classify_plan > "$work/plan"
  cat "$work/plan"
  grep -qx 'CLASSIFY_READY=yes' "$work/plan" || die "classification is blocked; nothing was changed"
  for move in "${CLASSIFY_MOVES[@]}"; do printf '%s\n' "$move"; done > "$work/moves"
  classify_inventory "$SEED" > "$work/inventory-before"

  local migration=$MOUNTPOINT/migration pool=$MOUNTPOINT/pool
  local receipts=$migration/$RECEIPTS_NAME
  [[ $SEED == "$migration" ]] || classify_rename "$SEED" "$migration"
  # Provenance first, so it survives a run that stops partway.
  mkdir -m 0700 -- "$receipts"
  cp --preserve=mode,timestamps -- "$EVIDENCE_PATH" "$receipts/preflight-evidence"
  cp --preserve=mode,timestamps -- "$QUIESCENCE_EVIDENCE" "$receipts/quiescence-evidence"
  cp --preserve=mode,timestamps -- "$RECEIPT_PATH" "$receipts/copy-receipt"
  cmp -s -- "$RECEIPT_PATH" "$receipts/copy-receipt" || die "copy receipt changed while it was stored"
  install -m 0600 -- "$work/plan" "$receipts/plan"
  install -m 0600 -- "$work/moves" "$receipts/moves"
  install -m 0600 -- "$work/inventory-before" "$receipts/inventory-before"

  classify_mkdir_shared "$pool"
  classify_mkdir_shared "$pool/library"
  for move in "${CLASSIFY_MOVES[@]}"; do
    classify_rename "$migration/${move%%|*}" "$pool/${move#*|}"
  done

  local verified
  verified=$(classify_verify "$receipts/inventory-before" "$receipts/moves") ||
    die "classification did not preserve every object; see the messages above and $receipts/"
  classify_inventory "$pool" > "$work/inventory-after-pool"
  classify_inventory "$migration" > "$work/inventory-after-migration"
  install -m 0600 -- "$work/inventory-after-pool" "$receipts/inventory-after-pool"
  install -m 0600 -- "$work/inventory-after-migration" "$receipts/inventory-after-migration"

  local tmp
  assert_evidence_unchanged
  umask 077
  tmp=$(mktemp "$receipts/.classify.XXXXXX") || die "could not create classify receipt"
  {
    printf 'CLASSIFY_RECEIPT_VERSION=2\n'
    printf 'SEED_ROOT=%s\n' "$RECEIPT_SEED_ROOT"
    printf 'COPY_RECEIPT_SHA256=%s\n' "$(sha256sum -- "$RECEIPT_PATH" | cut -d' ' -f1)"
    printf 'EVIDENCE_SHA256=%s\n' "$(evidence_sha256)"
    printf 'DESCRIPTOR_SHA256=%s\n' "$(descriptor_sha256)"
    printf 'TARGET_MOUNTPOINT=%s\n' "$MOUNTPOINT"
    printf 'TARGET_UUID=%s\n' "$DESTINATION_UUID"
    for move in "${CLASSIFY_MOVES[@]}"; do printf 'MOVED=%s\n' "$move"; done
    printf '%s\n' "$verified"
    printf 'CLASSIFIED=PASS\n'
  } > "$tmp"
  publish_once "$tmp" "$receipts/classify"
  printf '%s\nCLASSIFIED=PASS\n' "$verified"
}

share_disk() {
  classify_parse "$@"
  [[ $CLASSIFY_APPROVED == --approve-share ]] || die "share requires --approve-share"
  read_descriptor
  inspect_destination_mount
  local pool=$MOUNTPOINT/pool receipts=$MOUNTPOINT/migration/$RECEIPTS_NAME
  grep -qx 'CLASSIFIED=PASS' "$receipts/classify" 2>/dev/null ||
    die "share requires a passing classify receipt at $receipts/classify"
  [[ ! -e $receipts/share ]] || die "share already ran: $receipts/share"
  assert_real_directory_on_destination "$pool"

  # Owners stay. -xdev keeps to this filesystem and find never follows
  # symlinks; symlinks themselves are left alone. ACLs the copy preserved are
  # removed first, so no old named grant outlives the shared group.
  find "$pool" -xdev ! -type l -exec setfacl -b -- {} +
  find "$pool" -xdev ! -type l -exec chgrp -- "$CLASSIFY_GROUP" {} +
  find "$pool" -xdev -type d -exec chmod g+rwxs,o-rwx {} +
  find "$pool" -xdev -type f -exec chmod g+rw,o-rwx {} +
  find "$pool" -xdev -type d -exec setfacl -m "$SHARED_DEFAULT_ACL" -- {} +

  local wrong
  wrong=$(find "$pool" -xdev ! -type l \( ! -group "$CLASSIFY_GROUP" -o -perm /0007 \
    -o \( -type d ! -perm -2070 \) -o \( -type f ! -perm -0060 \) \) -print -quit)
  [[ -z $wrong ]] || die "an entry under $pool does not have the shared mode: $wrong"
  local directories with_acl
  directories=$(find "$pool" -xdev -type d | wc -l)
  with_acl=$(find "$pool" -xdev -type d -print0 | xargs -0 -r getfacl -cpd -- | grep -cx 'group::rwx')
  ((directories == with_acl)) ||
    die "$((directories - with_acl)) directories under $pool lack the shared default ACL"
  local named
  named=$(find "$pool" -xdev ! -type l -print0 | xargs -0 -r getfacl -cpn -- |
    grep -cE '^(default:)?(user|group):[^:]+:' || true)
  ((named == 0)) || die "$named named ACL entries remain under $pool"

  local tmp
  umask 077
  tmp=$(mktemp "$receipts/.share.XXXXXX") || die "could not create share receipt"
  printf 'SHARE_RECEIPT_VERSION=2\nTARGET_UUID=%s\nGROUP=%s\nDEFAULT_ACL=%s\nSHARED=PASS\n' \
    "$DESTINATION_UUID" "$CLASSIFY_GROUP" "$SHARED_DEFAULT_ACL" > "$tmp"
  publish_once "$tmp" "$receipts/share"
  printf 'SHARED=PASS\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  command=${1-}
  shift || true
  case $command in
    plan) plan_disk "$@" ;;
    classify) classify_disk "$@" ;;
    share) share_disk "$@" ;;
    *) classify_usage ;;
  esac
fi
