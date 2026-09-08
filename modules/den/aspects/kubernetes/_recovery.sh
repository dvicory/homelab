# Root-only host operation; this script is packaged with its Nix inventory.
if [[ ${1:-} == --help ]]; then cat "$RECOVERY_GUIDANCE"; exit 0; fi
[[ $# == 4 ]] || { cat "$RECOVERY_GUIDANCE" >&2; exit 2; }
action=$1 descriptor=$(realpath -e "$2") point=$(realpath -m "$3") metrics=$(realpath -e "$4")
[[ $EUID == 0 && $point != / && -d $metrics ]] || exit 2
[[ $action == export || $action == restore || $action == resume ]] || exit 2
umask 077
project=$(jq -er .project "$descriptor")
instance=$(jq -er .instance "$descriptor")
[[ $project =~ ^[a-zA-Z0-9_-]+$ && $instance =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
export INCUS_SOCKET=/var/lib/incus/unix.socket
exec 9>"/run/lock/compute-$project-$instance.lock"
flock -n 9
session="$point.session"
metric="$metrics/household-recovery.prom"
last=0
if [[ -f $metric ]]; then
  last=$(sed -n 's/^homelab_recovery_last_success_timestamp_seconds{recovery_set="household"} \([0-9]*\)$/\1/p' "$metric")
  [[ $last =~ ^[0-9]+$ ]] || exit 2
fi
quiescing=0
guest_started=0
publish() {
  local temporary
  temporary=$(mktemp "$metrics/.household-recovery.XXXXXX")
  printf 'homelab_recovery_last_attempt_success{recovery_set="household"} %s\nhomelab_recovery_last_success_timestamp_seconds{recovery_set="household"} %s\n' "$1" "$last" > "$temporary"
  chmod 644 "$temporary"
  mv -f "$temporary" "$metric"
}
failed() {
  local code=$?
  trap - EXIT
  if (( code != 0 )); then
    if (( quiescing || guest_started )); then
      if ! incus --project "$project" stop "$instance" --timeout 120 >/dev/null 2>&1; then
        printf 'Recovery could not stop guest %s; do not resume or start writers.\n' "$instance" >&2
      fi
    fi
    publish 0
    printf 'Recovery failed; no automatic resume. Inspect %s and staged/displaced paths.\n' "$session" >&2
  fi
  exit "$code"
}
trap failed EXIT
publish 0
k() { incus --project "$project" exec "$instance" -- k3s kubectl "$@"; }
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$session/journal"; }
wait_pods() {
  local namespace=$1 phase=$2 remaining
  for (( attempt=0; attempt<180; attempt++ )); do
    remaining=$(k -n "$namespace" get pods -o json | jq --arg phase "$phase" '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") | select(if $phase == "deployments" then any(.metadata.ownerReferences[]?; .kind == "ReplicaSet") else (any(.metadata.ownerReferences[]?; .kind == "DaemonSet") | not) end)] | length')
    [[ $remaining == 0 ]] && return 0
    sleep 2
  done
  echo "Writers did not stop in $namespace" >&2; return 1
}
scale_saved() {
  local file=$1 count=$2 namespace kind name replicas
  while IFS=$'\t' read -r namespace kind name replicas; do
    k -n "$namespace" scale "$kind/$name" --replicas="${count:-$replicas}"
  done < <(jq -r '.items[] | [.metadata.namespace,.kind,.metadata.name,(.spec.replicas // 1)] | @tsv' "$file")
}
wait_node_ready() {
  local nodes
  for (( attempt=0; attempt<180; attempt++ )); do
    if nodes=$(k get nodes -o json 2>/dev/null) &&
      jq -e '(.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' <<< "$nodes" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "Kubernetes node did not become Ready" >&2
  return 1
}
wait_rollouts() {
  local file=$1 namespace kind name replicas
  while IFS=$'\t' read -r namespace kind name replicas; do
    [[ $replicas =~ ^[0-9]+$ && $replicas -gt 0 ]] || continue
    k -n "$namespace" rollout status "$kind/$name" --timeout=600s
  done < <(jq -r '.items[] | [.metadata.namespace,.kind,.metadata.name,(.spec.replicas // 1)] | @tsv' "$file")
}
wait_argocd_ready() {
  local desired pods
  desired=$(jq -er '[.items[] | (.spec.replicas // 1)] | add // 0' "$session/argocd.json")
  (( desired > 0 )) || return 0
  wait_rollouts "$session/argocd.json"
  for (( attempt=0; attempt<180; attempt++ )); do
    if pods=$(k -n argocd get pods -o json 2>/dev/null) &&
      jq -e '(.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' <<< "$pods" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "Argo controllers did not become Ready" >&2
  return 1
}
copy_contents() {
  local source=$1 destination=$2 list
  list=$(mktemp "$session/.copy-list.XXXXXX")
  if ! find "$source" -mindepth 1 -maxdepth 1 -printf '%P\0' > "$list"; then
    rm -f "$list"
    return 1
  fi
  if ! tar --numeric-owner --acls --xattrs -C "$source" --null --files-from="$list" -cpf - |
    tar --numeric-owner --acls --xattrs -xpf - -C "$destination"; then
    rm -f "$list"
    return 1
  fi
  rm -f "$list"
}
assert_no_descendant_mounts() {
  local root=$1 mountpoints
  mountpoints=$(findmnt --json --list --output TARGET) || {
    printf 'Cannot inspect mounts below %s\n' "$root" >&2
    return 1
  }
  if ! jq -e --arg prefix "$root/" \
    'all(.filesystems[]; .target | startswith($prefix) | not)' <<< "$mountpoints" >/dev/null; then
    printf 'Refusing selected root %s with descendant mounts or unreadable mount metadata\n' "$root" >&2
    return 1
  fi
}
clear_contents() {
  local root=$1 child
  local -a children=()
  shopt -s dotglob nullglob
  children=( "$root"/* )
  for child in "${children[@]}"; do
    rm -rf -- "$child"
  done
}
assert_no_dynamic_content() {
  local index name path child
  for index in "${!names[@]}"; do
    name=${names[$index]} path=${paths[$index]}
    if jq -e --arg name "$name" '(.dynamicPaths // []) | index($name) != null' "$RECOVERY_INVENTORY" >/dev/null; then
      child=$(find "$path" -mindepth 1 -maxdepth 1 -print -quit) || {
        printf 'Cannot inspect retained dynamic-PVC path %s\n' "$name" >&2
        return 1
      }
      if [[ -n $child ]]; then
        printf 'Refusing %s: retained dynamic-PVC content is not represented by rendered resources.\n' "$name" >&2
        return 1
      fi
    fi
  done
}
if [[ $action == resume ]]; then
  [[ -f $session/ready && ! -f $session/resumed ]]
  cmp "$descriptor" "$session/descriptor.json"
  cmp "$RECOVERY_INVENTORY" "$session/inventory.json"
  incus --project "$project" start "$instance"
  guest_started=1
  wait_node_ready
  scale_saved "$session/workloads.json" ''
  wait_rollouts "$session/workloads.json"
  scale_saved "$session/argocd.json" ''
  wait_argocd_ready
  wait_rollouts "$session/workloads.json"
  note 'Resumed workloads after Kubernetes and Argo readiness'
  touch "$session/resumed"
  publish 1
  exit 0
fi
# Generated inventory names must match the evaluated descriptor exactly.
jq -e --slurpfile inventory "$RECOVERY_INVENTORY" '
  $inventory[0].format == 2
  and (.retainedPaths|keys|sort) == ($inventory[0].paths|sort)
  and ((($inventory[0].unresolvedPaths // []) | length) == 0)
  and all(.retainedPaths[]; (.readOnly // false) == false and (.path|startswith("/")))
' "$descriptor" >/dev/null
# Root-owned descriptor and export provenance are prerequisites, not a parser for
# hostile paths. Refuse overlapping trees and recovery output inside live state.
mapfile -t names < <(jq -r '.paths[]' "$RECOVERY_INVENTORY")
mapfile -t paths < <(jq -r --slurpfile d "$descriptor" '.paths[] as $n | $d[0].retainedPaths[$n].path' "$RECOVERY_INVENTORY")
declare -a root_mounts root_attrs
for index in "${!names[@]}"; do
  name=${names[$index]} path=${paths[$index]}
  [[ $name =~ ^[a-zA-Z0-9._-]+$ ]]
  [[ -d $path && ! -L $path && $(realpath -e "$path") == "$path" ]]
  assert_no_descendant_mounts "$path"
  [[ $point != "$path" && $point != "$path/"* && $path != "$point/"* ]]
  [[ $session != "$path" && $session != "$path/"* && $path != "$session/"* ]]
  [[ $metrics != "$path" && $metrics != "$path/"* ]]
  root_attrs[$index]=$(stat -c '%u:%g:%f' -- "$path")
  root_mounts[$index]=$(findmnt -n -o SOURCE,FSTYPE,MAJ:MIN -T "$path" 2>/dev/null || true)
done
assert_no_dynamic_content
for path in "${paths[@]}"; do
  for other in "${paths[@]}"; do [[ $path == "$other" || $path != "$other/"* ]]; done
done
stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
if [[ $action == export ]]; then
  [[ ! -e $point ]]
  mkdir -p "$(dirname "$point")"
else
  [[ -d $point && ! -L $point ]]
  cmp "$RECOVERY_INVENTORY" "$point/inventory.json"
  cmp "$descriptor" "$point/descriptor.json"
  [[ $(cat "$point/COMPLETE") == household-recovery-v2 ]]
  # Check an exact fixed filename set; never execute a supplied checksum path.
  expected=$(printf '%s\n' COMPLETE descriptor.json inventory.json sizes.json images.json "${names[@]/%/.tar}" | sort)
  actual=$(find "$point" -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort)
  [[ $expected == "$actual" ]]
  [[ $(find "$point" -mindepth 1 -maxdepth 1 ! -type f | wc -l) == 0 ]]
  [[ $(cut -c67- "$point/SHA256SUMS" | sort) == "$expected" ]]
  (cd "$point"; sha256sum --check --strict SHA256SUMS)
fi
if [[ $action == restore ]]; then
  restore_total=$(jq -er '[.[]] | add // 0' "$point/sizes.json")
  [[ $restore_total =~ ^[0-9]+$ ]]
  restore_live=0
  for path in "${paths[@]}"; do
    bytes=$(du -sb -- "$path" | cut -f1)
    [[ $bytes =~ ^[0-9]+$ ]]
    restore_live=$((restore_live + bytes))
  done
  restore_required=$((2 * restore_total + restore_live))
  restore_available=$(df -B1 --output=avail "$(dirname "$session")" | sed -n '2s/ //gp')
  [[ $restore_available =~ ^[0-9]+$ ]]
  (( restore_available > restore_required + restore_required/5 + 1073741824 ))
  for path in "${paths[@]}"; do
    bytes=$(du -sb -- "$path" | cut -f1)
    target_available=$(df -B1 --output=avail "$path" | sed -n '2s/ //gp')
    [[ $bytes =~ ^[0-9]+$ && $target_available =~ ^[0-9]+$ ]]
    (( target_available + bytes > restore_total + restore_total/5 + 1073741824 ))
  done
fi
mkdir "$session"
cp "$descriptor" "$session/descriptor.json"
cp "$RECOVERY_INVENTORY" "$session/inventory.json"
if [[ $action == restore ]]; then
  mkdir -p "$session/staged" "$session/displaced"
fi
if [[ $action == export ]]; then
  # This file is generated from trusted cluster resource declarations.
  source "$RECOVERY_PREFLIGHT"
fi
note "Starting $action; reconcilers will remain stopped until explicit resume"
# Stop the owner itself, not Application syncPolicy: app-of-apps cannot undo this
# after every Argo controller pod is gone. No other autoscaler may own this set.
quiescing=1
k -n argocd get deployments,statefulsets -o json > "$session/argocd.json"
jq -e '.items|length>0' "$session/argocd.json" >/dev/null
scale_saved "$session/argocd.json" 0
wait_pods argocd all
k get deployments,statefulsets -A -o json | jq --slurpfile i "$RECOVERY_INVENTORY" '{items:[.items[] | select(.metadata.namespace as $n | $i[0].namespaces|index($n))]}' > "$session/workloads.json"
find -L "$RECOVERY_MANIFESTS" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec yq -r '.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' {} + | sort -u > "$session/declared-images"
k get pods -A -o json | jq --slurpfile i "$RECOVERY_INVENTORY" '[.items[] | select(.metadata.namespace as $n | $i[0].namespaces|index($n)) | .spec | (.containers + (.initContainers // []))[] | .image] | unique' > "$session/images.json"
jq -e 'length>0' "$session/images.json" >/dev/null
while read -r image; do
  jq -en --arg image "$image" --rawfile declared "$session/declared-images" '$declared|split("\n")|index($image)!=null' >/dev/null
done < <(jq -r '.[]' "$session/images.json")
if [[ $action == restore ]]; then cmp "$session/images.json" "$point/images.json"; fi
# Suspended configuration templates cannot launch writers; reject active schedules and autoscalers.
while read -r namespace; do
  k -n "$namespace" get cronjobs,hpa -o json | jq -e 'all(.items[]; .kind=="CronJob" and .spec.suspend==true)' >/dev/null
  k -n "$namespace" get daemonsets -o json | jq --slurpfile i "$RECOVERY_INVENTORY" --arg namespace "$namespace" -e 'all(.items[]; .metadata.name as $name | any($i[0].daemonsets[]?; .namespace == $namespace and .name == $name))' >/dev/null
  k -n "$namespace" get jobs -o json | jq -e 'all(.items[]; (.status.active // 0)==0)' >/dev/null
done < <(jq -r '.namespaces[]' "$RECOVERY_INVENTORY")
jq '{items:[.items[]|select(.kind=="Deployment")]}' "$session/workloads.json" > "$session/deployments.json"
scale_saved "$session/deployments.json" 0
while read -r namespace; do wait_pods "$namespace" deployments; done < <(jq -r '.namespaces[]' "$RECOVERY_INVENTORY")
scale_saved "$session/workloads.json" 0
while read -r namespace; do wait_pods "$namespace" all; done < <(jq -r '.namespaces[]' "$RECOVERY_INVENTORY")
note 'Argo and household writers quiesced'
if [[ $action == export ]]; then
  work="$point.partial-$stamp"
  mkdir "$work"
  cp "$RECOVERY_INVENTORY" "$work/inventory.json"
  cp "$descriptor" "$work/descriptor.json"
  cp "$session/images.json" "$work/images.json"
  sizes='{}'
  total=0
  for index in "${!names[@]}"; do
    bytes=$(du -sb "${paths[$index]}" | cut -f1)
    sizes=$(jq --arg name "${names[$index]}" --argjson bytes "$bytes" '.+{($name):$bytes}' <<< "$sizes")
    total=$((total+bytes))
  done
  printf '%s\n' "$sizes" > "$work/sizes.json"
  available=$(df -B1 --output=avail "$work" | sed -n '2s/ //gp')
  (( available > 2*total + total/5 + 1073741824 ))
else
  work=$point
fi
incus --project "$project" stop "$instance" --timeout 120
[[ $(incus --project "$project" list "$instance" --format json | jq -r '.[0].status') == Stopped ]]
sync
assert_no_dynamic_content
note 'Guest stopped; no retained mounts have active guest writers'
if [[ $action == export ]]; then
  for index in "${!names[@]}"; do
    assert_no_descendant_mounts "${paths[$index]}"
    tar --numeric-owner --acls --xattrs -cpf "$work/${names[$index]}.tar" -C "${paths[$index]}" .
  done
else
  total=$(jq -er '[.[]] | add // 0' "$work/sizes.json")
  [[ $total =~ ^[0-9]+$ ]]
  for index in "${!names[@]}"; do
    name=${names[$index]} stage="$session/staged/${names[$index]}"
    mkdir "$stage"
    tar -xpf "$work/$name.tar" -C "$stage"
    note "Staged $name at $stage"
    sync -f "$stage"
  done
  # Every archive has been extracted before changing any mounted root. Displaced
  # copies remain in the session for recovery.
  for index in "${!names[@]}"; do
    name=${names[$index]} path=${paths[$index]}
    stage="$session/staged/$name"
    displaced="$session/displaced/$name"
    [[ ! -e $displaced ]]
    [[ -d $path && ! -L $path && $(realpath -e "$path") == "$path" ]]
    current_mount=$(findmnt -n -o SOURCE,FSTYPE,MAJ:MIN -T "$path" 2>/dev/null || true)
    if [[ -n ${root_mounts[$index]} ]]; then
      [[ $current_mount == "${root_mounts[$index]}" ]]
    fi
    [[ ${root_attrs[$index]} == "$(stat -c '%u:%g:%f' -- "$path")" ]]
    assert_no_descendant_mounts "$path"
    note "Copying live $path to $displaced"
    cp -a --reflink=auto -- "$path" "$displaced"
    sync -f "$displaced"
    clear_contents "$path"
    copy_contents "$stage" "$path"
    sync -f "$path"
    [[ -d $path && ! -L $path && $(realpath -e "$path") == "$path" ]]
    [[ ${root_attrs[$index]} == "$(stat -c '%u:%g:%f' -- "$path")" ]]
    current_mount=$(findmnt -n -o SOURCE,FSTYPE,MAJ:MIN -T "$path" 2>/dev/null || true)
    if [[ -n ${root_mounts[$index]} ]]; then
      [[ $current_mount == "${root_mounts[$index]}" ]]
    fi
    note "Installed $path; root mount and metadata remain in place"
  done
fi
if [[ $action == export ]]; then
  printf 'household-recovery-v2\n' > "$work/COMPLETE"
  (cd "$work"; sha256sum COMPLETE descriptor.json inventory.json sizes.json images.json ./*.tar | sort -u > SHA256SUMS)
  # Explicit filenames avoid ./ aliases in the externally verified set.
  sed -i 's@  \./@  @' "$work/SHA256SUMS"
  sort -u -o "$work/SHA256SUMS" "$work/SHA256SUMS"
  sync -f "$work"
  mv -T "$work" "$point"
  sync -f "$(dirname "$point")"
  last=$(date +%s)
fi
note "Complete $action; explicit resume permitted"
touch "$session/ready"
publish 1
printf 'Complete %s: %s; guest remains stopped. Run explicit resume after inspection.\n' "$action" "$point"
