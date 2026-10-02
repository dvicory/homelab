# Sourced by Chainsaw scripts; only input publication and native CLI commands.
set -euo pipefail
: "${FIXTURE_SECRET:?owned Secret closure container required}"
: "${FIXTURE_SETTINGS:?private fixture settings required}"
SECRET_STATE=/var/lib/homelab-runtime-secrets
SECRET_ROOT=/run/kubernetes-runtime-secrets
SECRET_BIN=$(jq -er '.secret.coreutils' "$FIXTURE_SETTINGS")
SECRET_RECONCILE=$(jq -er '.secret.reconcile' "$FIXTURE_SETTINGS")

secret_docker() {
  "$FIXTURE_DOCKER" --host "$FIXTURE_DOCKER_HOST" --config "$FIXTURE_DOCKER_CONFIG" "$@"
}
secret_exec() { secret_docker exec "$FIXTURE_SECRET" "$@"; }
secret_kubectl() { "$KUBECTL" --request-timeout=10s "$@"; }
secret_get() { secret_kubectl get secret "$1" -n "$SECRET_NAMESPACE" -o json; }
secret_copy() { secret_docker cp "$1" "$FIXTURE_SECRET:$2"; }
secret_run() { secret_exec "$SECRET_RECONCILE"; }
secret_apply() {
  secret_kubectl apply --server-side --force-conflicts --field-manager=application -f "$1" >/dev/null
}
secret_ack() {
  printf '%s\n' "$1" > "$SECRET_CASE/expected-ack"
  secret_docker cp "$FIXTURE_SECRET:$SECRET_STATE/applied-generation" "$SECRET_CASE/actual-ack"
  cmp "$SECRET_CASE/expected-ack" "$SECRET_CASE/actual-ack"
}
secret_stage() {
  local resources=$1 names=${2:-} yaml_hash names_hash
  cp "$resources" "$SECRET_CASE/runtime-secrets.yaml"
  if [ -n "$names" ]; then
    cp "$names" "$SECRET_CASE/runtime-secrets.names"
  else
    jq -r '.items[] | [.metadata.namespace, .metadata.name, .type, (.data | keys | join(","))] | @tsv' "$resources" |
      LC_ALL=C sort > "$SECRET_CASE/runtime-secrets.names"
  fi
  # An empty generation must have genuinely empty YAML, not a List envelope.
  if jq -e '.items | length == 0' "$resources" >/dev/null; then
    : > "$SECRET_CASE/runtime-secrets.yaml"
  fi
  yaml_hash=$(sha256sum "$SECRET_CASE/runtime-secrets.yaml"); yaml_hash=${yaml_hash%% *}
  names_hash=$(sha256sum "$SECRET_CASE/runtime-secrets.names"); names_hash=${names_hash%% *}
  SECRET_GENERATION=$(printf '%s\n%s\n' "$yaml_hash" "$names_hash" | sha256sum)
  SECRET_GENERATION=${SECRET_GENERATION%% *}
  printf 'generation=%s yaml-sha256=%s names-sha256=%s\n' "$SECRET_GENERATION" "$yaml_hash" "$names_hash" > "$SECRET_CASE/runtime-secrets.commit"
  secret_copy "$SECRET_CASE/runtime-secrets.yaml" "$SECRET_ROOT/runtime-secrets.yaml"
  secret_copy "$SECRET_CASE/runtime-secrets.names" "$SECRET_ROOT/runtime-secrets.names"
  secret_copy "$SECRET_CASE/runtime-secrets.commit" "$SECRET_ROOT/runtime-secrets.commit"
}
secret_snapshot() {
  local destination=$1
  mkdir -p "$destination"
  secret_kubectl get secrets -n "$SECRET_NAMESPACE" -o json |
    jq -S '.items | sort_by(.metadata.name)' > "$destination/api.json"
  secret_docker cp "$FIXTURE_SECRET:$SECRET_STATE/." "$destination/state"
}
secret_refused_without_mutation() {
  secret_snapshot "$SECRET_CASE/before"
  if secret_run; then
    echo 'Invalid Secret input accepted' >&2
    return 1
  fi
  secret_snapshot "$SECRET_CASE/after"
  diff -r "$SECRET_CASE/before" "$SECRET_CASE/after"
}
secret_prepare() {
  SECRET_NAMESPACE=$1
  SECRET_CASE="$FIXTURE_WORK/$SECRET_NAMESPACE"
  mkdir -m 0700 "$SECRET_CASE"
  secret_kubectl create namespace "$SECRET_NAMESPACE" >/dev/null
  # Tests run serially. Reset only synthetic private files inside the owned
  # closure container; no host/store mounts and no production filesystem.
  secret_exec "$SECRET_BIN/rm" -rf "$SECRET_STATE" "$SECRET_ROOT"
  secret_exec "$SECRET_BIN/mkdir" -m 0700 "$SECRET_STATE" "$SECRET_ROOT"
  jq -n --arg ns "$SECRET_NAMESPACE" '{apiVersion:"v1",kind:"List",items:[
    {apiVersion:"v1",kind:"Secret",metadata:{namespace:$ns,name:"shared",labels:{"homelab.danielvicory/runtime-secret":"true"}},type:"Opaque",data:{"source-one":"b25l","source-two":"dHdv"}},
    {apiVersion:"v1",kind:"Secret",metadata:{namespace:$ns,name:"replaced",labels:{"homelab.danielvicory/runtime-secret":"true"}},type:"kubernetes.io/tls",data:{"tls.crt":"Y2VydA==","tls.key":"a2V5"}}
  ]}' > "$SECRET_CASE/initial.json"
  jq '.items |= map(select(.metadata.name == "shared") | .data = {"source-one":"dXBkYXRlZA=="})' "$SECRET_CASE/initial.json" > "$SECRET_CASE/desired.json"
  printf '{"apiVersion":"v1","kind":"List","items":[]}\n' > "$SECRET_CASE/empty.json"
}
secret_baseline() {
  secret_stage "$SECRET_CASE/initial.json"
  SECRET_INITIAL_GENERATION=$SECRET_GENERATION
  secret_exec "$SECRET_BIN/test" ! -e "$SECRET_STATE/applied-generation"
  secret_run
  secret_ack "$SECRET_INITIAL_GENERATION"
  secret_get shared > "$SECRET_CASE/shared-original.json"
  secret_get replaced > "$SECRET_CASE/replaced-original.json"
  SECRET_SHARED_UID=$(jq -er '.metadata.uid' "$SECRET_CASE/shared-original.json")
  SECRET_OLD_UID=$(jq -er '.metadata.uid' "$SECRET_CASE/replaced-original.json")
  secret_docker cp "$FIXTURE_SECRET:$SECRET_STATE/owned" "$SECRET_CASE/owned-original"
  printf '%s\treplaced\t%s\n%s\tshared\t%s\n' "$SECRET_NAMESPACE" "$SECRET_OLD_UID" "$SECRET_NAMESPACE" "$SECRET_SHARED_UID" > "$SECRET_CASE/owned-expected"
  cmp "$SECRET_CASE/owned-original" "$SECRET_CASE/owned-expected"
  jq -e '.type == "Opaque" and .data == {"source-one":"b25l","source-two":"dHdv"}' "$SECRET_CASE/shared-original.json" >/dev/null
  jq -e '.type == "kubernetes.io/tls" and .data == {"tls.crt":"Y2VydA==","tls.key":"a2V5"}' "$SECRET_CASE/replaced-original.json" >/dev/null
}
secret_foreign() {
  jq -n --arg ns "$SECRET_NAMESPACE" '{apiVersion:"v1",kind:"List",items:[
    {apiVersion:"v1",kind:"Secret",metadata:{namespace:$ns,name:"shared"},type:"Opaque",data:{application:"Zm9yZWlnbi12YWx1ZQ=="}},
    {apiVersion:"v1",kind:"Secret",metadata:{namespace:$ns,name:"forged",labels:{"homelab.danielvicory/runtime-secret":"true"}},type:"Opaque",data:{foreign:"Zm9yZWlnbg=="}}
  ]}' > "$SECRET_CASE/foreign.json"
  secret_apply "$SECRET_CASE/foreign.json"
  secret_get forged | jq -S . > "$SECRET_CASE/forged-original.json"
}
