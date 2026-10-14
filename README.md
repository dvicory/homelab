# homelab

## Local verification

Schema, rendered policy and executed Argo health are separate required gates:

```sh
system=$(nix eval --impure --raw --expr builtins.currentSystem)
nix build --no-link \
  "path:.#checks.$system.prod-home-manifests-schema" \
  "path:.#checks.$system.prod-home-manifests-policy" \
  "path:.#checks.$system.argocd-application-health"
```

The schema gate validates original canonical YAML against pinned local
Kubernetes and exact tracked CRD schemas, rejects duplicate keys, and
accounts for every effective document. Its negative cases reject missing
schemas, collisions, empty input and skipped validation. Converted CRD
schemas do not prove CEL admission, all ObjectMeta rules, controller
behavior or traffic. Kyverno owns rendered repository confinement, ownership,
retention, lifecycle, authority, identity, Gateway and workload/storage policy.
The health gate executes Lua from the evaluated production Argo ConfigMap.

On x86_64 Linux, run the bundled native Gateway admission, runtime-Secret
ownership, Argo recovery and Gateway traffic/authorization scenarios with a
local Docker Unix-socket context and a new result filename:

```sh
nix run path:.#verify-kubernetes-api -- \
  --docker-context default --report ./api-result.json
```

This creates a pinned disposable K3s fixture with explicit credentials and
a loopback endpoint. It disables K3s's embedded network-policy controller,
uses nftables kube-proxy and applies the canonical unprivileged
`kube-network-policies` enforcer before the scenarios. It then removes its
containers, volumes and credentials.
Full acceptance requires all declared scenarios and successful cleanup. The
`--remove-gateway-tls-cel` mutation must fail; an empty `--test-dir`,
`--exclude-test-regex '.*'`, an unmatched `--selector`, or a skipped
scenario must also fail. Reports contain sanitized progress, outcomes and
timings, not kubeconfigs or raw assertion errors.
Other frontends require an explicit compatible `--fixture-settings` closure;
amd64 emulation is not native ARM evidence.

## Media verification

On native x86_64 Linux with Docker Engine 26+, `nix run .#media-live-acceptance -- --docker-host unix:///var/run/docker.sock --platform linux/amd64` runs the full pinned media API suite using packaged manifests/policy inputs and owned disposable Docker volumes, without production mounts or credentials. Hosted CI requires its execution, not merely building the runner; Kubernetes/Incus/recovery evidence remains separate.

Native service behavior is the category-integration proof. SABnzbd owns its default `*` category; the local initializer checks must not equate its complete category inventory with the configured Arr instances.