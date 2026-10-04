set -eu
umask 077
export DOCKER_HOST="$FIXTURE_DOCKER_HOST" DOCKER_CONFIG="$FIXTURE_DOCKER_CONFIG"
g="$FIXTURE_WORK/gateway"
mkdir -p "$g"
setting() { jq -er --arg key "$1" '.gateway[$key]' "$FIXTURE_SETTINGS"; }
k() { "$KUBECTL" "$@"; }
d() { "$FIXTURE_DOCKER" "$@"; }
apply() { k apply -f "$(setting "$1")"; }
node_port=$(setting nodePort)
idm=$(setting idmHost)
admin=$(setting adminHost)
controller=gateway.envoyproxy.io/gatewayclass-controller
# kubectl owns the bounded watch. The final assertion also binds conditions to
# the actual controller/ancestor and current generation, never a stale True.
condition() {
  local resource name namespace kind value reason ancestor ancestor_kind generation owner ref base
  resource=$1 name=$2 namespace=$3 kind=$4 value=$5 reason=${6:-} ancestor=${7:-household} ancestor_kind=${8:-Gateway}
  generation=$(k get "$resource" "$name" -n "$namespace" -o jsonpath='{.metadata.generation}')
  case "$resource" in
    httproute) owner=parents; ref=parentRef ;;
    backendtlspolicy|clienttrafficpolicy|securitypolicy|envoyproxy) owner=ancestors; ref=ancestorRef ;;
    *) owner=; ref= ;;
  esac
  if [ -n "$owner" ]; then
    base=".status.$owner[?(@.$ref.name==\"$ancestor\")].conditions[?(@.type==\"$kind\")]"
  else
    base=".status.conditions[?(@.type==\"$kind\")]"
  fi
  k wait "$resource/$name" -n "$namespace" --timeout=180s "--for=jsonpath={$base.observedGeneration}=$generation"
  k wait "$resource/$name" -n "$namespace" --timeout=180s "--for=jsonpath={$base.status}=$value"
  k get "$resource" "$name" -n "$namespace" -o json | jq -e \
    --arg owner "$owner" --arg ref "$ref" --arg controller "$controller" --arg ancestor "$ancestor" \
    --arg ancestorKind "$ancestor_kind" --arg namespace "$namespace" --arg resource "$resource" \
    --arg kind "$kind" --arg value "$value" --arg reason "$reason" '
      .metadata.generation as $generation |
      (if $owner == "" then [.status] else .status[$owner] end) |
      any(.[];
        (if $owner == "" then true else
          (.[$ref].name == $ancestor and (.[$ref].kind // "Gateway") == $ancestorKind and
           (.[$ref].group // "gateway.networking.k8s.io") ==
             (if $ancestorKind == "SecurityPolicy" then "gateway.envoyproxy.io" else "gateway.networking.k8s.io" end) and
           (.[$ref].namespace // (if $ref == "parentRef" then $namespace else "gateway" end)) == "gateway" and
           ($resource == "envoyproxy" or .controllerName == $controller)) end) and
        any(.conditions[]?; .type == $kind and .status == $value and .observedGeneration == $generation and
          ($reason == "" or .reason == $reason)))' >/dev/null
}
route_ready() { condition httproute "$1" gateway Accepted True; condition httproute "$1" gateway ResolvedRefs True; }
proxy_ready() {
  k rollout status deployment -n gateway -l gateway.envoyproxy.io/owning-gateway-name=household --timeout=180s
  k wait pod -n gateway -l gateway.envoyproxy.io/owning-gateway-name=household --for=condition=Ready --timeout=180s
}
trusted() {
  jq --arg cidr "$FIXTURE_TRUSTED_IP/32" '
    (.items[] | select(.kind == "ClientTrafficPolicy") | .spec.clientIPDetection.xForwardedFor.trustedCIDRs) = [$cidr] |
    (.items[] | select(.kind == "NetworkPolicy" and .metadata.name == "private-origin") | .spec.ingress[0].from) = [{ipBlock:{cidr:$cidr}}]
  ' "$(setting trusted)" > "$g/trusted.json"
  k apply -f "$g/trusted.json"
  condition clienttrafficpolicy trusted-edges gateway Accepted True
  proxy_ready
}
request() {
  local peer host path
  peer=$1 host=$2 path=$3; shift 3
  d exec "$peer" curl -sS --connect-timeout 5 --max-time 10 --cacert /fixture/ca.crt \
    --resolve "$host:$node_port:$FIXTURE_NODE_IP" "https://$host:$node_port/$path" "$@"
}
positive() {
  local peer host path
  peer=$1 host=$2 path=$3; shift 3
  request "$peer" "$host" "$path" --fail --retry 12 --retry-all-errors --retry-delay 1 --retry-max-time 120 "$@"
}
# A rejected HTTP response is not CNI enforcement. Only a failed connection
# without an HTTP response counts; Docker, certificate and other errors fail.
connection_denied() {
  local result
  if request "$FIXTURE_STRANGER" origin.test blocked-probe \
    -H "X-Forwarded-For: $FIXTURE_TRUSTED_IP" -o /fixture/blocked-response \
    -w '%{http_code}' > "$g/blocked.out" 2> "$g/blocked.err"; then
    return 1
  else
    result=$?
  fi
  case "$result" in
    7|28|52|56) if [ "$(cat "$g/blocked.out")" = 000 ]; then return 0; fi ;;
  esac
  echo 'Stranger probe failed without proving a connection-level CNI denial' >&2
  exit 1
}
snapshot() {
  # Envoy's file sink flushes asynchronously. Fence it before inspecting both
  # JSON access records and non-JSON error messages, without filtering either.
  sleep "${1:-3}"
  k logs -n gateway -c envoy --tail=-1 -l gateway.envoyproxy.io/owning-gateway-name=household > "$g/envoy.log"
}
entry() {
  local attempt result
  # Allow 30 one-second log-flush observations.
  for ((attempt=0; attempt<30; attempt++)); do
    snapshot 1
    if jq -Rsec --arg path "/$1" --arg id "${2:-}" --arg code "${3:-}" '
      [split("\n")[] | fromjson? | select(.path == $path and
        ($id == "" or .request_id == $id) and ($code == "" or (.status|tostring) == $code))] |
      if length > 0 then last else empty end
    ' "$g/envoy.log" > "$g/entry.json"; then
      return 0
    else
      result=$?
    fi
    # Empty selection may converge; a jq runtime/schema error must not retry.
    [ "$result" -eq 4 ] || return "$result"
  done
  echo 'Required traffic access record absent after the retained observation bound' >&2
  return 1
}
idm_status() {
  local expected=$1 id=$2 status= matched=false deadline=$((SECONDS + 120)) remaining
  # Controller status can precede Envoy's data-plane update. Require real HTTP
  # convergence within 120 s, not status-only success.
  while ((SECONDS < deadline)); do
    remaining=$((deadline - SECONDS))
    ((remaining > 0)) || break
    ((remaining <= 10)) || remaining=10
    if status=$(request "$FIXTURE_TRUSTED" "$idm" status -H "X-Request-ID: $id" \
      -o /fixture/idm-response -w '%{http_code}' --max-time "$remaining") &&
      [ "$status" = "$expected" ]; then
      matched=true
      break
    fi
    sleep 1
  done
  test "$matched" = true
  entry status "$id" "$expected"
  if [ "$expected" = 503 ]; then
    jq -e '.response_flags | contains("UF")' "$g/entry.json" >/dev/null
    jq -e '.upstream != null and .upstream != "" and .upstream != "-"' "$g/entry.json" >/dev/null
  fi
}
patch_validation() { k patch backendtlspolicy idm -n identity --type=merge -p "$1"; }
setup() {
  apply retained
  k apply --server-side -f "$(setting crds)"
  k wait crd/gateways.gateway.networking.k8s.io crd/envoyproxies.gateway.envoyproxy.io \
    crd/clienttrafficpolicies.gateway.envoyproxy.io crd/securitypolicies.gateway.envoyproxy.io \
    crd/backendtlspolicies.gateway.networking.k8s.io --for=condition=Established --timeout=180s
  apply controller
  k wait job/envoy-gateway-gateway-helm-certgen -n gateway --for=condition=Complete --timeout=180s
  k rollout status deployment/envoy-gateway -n gateway --timeout=300s
  apply origins
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=fixture-ca \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -keyout "$g/ca.key" -out "$g/ca.crt" >/dev/null 2>&1
  openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$idm" -keyout "$g/idm.key" -out "$g/idm.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$idm" > "$g/idm.ext"
  openssl x509 -req -in "$g/idm.csr" -CA "$g/ca.crt" -CAkey "$g/ca.key" -CAcreateserial -days 2 \
    -extfile "$g/idm.ext" -out "$g/idm.crt" >/dev/null 2>&1
  chmod 0644 "$g/idm.key"
  openssl req -new -newkey rsa:2048 -nodes -subj /CN=origin.test -keyout "$g/tls.key" -out "$g/tls.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:origin.test,DNS:%s,DNS:%s\nextendedKeyUsage=serverAuth\n' "$idm" "$admin" > "$g/gateway.ext"
  openssl x509 -req -in "$g/tls.csr" -CA "$g/ca.crt" -CAkey "$g/ca.key" -CAcreateserial -days 2 \
    -extfile "$g/gateway.ext" -out "$g/tls.crt" >/dev/null 2>&1
  k create configmap fixture-ca -n gateway --from-file="ca-certificates.crt=$g/ca.crt"
  k create configmap fixture-ca -n identity --from-file="ca.crt=$g/ca.crt"
  k create secret tls gateway-tls -n gateway --cert="$g/tls.crt" --key="$g/tls.key"
  k create secret tls kanidm-tls -n identity --cert="$g/idm.crt" --key="$g/idm.key"
  d exec "$FIXTURE_NODE" sh -ec 'mkdir -p "$1"; chown 1000:1000 "$1"; chmod 0700 "$1"' \
    -- "$(setting identityDataPath)"
  apply identity
  k rollout status deployment/kanidm -n identity --timeout=300s
  apply direct
  condition gatewayclass envoy gateway Accepted True
  condition gateway household gateway Accepted True
  condition gateway household gateway Programmed True
  condition envoyproxy household gateway Accepted True
  condition clienttrafficpolicy trusted-edges gateway Accepted True
  route_ready origin
  route_ready idm
  condition backendtlspolicy idm identity Accepted True
  proxy_ready
  k rollout status deployment/origin -n origin --timeout=180s
  k rollout status deployment/origin -n gateway-admin-origin --timeout=180s
  for peer in "$FIXTURE_TRUSTED" "$FIXTURE_STRANGER"; do
    d exec "$peer" /bin/sh -c 'mkdir -p /fixture /root/.pki/nssdb /root/.local/share/pki/nssdb'
    d cp "$g/ca.crt" "$peer:/fixture/ca.crt"
  done
  # The unchanged browser uses canonical https origins (443). The listener is
  # client-local; its outbound socket traverses the owned Docker bridge, not NAT.
  d exec "$FIXTURE_TRUSTED" /bin/sh -c 'printf "127.0.0.1 %s %s\n" "$1" "$2" > /fixture/hosts; cat /etc/hosts >> /fixture/hosts; cat /fixture/hosts > /etc/hosts' sh "$idm" "$admin"
  d exec -d "$FIXTURE_TRUSTED" socat TCP-LISTEN:443,bind=127.0.0.1,reuseaddr,fork "TCP:$FIXTURE_NODE_IP:$node_port"
  for nss in /root/.pki/nssdb /root/.local/share/pki/nssdb; do
    d exec "$FIXTURE_TRUSTED" certutil -N -d "sql:$nss" --empty-password
    d exec "$FIXTURE_TRUSTED" certutil -A -d "sql:$nss" -n fixture-ca -t 'C,,' -i /fixture/ca.crt
  done
  k exec deployment/kanidm -n identity -- /sbin/kanidmd scripting recover-account idm_admin \
    -c /etc/kanidm/server.toml > "$g/recovery.json" 2> "$g/recovery.log"
  jq -er 'select(.status == "ok") | .output' "$g/recovery.json" > "$g/idm-admin-password"
  k create secret generic kanidm-provision -n identity --from-file="idm-admin-password=$g/idm-admin-password"
  apply identityDNS
  k rollout restart deployment/coredns -n kube-system
  k rollout status deployment/coredns -n kube-system --timeout=180s
  k patch deployment envoy-gateway -n gateway --type=strategic -p '{"spec":{"template":{"spec":{"volumes":[{"name":"fixture-ca","configMap":{"name":"fixture-ca"}}],"containers":[{"name":"envoy-gateway","env":[{"name":"SSL_CERT_FILE","value":"/fixture-ca/ca-certificates.crt"}],"volumeMounts":[{"name":"fixture-ca","mountPath":"/fixture-ca","readOnly":true}]}]}}}}'
  k rollout status deployment/envoy-gateway -n gateway --timeout=180s
  apply provision
  k wait job/kanidm-provision -n identity --for=condition=Complete --timeout=600s
  apply adminPolicies
  apply adminRoutes
  route_ready argocd
  condition backendtlspolicy kanidm-oidc-tls identity Accepted True '' argocd-admin SecurityPolicy
  condition securitypolicy argocd-admin gateway Accepted True
  d cp "$(setting authorization)" "$FIXTURE_TRUSTED:/fixture/authorization.py"
  d cp "$g/recovery.json" "$FIXTURE_TRUSTED:/fixture/recovery.json"
  rm -f "$g/recovery.json" "$g/recovery.log" "$g/idm-admin-password"
}
# The first fixed numeric witness survives cleanup for every native case.
# Lines include writeShellScriptBin's shebang; commands and values stay private.
gateway_error() {
  local result=$1 line=$2 caller=$2 frame
  if [ ! -e "$g/case-failure.json" ]; then
    for frame in "${BASH_LINENO[@]}"; do
      if [ "$frame" -gt 0 ]; then caller=$frame; fi
    done
    # The whole call stack, as line numbers and function names only.
    jq -cn --argjson scriptLine "$line" --argjson callerLine "$caller" --argjson returnCode "$result" \
      --args '{$scriptLine, $callerLine, $returnCode, frames: ($ARGS.positional | map(tonumber? // empty))}' \
      "${BASH_LINENO[@]}" > "$g/case-failure.json"
    jq -cn --args '$ARGS.positional' "${FUNCNAME[@]}" > "$g/case-failure-functions.json"
  fi
  return "$result"
}
rm -f "$g/case-failure.json"
set -E
trap 'gateway_error "$?" "$LINENO"' ERR
case "${1:?required gateway safety case}" in
  setup) setup ;;
  status)
    condition gatewayclass envoy gateway Accepted True
    condition gateway household gateway Accepted True
    condition gateway household gateway Programmed True
    condition envoyproxy household gateway Accepted True
    condition clienttrafficpolicy trusted-edges gateway Accepted True
    route_ready origin; route_ready idm; route_ready argocd
    condition backendtlspolicy idm identity Accepted True
    condition securitypolicy argocd-admin gateway Accepted True
    condition backendtlspolicy kanidm-oidc-tls identity Accepted True '' argocd-admin SecurityPolicy
    ;;
  direct)
    apply direct
    k delete networkpolicy private-origin -n gateway --ignore-not-found
    condition clienttrafficpolicy trusted-edges gateway Accepted True
    proxy_ready
    test "$FIXTURE_TRUSTED_IP" != "$FIXTURE_STRANGER_IP"
    test "$(positive "$FIXTURE_STRANGER" origin.test 'direct-probe?token=query-secret' \
      -H 'X-Forwarded-For: 198.51.100.9' -H 'X-Request-ID: client-supplied' \
      -H 'Authorization: Bearer bearer-secret' -H 'Cookie: session=cookie-secret')" = origin
    entry direct-probe '' 200
    jq -e --arg ip "$FIXTURE_STRANGER_IP" '.client == $ip and .request_id != "client-supplied" and .request_id != "" and .request_id != "-" and .request_id != null' "$g/entry.json" >/dev/null
    test "$(positive "$FIXTURE_TRUSTED" origin.test trusted-probe)" = origin
    entry trusted-probe '' 200
    jq -e --arg ip "$FIXTURE_TRUSTED_IP" '.client == $ip' "$g/entry.json" >/dev/null
    ;;
  cni-prepare)
    trusted
    ;;
  cni-enforce)
    # Wait up to 120s for actual negative enforcement. The Chainsaw step
    # timeout owns that deadline, not API status or a fixed sleep.
    until connection_denied; do sleep 1; done
    ;;
  cni-proof)
    test "$(positive "$FIXTURE_TRUSTED" origin.test trusted-probe)" = origin
    # After convergence, require three failures even with a spoofed trusted IP.
    for attempt in 1 2 3; do
      if ! connection_denied; then
        echo 'Untrusted bridge peer bypassed the production CNI ingress policy' >&2; exit 1
      fi
    done
    test "$(positive "$FIXTURE_TRUSTED" origin.test trusted-probe)" = origin
    ;;
  cni-forwarded)
    # Permit 30 metadata convergence attempts, each with a fresh ID so an
    # earlier access record cannot satisfy this one.
    for attempt in $(seq 0 29); do
      request_id="edge-request-$attempt"
      test "$(request "$FIXTURE_TRUSTED" origin.test trusted-probe --fail \
        -H 'X-Forwarded-For: 198.51.100.7' -H "X-Request-ID: $request_id")" = origin
      entry trusted-probe '' 200
      if jq -e --arg id "$request_id" '.client == "198.51.100.7" and .request_id == $id' "$g/entry.json" >/dev/null; then
        exit 0
      fi
      sleep 1
    done
    echo 'Trusted-edge forwarded address and request ID did not converge in 30 attempts' >&2
    exit 1
    ;;
  grant)
    trusted; idm_status 200 grant-before
    generation=$(k get httproute idm -n gateway -o jsonpath='{.metadata.generation}')
    k delete referencegrant gateway-idm -n identity
    k patch httproute idm -n gateway --type=json -p '[{"op":"add","path":"/spec/rules/0/timeouts","value":{"request":"16s","backendRequest":"15s"}}]'
    condition httproute idm gateway Accepted True
    condition httproute idm gateway ResolvedRefs False RefNotPermitted
    test "$(k get httproute idm -n gateway -o jsonpath='{.metadata.generation}')" -gt "$generation"
    idm_status 500 grant-missing
    trusted; route_ready idm; idm_status 200 grant-restored
    ;;
  name)
    trusted; idm_status 200 name-before
    generation=$(k get backendtlspolicy idm -n identity -o jsonpath='{.metadata.generation}')
    patch_validation '{"spec":{"validation":{"hostname":"wrong.test"}}}'
    condition backendtlspolicy idm identity Accepted True
    test "$(k get backendtlspolicy idm -n identity -o jsonpath='{.metadata.generation}')" -gt "$generation"
    idm_status 503 tls-wrong-name
    trusted; condition backendtlspolicy idm identity Accepted True; idm_status 200 tls-name-restored
    ;;
  ca)
    trusted; idm_status 200 ca-before
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=untrusted-ca \
      -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
      -keyout "$g/wrong-ca.key" -out "$g/wrong-ca.crt" >/dev/null 2>&1
    openssl x509 -req -in "$g/idm.csr" -CA "$g/wrong-ca.crt" -CAkey "$g/wrong-ca.key" -CAcreateserial -days 2 \
      -extfile "$g/idm.ext" -out "$g/untrusted-idm.crt" >/dev/null 2>&1
    for state in untrusted restored; do
      if [ "$state" = untrusted ]; then cert="$g/untrusted-idm.crt"; code=503; else cert="$g/idm.crt"; code=200; fi
      k create secret tls kanidm-tls -n identity --cert="$cert" --key="$g/idm.key" --dry-run=client -o yaml | k apply -f -
      k rollout restart deployment/kanidm -n identity
      k rollout status deployment/kanidm -n identity --timeout=180s
      route_ready idm; condition backendtlspolicy idm identity Accepted True
      idm_status "$code" "tls-ca-$state"
    done
    ;;
  browser)
    trusted; route_ready argocd; condition securitypolicy argocd-admin gateway Accepted True
    browser_rc=0
    d exec "$FIXTURE_TRUSTED" "$(setting python)" /fixture/authorization.py \
      "https://$idm" "https://$admin" "$(setting administrator)" /fixture/recovery.json /fixture/ca.crt \
      "$(setting chromium)" /fixture/auth-results || browser_rc=$?
    if [ "$browser_rc" -ne 0 ]; then
      d cp "$FIXTURE_TRUSTED:/fixture/auth-results/result.json" "$g/browser-result.json"
      jq '{httpStatus: (.http_status // 0), firstLine: (.fixture_lines[0] // 0), lastLine: (.fixture_lines[-1] // 0)}' \
        "$g/browser-result.json" >"$g/browser-failure.json"
      exit "$browser_rc"
    fi
    d cp "$FIXTURE_TRUSTED:/fixture/auth-results/result.json" "$g/browser-result.json"
    jq -e '.administrator.native_passkey_authenticated and .administrator.origin_status == 200 and
      .nonmember.native_passkey_authenticated and .nonmember.native_scope_denial_status == 403 and
      .nonmember.origin_redirect_status == 302 and .tampered_session_denied' "$g/browser-result.json" >/dev/null
    k delete secret kanidm-provision -n identity
    ;;
  privacy)
    trusted
    for spoof in anonymous bearer cookie identity; do
      case "$spoof" in
        anonymous) set -- ;;
        bearer) set -- -H 'Authorization: Bearer bearer-secret' ;;
        cookie) set -- -H 'Cookie: BearerToken=cookie-secret; OauthHMAC=cookie-secret' ;;
        identity) set -- -H "X-Forwarded-User: $(setting administrator)" -H "X-Auth-Request-User: $(setting administrator)" ;;
      esac
      status=$(request "$FIXTURE_TRUSTED" "$admin" 'index.html?token=query-secret' "$@" -o /fixture/spoof-response -w '%{http_code}')
      test "$status" = 302
      if d exec "$FIXTURE_TRUSTED" /bin/sh -c 'test "$(cat /fixture/spoof-response)" = origin'; then
        echo 'Spoofed authorization reached the origin' >&2; exit 1
      fi
    done
    status=$(request "$FIXTURE_TRUSTED" "$admin" 'oauth2/callback?code=callback-secret&state=invalid' -o /fixture/callback-response -w '%{http_code}')
    test "$status" = 401
    entry oauth2/callback '' 401
    # Require a successful real callback too; otherwise credential-log privacy
    # could pass without exercising authorization-code handling at all.
    entry oauth2/callback '' 302
    d cp "$FIXTURE_TRUSTED:/fixture/auth-results/sensitive.json" "$g/sensitive.json"
    d cp "$g/envoy.log" "$FIXTURE_TRUSTED:/fixture/envoy.log"
    d exec "$FIXTURE_TRUSTED" "$(setting python)" -c '
import json,pathlib
logs=pathlib.Path("/fixture/envoy.log").read_text()
values=json.loads(pathlib.Path("/fixture/auth-results/sensitive.json").read_text())
markers=["query-secret","bearer-secret","cookie-secret","callback-secret"]
assert values and all(value and value not in logs for value in values), "Real OIDC credentials reached Envoy access/error logs"
assert all(marker not in logs for marker in markers), "Synthetic credential marker reached Envoy access/error logs"
'
    d exec "$FIXTURE_TRUSTED" rm -f /fixture/envoy.log /fixture/auth-results/sensitive.json
    rm -f "$g/envoy.log" "$g/sensitive.json"
    ;;
  *) echo 'Unknown gateway safety case' >&2; exit 2 ;;
esac
