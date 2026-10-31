set -Eeuo pipefail
fixture_error_line() {
  local line=$1 caller_line
  for caller_line in "${BASH_LINENO[@]}"; do
    if [ "$caller_line" -gt 0 ]; then line=$caller_line; fi
  done
  printf "HOMELAB_NATIVE_ARGO_ERROR_LINE=%s\n" "$line" >&2
}
trap 'fixture_error_line "$LINENO"' ERR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
settings=$(jq -c .argo "$FIXTURE_SETTINGS")
bootstrap=$(jq -r .bootstrap <<< "$settings")
manifests=$(jq -r .manifests <<< "$settings")
probe=$(jq -r .probeImage <<< "$settings")
retained_spec=$(jq -r .retainedSpec <<< "$settings")
work="$FIXTURE_WORK/argo"
repo="$work/runtime.git"
url="git://$FIXTURE_ARGO_GIT_IP/runtime.git"
mutation=${FIXTURE_ARGO_MUTATION:-}
case "$mutation" in ''|always-healthy|source-error-ignored|cascade-retained) ;; *) echo 'unknown Argo mutation' >&2; exit 1 ;; esac
k() { "$KUBECTL" "$@"; }
d() { "$FIXTURE_DOCKER" --host "$FIXTURE_DOCKER_HOST" --config "$FIXTURE_DOCKER_CONFIG" "$@"; }
node() { d exec "$FIXTURE_NODE" sh -ec "$1"; }
canonical() { yq -o=json '.' "$manifests/$1"; }
retained() {
  d exec -i "$FIXTURE_NODE" /bin/retained-directories "$@" --spec - < "$retained_spec"
}
invalid_retained() {
  local code=0
  retained validate --entry identity-kanidm >&2 || code=$?
  test "$code" -eq 1
}
retained_snapshot() {
  node 'stat -c "%i:%u:%g:%a" /srv/retained/state /srv/retained/state/identity-kanidm;
    find /srv/retained/state -mindepth 1 -maxdepth 2 -print | sort;
    sha256sum /srv/retained/state/.homelab-retained-root.json /srv/retained/state/identity-kanidm/fixture-sentinel /srv/retained/state/identity-kanidm/startup'
}
publish() {
  d cp "$repo/." "$FIXTURE_ARGO_GIT:/srv/git/runtime.git/" >&2
  # docker cp keeps the caller's UID. git daemon runs as root and refuses a
  # repository owned by anyone else, so a non-root caller would break fetches.
  d exec "$FIXTURE_ARGO_GIT" chown -R 0:0 /srv/git/runtime.git >&2
}
commit() {
  git -C "$repo" add .
  git -C "$repo" commit -m "$1" >&2
  git -C "$repo" rev-parse HEAD > "$work/$2"
  publish
}
app() {
  local name=$1 path=$2 revision=$3 namespace=$4 retained=${5:-false} source=Application-argocd.yaml
  if [ "$retained" = true ]; then source=Application-identity-retained.yaml; fi
  canonical "apps/$source" | jq --arg name "$name" --arg path "$path" --arg revision "$revision" --arg namespace "$namespace" --arg url "$url" '
    .metadata.name=$name | .metadata.annotations["argocd.argoproj.io/sync-wave"]="0" |
    .spec.project="native-argo" | .spec.destination.namespace=$namespace |
    .spec.source={repoURL:$url,path:$path,targetRevision:$revision}'
}
job() {
  jq -n --arg name "$1" --arg command "$2" --arg wave "${3:-0}" --arg namespace "${4:-runtime}" --arg image "$probe" '{
    apiVersion:"batch/v1",kind:"Job",metadata:{name:$name,namespace:$namespace,annotations:{"argocd.argoproj.io/sync-wave":$wave}},
    spec:{backoffLimit:0,template:{spec:{restartPolicy:"Never",automountServiceAccountToken:false,
      containers:[{name:"probe",image:$image,imagePullPolicy:"Never",command:["/bin/sh","-ec",$command],volumeMounts:[{name:"proof",mountPath:"/proof"}]}],
      volumes:[{name:"proof",hostPath:{path:"/srv/proof",type:"Directory"}}]}}}}'
}
directory_consumer() {
  jq -n --arg image "$probe" '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:"directory-consumer",namespace:"runtime"},
    spec:{replicas:1,selector:{matchLabels:{app:"directory-consumer"}},template:{metadata:{labels:{app:"directory-consumer"}},spec:{automountServiceAccountToken:false,
      containers:[{name:"consumer",image:$image,imagePullPolicy:"Never",
        command:["/bin/sh","-ec","test \"$(cat /data/fixture-sentinel)\" = explicitly-provisioned-fixture-state; echo started > /data/startup; sleep 3600"],
        readinessProbe:{exec:{command:["/bin/sh","-ec","test \"$(cat /data/fixture-sentinel)\" = explicitly-provisioned-fixture-state"]}},
        volumeMounts:[{name:"data",mountPath:"/data"}]}],
      volumes:[{name:"data",persistentVolumeClaim:{claimName:"native-argo-consumer"}}]}}}}'
}
unrelated() {
  job "$1" "echo ready > /proof/$1" | k apply -f - >&2
  k -n runtime wait --for=condition=Complete "job/$1" --timeout=120s >&2
  k get nodes -o json | jq -e '.items | length == 1 and all(.[]; any(.status.conditions[]; .type=="Ready" and .status=="True"))' >&2
  node "test \"\$(cat /srv/proof/$1)\" = ready"
}
reader() {
  jq -n --arg image "$probe" '{apiVersion:"apps/v1",kind:"Deployment",metadata:{name:"data-reader",namespace:"identity"},
    spec:{replicas:1,selector:{matchLabels:{app:"data-reader"}},template:{metadata:{labels:{app:"data-reader"}},spec:{automountServiceAccountToken:false,
    containers:[{name:"reader",image:$image,imagePullPolicy:"Never",command:["/bin/sh","-ec","test \"$(cat /data/sentinel)\" = retained-fixture-data; echo consumed > /data/consumed; sleep 3600"],
      readinessProbe:{exec:{command:["/bin/sh","-ec","test \"$(cat /data/sentinel)\" = retained-fixture-data"]}},volumeMounts:[{name:"data",mountPath:"/data"}]}],
    volumes:[{name:"data",persistentVolumeClaim:{claimName:"identity-kanidm"}}]}}}}'
}
identities() {
  k get namespace identity -o json | jq -r .metadata.uid > "$work/namespace.uid"
  k get pv identity-kanidm -o json | jq -r .metadata.uid > "$work/pv.uid"
  k -n identity get pvc identity-kanidm -o json | jq -r .metadata.uid > "$work/pvc.uid"
}
preserve() {
  for pair in 'namespace namespace/identity' 'pv pv/identity-kanidm' 'pvc pvc/identity-kanidm'; do
    read -r file resource <<< "$pair"
    k -n identity get "$resource" -o json | jq -e --arg uid "$(cat "$work/$file.uid")" '.metadata.uid==$uid and .metadata.deletionTimestamp==null' >&2
  done
}
usable() {
  k -n identity rollout status deployment/data-reader --timeout=180s >&2
  test "$(k -n identity exec deployment/data-reader -- /bin/cat /data/sentinel)" = retained-fixture-data
  node 'test "$(cat /srv/retained/state/identity-kanidm/consumed)" = consumed'
}
stop_reader() {
  k -n argocd patch application reader --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >&2
  k -n identity delete deployment data-reader --wait=true --timeout=120s >&2
  k -n identity wait --for=delete pod -l app=data-reader --timeout=120s >&2
}
case "$1" in
setup)
  mkdir -p "$repo" "$work"
  git -C "$repo" init -b main >&2
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" config user.name fixture
  # Declared disposable tmpfs coordinates, never inferred from mountinfo.
  # The retained root stays absent while the node and controllers start.
  node 'mkdir -p /srv/retained /srv/proof; mount -t tmpfs -o size=16m,mode=0755 homelab-api-retained /srv/retained; test ! -e /srv/retained/state'
  d cp "$(jq -r .retainedCommand <<< "$settings")" "$FIXTURE_NODE:/bin/retained-directories"
  d exec "$FIXTURE_ARGO_GIT" mkdir -p /srv/git/runtime.git
  k apply --server-side --field-manager=homelab-bootstrap -f "$bootstrap/namespaces.yaml" >&2
  k apply --server-side --field-manager=homelab-bootstrap -f "$bootstrap/crds.yaml" >&2
  # Native assertions treat absent/null conditions as not ready; the shared
  # outer bound preserves kubectl wait's original total convergence deadline.
  timeout --foreground 120s "$(jq -r .chainsaw "$FIXTURE_SETTINGS")" assert \
    --timeout=120s --no-color \
    --file "$(jq -r .argo.crdReadiness "$FIXTURE_SETTINGS")" >&2
  jq -n '{apiVersion:"v1",kind:"Secret",metadata:{name:"argocd-secret",namespace:"argocd"},stringData:{"server.secretkey":"isolated-native-fixture-only","admin.password":"$2a$10$7lKraD.Az3/wo2XdoQ4YU.kAeUWu0bC7khAuqmskfCXKg3fRDSKGa","admin.passwordMtime":"2026-01-01T00:00:00Z"}}' | k apply -f - >&2
  k apply --server-side --field-manager=homelab-bootstrap -f "$bootstrap/controllers.yaml" >&2
  if [ "$mutation" = always-healthy ]; then
    k -n argocd patch configmap argocd-cm --type=merge -p '{"data":{"resource.customizations.health.argoproj.io_Application":"return {status = \"Healthy\", message = \"broken fixture\"}"}}' >&2
  elif [ "$mutation" = source-error-ignored ]; then
    # Remove only the source-comparison guard from the actual installed Lua.
    # Ordinary workload health propagation remains byte-for-byte unchanged.
    guard=$(cat <<'LUA'
  for _, condition in ipairs(obj.status.conditions or {}) do
    if condition.type == "ComparisonError" then
      return {status = "Degraded", message = "Application source comparison failed"}
    end
  end
LUA
)
    k -n argocd get configmap argocd-cm -o json |
      jq --arg guard "$guard"$'\n' '
        .data["resource.customizations.health.argoproj.io_Application"] as $lua |
        if ($lua | split($guard) | length) != 2 then
          error("source comparison guard missing or ambiguous")
        else
          {data: {"resource.customizations.health.argoproj.io_Application": ($lua | split($guard) | join(""))}}
        end' > "$work/source-error-ignored.json"
    k -n argocd patch configmap argocd-cm --type=merge --patch-file "$work/source-error-ignored.json" >&2
  fi
  for resource in statefulset/argocd-application-controller deployment/argocd-repo-server deployment/argocd-redis deployment/argocd-server deployment/argocd-applicationset-controller; do
    k -n argocd rollout status "$resource" --timeout=300s >&2
  done
  for namespace in runtime local-path-storage; do k create namespace "$namespace" >&2; done
  jq -n --arg url "$url" '{apiVersion:"argoproj.io/v1alpha1",kind:"AppProject",metadata:{name:"native-argo",namespace:"argocd"},spec:{sourceRepos:[$url],destinations:[{server:"https://kubernetes.default.svc",namespace:"*"}],clusterResourceWhitelist:[{group:"",kind:"Namespace"},{group:"",kind:"PersistentVolume"}]}}' | k apply -f - >&2
  hostname=$(k get nodes -o jsonpath='{.items[0].metadata.labels.kubernetes\.io/hostname}')
  printf %s "$hostname" > "$work/hostname"
  mkdir -p "$repo/failed" "$repo/failed-child-root" "$repo/missing-child-root" "$repo/retained-gate" "$repo/retained-consumer"
  job failed-child-job 'exit 1' > "$repo/failed/job.json"
  canonical identity-retained/PersistentVolume-identity-kanidm.yaml |
    jq --arg hostname "$hostname" '.metadata.name="native-argo-consumer" |
      .spec.local.path="/srv/retained/state/identity-kanidm" |
      .spec.claimRef.name="native-argo-consumer" | .spec.claimRef.namespace="runtime" |
      .spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values=[$hostname]' > "$repo/retained-consumer/pv.json"
  canonical identity-retained/PersistentVolumeClaim-identity-kanidm.yaml |
    jq '.metadata.name="native-argo-consumer" | .metadata.namespace="runtime" |
      .spec.volumeName="native-argo-consumer"' > "$repo/retained-consumer/pvc.json"
  directory_consumer > "$repo/retained-consumer/deployment.json"
  commit 'failing workload and unprovisioned local-PV consumer' payload
  git -C "$repo" branch child-payload "$(cat "$work/payload")"
  for name in failed-child missing-child; do
    path=failed; [ "$name" != missing-child ] || path=does-not-exist
    app "$name" "$path" child-payload runtime > "$repo/$name-root/child.json"
    job "$name-late" "echo advanced > /proof/$name-late" 1 > "$repo/$name-root/late.json"
  done
  # Compared desired inventory is reconciled, but does not authorize creation.
  canonical retained-storage/ConfigMap-retained-directories.yaml |
    jq '.metadata.annotations["argocd.argoproj.io/sync-wave"]="-1"' > "$repo/retained-gate/directories.json"
  app retained-consumer retained-consumer "$(cat "$work/payload")" runtime > "$repo/retained-gate/child.json"
  job after-retained-consumer 'echo completed > /proof/retained-consumer-completed' 1 > "$repo/retained-gate/after.json"
  commit 'dependency roots and explicit retained consumer gate' initial
  app failed-root failed-child-root "$(cat "$work/initial")" argocd | k apply -f - >&2
  app missing-root missing-child-root "$(cat "$work/initial")" argocd | k apply -f - >&2
  ;;
