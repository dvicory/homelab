set -euo pipefail
inputs=$1
schemas=$2
validator=$3
reports=$4
mkdir -p "$reports"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -aL "$schemas/." "$work/schemas"
chmod -R u+w "$work/schemas"
policy_schema="$work/schemas/gateway.envoyproxy.io__clienttrafficpolicy__v1alpha1.json"
jq -e '.properties.spec.properties.headers.properties.requestID.enum | index("PreserveOrGenerate") != null' "$policy_schema" > /dev/null
jq '.properties.spec.properties.headers.properties.requestID.enum |= map(select(. != "PreserveOrGenerate"))' "$policy_schema" > "$work/changed.json"
mv "$work/changed.json" "$policy_schema"
# The exact native registry mutation remains compatible with actual direct mode.
"$validator" "$inputs/normal-ready-direct/manifests" "$work/schemas" "$reports/direct-still-valid.json"
if "$validator" "$inputs/normal-ready-trustedEdges/manifests" "$work/schemas" "$reports/trusted-enum-rejected.json"; then
  echo 'trusted-only request-ID schema counterfactual unexpectedly passed' >&2
  exit 1
fi
jq -e 'any(.resources[]; .kind == "ClientTrafficPolicy" and .status == "statusInvalid" and (.msg | contains("PreserveOrGenerate")))' "$reports/trusted-enum-rejected.json" > /dev/null
cp -aL "$inputs/normal-ready-direct/manifests/." "$work/normal"
chmod -R u+w "$work/normal"
yq -e '.kind == "Job" and .metadata.name == "kanidm-provision"' "$work/normal/identity/Job-kanidm-provision.yaml" > /dev/null
yq -i '.spec.parallelism = "not-an-integer"' "$work/normal/identity/Job-kanidm-provision.yaml"
if "$validator" "$work/normal" "$schemas" "$reports/normal-job-schema-rejected.json"; then
  echo 'normal-phase malformed Job schema counterfactual unexpectedly passed' >&2
  exit 1
fi
jq -e 'any(.resources[]; .kind == "Job" and .name == "kanidm-provision" and .status == "statusInvalid")' "$reports/normal-job-schema-rejected.json" > /dev/null
