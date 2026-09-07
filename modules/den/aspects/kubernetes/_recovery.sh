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
    remaining=$(k -n "$namespace" get pods -o json | jq --arg phase "$phase" '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == "immich-postgres") | not) | select(if $phase == "deployments" then any(.metadata.ownerReferences[]?; .kind == "ReplicaSet") else (any(.metadata.ownerReferences[]?; .kind == "DaemonSet") | not) end)] | length')
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
if [[ $action == resume ]]; then
  [[ -f $session/ready && ! -f $session/resumed ]]
  cmp "$descriptor" "$session/descriptor.json"
  cmp "$RECOVERY_INVENTORY" "$session/inventory.json"
  incus --project "$project" start "$instance"
  for (( attempt=0; attempt<180; attempt++ )); do k get nodes >/dev/null 2>&1 && break; sleep 2; done
  scale_saved "$session/workloads.json" ''
  while IFS=$'\t' read -r namespace kind name; do
    k -n "$namespace" rollout status "$kind/$name" --timeout=600s
  done < <(jq -r '.items[] | select((.spec.replicas // 1)>0) | [.metadata.namespace,.kind,.metadata.name] | @tsv' "$session/workloads.json")
  scale_saved "$session/argocd.json" ''
  note 'Resumed workloads, then Argo reconciliation'
  touch "$session/resumed"
  publish 1
  exit 0
fi
# Exact names prevent accidental omission when Nix adds a new persistent input.
jq -e --slurpfile inventory "$RECOVERY_INVENTORY" '(.retainedPaths|keys|sort) == ($inventory[0].paths|sort) and all(.retainedPaths[]; (.readOnly // false) == false and (.path|startswith("/")))' "$descriptor" >/dev/null
# Root-owned descriptor and export provenance are prerequisites, not a parser for
# hostile paths. Refuse overlapping trees and recovery output inside live state.
mapfile -t names < <(jq -r '.paths[]' "$RECOVERY_INVENTORY")
mapfile -t paths < <(jq -r --slurpfile d "$descriptor" '.paths[] as $n | $d[0].retainedPaths[$n].path' "$RECOVERY_INVENTORY")
for path in "${paths[@]}"; do
  [[ -d $path && ! -L $path && $(realpath -e "$path") == "$path" ]]
  [[ $point != "$path" && $point != "$path/"* && $path != "$point/"* ]]
  [[ $metrics != "$path" && $metrics != "$path/"* ]]
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
  [[ $(cat "$point/COMPLETE") == household-recovery-v1 ]]
  # Check an exact fixed filename set; never execute a supplied checksum path.
  expected=$(printf '%s\n' COMPLETE descriptor.json inventory.json sizes.json images.json database.tar "${names[@]/%/.tar}" | sed '/^immich-postgres.tar$/d' | sort)
  actual=$(find "$point" -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort)
  [[ $expected == "$actual" ]]
  [[ $(find "$point" -mindepth 1 -maxdepth 1 ! -type f | wc -l) == 0 ]]
  [[ $(cut -c67- "$point/SHA256SUMS" | sort) == "$expected" ]]
  (cd "$point"; sha256sum --check --strict SHA256SUMS)
fi
mkdir "$session"
cp "$descriptor" "$session/descriptor.json"
cp "$RECOVERY_INVENTORY" "$session/inventory.json"
note "Starting $action; reconcilers will remain stopped until explicit resume"
# Stop the owner itself, not Application syncPolicy: app-of-apps cannot undo this
# after every Argo controller pod is gone. No other autoscaler may own this set.
k -n argocd get deployments,statefulsets -o json > "$session/argocd.json"
jq -e '.items|length>0' "$session/argocd.json" >/dev/null
scale_saved "$session/argocd.json" 0
wait_pods argocd all
k get deployments,statefulsets -A -o json | jq --slurpfile i "$RECOVERY_INVENTORY" '{items:[.items[] | select(.metadata.namespace as $n | $i[0].namespaces|index($n)) | select(.metadata.name != "immich-postgres")]}' > "$session/workloads.json"
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
  k -n "$namespace" get daemonsets -o json | jq -e --arg namespace "$namespace" 'all(.items[]; $namespace=="monitoring" and .metadata.name=="alloy")' >/dev/null
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
  k -n immich exec -i deployment/immich-postgres -- sh -es > "$work/database.tar" <<'DATABASE'
export PGPASSWORD="$POSTGRES_PASSWORD"
test "$(psql -U immich -d immich -Atc "SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default','pg_global')")" = 0
exec pg_basebackup -U immich -D - -Ft -X fetch --checkpoint=fast
DATABASE
else
  work=$point
fi
incus --project "$project" stop "$instance" --timeout 120
[[ $(incus --project "$project" list "$instance" --format json | jq -r '.[0].status') == Stopped ]]
note 'Guest stopped; no retained mounts have active guest writers'
if [[ $action == export ]]; then
  for index in "${!names[@]}"; do
    name=${names[$index]}
    [[ $name == immich-postgres ]] && continue
    tar --numeric-owner --acls --xattrs -cpf "$work/$name.tar" -C "${paths[$index]}" .
  done
else
  total=$(jq -er '[.[]]|add' "$work/sizes.json")
  [[ $total =~ ^[0-9]+$ ]]
  for path in "${paths[@]}"; do
    available=$(df -B1 --output=avail "$(dirname "$path")" | sed -n '2s/ //gp')
    (( available > total + total/5 + 1073741824 ))
    [[ ! -e $path.staged-$stamp && ! -e $path.displaced-$stamp ]]
  done
  for index in "${!names[@]}"; do
    name=${names[$index]} path=${paths[$index]} stage=${paths[$index]}.staged-$stamp
    mkdir "$stage"
    if [[ $name == immich-postgres ]]; then
      mkdir "$stage/pgdata"
      tar -xpf "$work/database.tar" -C "$stage/pgdata"
      pg_verifybackup "$stage/pgdata"
      base=$(jq -er .idmapBase "$descriptor")
      uid=$(jq -er --arg name "$name" '.retainedPaths[$name].uid' "$descriptor")
      gid=$(jq -er --arg name "$name" '.retainedPaths[$name].gid' "$descriptor")
      chown -R "$((base+uid)):$((base+gid))" "$stage"
      chmod 700 "$stage" "$stage/pgdata"
    else
      tar --numeric-owner --acls --xattrs -xpf "$work/$name.tar" -C "$stage"
    fi
    note "Staged $name at $stage"
    sync -f "$stage"
  done
  # Every archive has been extracted and the database verified before first rename.
  for path in "${paths[@]}"; do
    note "Displacing $path to $path.displaced-$stamp"
    mv -T "$path" "$path.displaced-$stamp"
    mv -T "$path.staged-$stamp" "$path"
    sync -f "$(dirname "$path")"
    note "Installed $path"
  done
fi
if [[ $action == export ]]; then
  # Verify native database bytes before exposing a complete point, too.
  mkdir "$session/database-check"
  tar -xpf "$work/database.tar" -C "$session/database-check"
  pg_verifybackup "$session/database-check"
  rm -rf "$session/database-check"
  printf 'household-recovery-v1\n' > "$work/COMPLETE"
  (cd "$work"; sha256sum COMPLETE descriptor.json inventory.json sizes.json images.json database.tar ./*.tar | sort -u > SHA256SUMS)
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