revision) printf %s "$(cat "$work/$2")" ;;
start-retained)
  invalid_retained
  unrelated unrelated-with-missing-state
  app retained-gate retained-gate "$(cat "$work/initial")" argocd true | k apply -f - >&2
  printf %s "$(cat "$work/initial")"
  ;;
blocked-children)
  # A bounded observation window catches the actual later-wave side effects.
  sleep 15
  k -n runtime get jobs -o json | jq -e 'all(.items[]; .metadata.name != "failed-child-late" and .metadata.name != "missing-child-late")' >&2
  node 'test ! -e /srv/proof/failed-child-late; test ! -e /srv/proof/missing-child-late'
  ;;
recover-children)
  job repaired-child-job 'exit 0' > "$repo/failed/job.json"
  mkdir -p "$repo/does-not-exist"
  job found-child-job 'exit 0' > "$repo/does-not-exist/job.json"
  commit 'repair failed and missing workloads' repaired
  git -C "$repo" branch -f child-payload "$(cat "$work/repaired")"
  publish
  for name in failed-child missing-child; do
    k -n argocd annotate application "$name" argocd.argoproj.io/refresh=hard --overwrite >&2
  done
  ;;
children-proof) node 'test "$(cat /srv/proof/failed-child-late)" = advanced; test "$(cat /srv/proof/missing-child-late)" = advanced' ;;
retained-blocked)
  # Observe a real pending PV consumer, not a missing-resource success.
  k -n runtime get pods -l app=directory-consumer -o json |
    jq -e '.items | length == 1 and all(.[]; .status.phase=="Pending" and all(.status.containerStatuses[]?; .state.running==null and .state.terminated==null))' >&2
  k -n local-path-storage get configmap retained-directories -o json |
    jq -e --slurpfile spec "$retained_spec" '(.data["directories.json"] | fromjson)["identity-kanidm"] == $spec[0].entries["identity-kanidm"]' >&2
  sleep 15
  node 'test ! -e /srv/retained/state; test ! -e /srv/proof/retained-consumer-completed'
  k -n runtime get jobs -o json | jq -e 'all(.items[]; .metadata.name != "after-retained-consumer")' >&2
  ;;
consumer-uid)
  k -n runtime get pods -l app=directory-consumer -o json |
    jq -ejr 'if (.items | length)==1 then .items[0].metadata.uid else error("expected one retained consumer") end'
  ;;
provision-retained)
  invalid_retained
  node 'test ! -e /srv/retained/state'
  retained provision --root --confirm "$(jq -r .root.id "$retained_spec")" >&2
  retained provision --entry identity-kanidm --confirm "$(jq -r '.entries["identity-kanidm"].id' "$retained_spec")" >&2
  node 'test -z "$(find /srv/retained/state/identity-kanidm -mindepth 1 -print)";
    printf %s explicitly-provisioned-fixture-state > /srv/retained/state/identity-kanidm/fixture-sentinel'
  retained validate --entry identity-kanidm >&2
  ;;
retained-proof)
  k -n runtime rollout status deployment/directory-consumer --timeout=120s >&2
  test "$(k -n runtime exec deployment/directory-consumer -- /bin/cat /data/fixture-sentinel)" = explicitly-provisioned-fixture-state
  node 'test "$(cat /srv/proof/retained-consumer-completed)" = completed; test "$(cat /srv/retained/state/identity-kanidm/startup)" = started'
  ;;
reconcile-invalid-retained)
  # Scratch-only damage: Argo must not repair it. This fixture does not claim
  # runtime refusal for existing directories; the exact native guard proof does.
  node 'chmod 0000 /srv/retained/state/identity-kanidm'
  invalid_retained
  retained_snapshot > "$work/retained.before"
  unrelated unrelated-with-invalid-state
  for name in retained-consumer retained-gate; do
    revision=payload; [ "$name" != retained-gate ] || revision=initial
    jq -n --arg revision "$(cat "$work/$revision")" '{operation:{sync:{revision:$revision}}}' > "$work/resync.json"
    k -n argocd patch application "$name" --type=merge --patch-file "$work/resync.json" >&2
  done
  ;;
nonmutating-proof)
  retained_snapshot > "$work/retained.after"
  cmp "$work/retained.before" "$work/retained.after"
  invalid_retained
  d exec "$FIXTURE_NODE" chmod "$(jq -r '.entries["identity-kanidm"].mode' "$retained_spec")" /srv/retained/state/identity-kanidm
  retained validate --entry identity-kanidm >&2
  ;;
prepare-storage)
  mkdir -p "$repo/retained" "$repo/reader"
  for file in Namespace-identity.yaml PersistentVolume-identity-kanidm.yaml PersistentVolumeClaim-identity-kanidm.yaml; do
    canonical "identity-retained/$file" | jq --arg hostname "$(cat "$work/hostname")" --arg mutation "$mutation" '
      if .kind=="PersistentVolume" then .spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values=[$hostname] else . end |
      if $mutation=="cascade-retained" then del(.metadata.annotations) else . end' > "$repo/retained/$file.json"
  done
  reader > "$repo/reader/deployment.json"
  node 'printf %s retained-fixture-data > /srv/retained/state/identity-kanidm/sentinel'
  commit 'canonical retained volumes and data consumer' storage
  app retained retained "$(cat "$work/storage")" identity true | jq --arg mutation "$mutation" 'if $mutation=="cascade-retained" then .metadata.finalizers=["resources-finalizer.argocd.argoproj.io"] else . end' | k apply -f - >&2
  app reader reader "$(cat "$work/storage")" identity | k apply -f - >&2
  ;;
self-heal)
  usable
  identities
  k -n identity get deployment data-reader -o json | jq -r .metadata.uid > "$work/reader.uid"
  k -n identity delete deployment data-reader --wait=true --timeout=120s >&2
  ;;
self-heal-proof)
  k -n identity get deployment data-reader -o json | jq -e --arg uid "$(cat "$work/reader.uid")" '.metadata.uid!=$uid and .status.observedGeneration==.metadata.generation and .status.availableReplicas==1' >&2
  preserve; usable
  ;;
omit)
  rm "$repo/retained/PersistentVolumeClaim-identity-kanidm.yaml.json"
  commit 'omit canonical retained PVC declaration' omission
  jq -n --arg revision "$(cat "$work/omission")" '{spec:{source:{targetRevision:$revision}}}' > "$work/omission.json"
  k -n argocd patch application retained --type=merge --patch-file "$work/omission.json" >&2
  ;;
preserve) preserve; usable ;;
direct-retire) stop_reader; k -n argocd delete application retained --wait=false >&2 ;;
retirement-proof)
  preserve
  reader | k apply -f - >&2
  usable
  ;;
prepare-root-retirement)
  k -n identity delete deployment data-reader --wait=true --timeout=120s >&2
  mkdir -p "$repo/retirement-root"
  canonical identity-retained/PersistentVolumeClaim-identity-kanidm.yaml > "$repo/retained/PersistentVolumeClaim-identity-kanidm.yaml.json"
  if [ "$mutation" = cascade-retained ]; then jq 'del(.metadata.annotations)' "$repo/retained/PersistentVolumeClaim-identity-kanidm.yaml.json" > "$work/pvc.json"; cp "$work/pvc.json" "$repo/retained/PersistentVolumeClaim-identity-kanidm.yaml.json"; fi
  commit 'restore retained declaration for root retirement' rootPayload
  app retained retained "$(cat "$work/rootPayload")" identity true | jq --arg mutation "$mutation" 'if $mutation=="cascade-retained" then .metadata.finalizers=["resources-finalizer.argocd.argoproj.io"] else . end' > "$repo/retirement-root/child.json"
  commit 'retirement root with canonical non-cascading child' retirementRoot
  app retirement-root retirement-root "$(cat "$work/retirementRoot")" argocd | k apply -f - >&2
  ;;
root-retire) preserve; k -n argocd delete application retirement-root --wait=false >&2 ;;
*) echo "unknown Argo action: $1" >&2; exit 1 ;;
esac
