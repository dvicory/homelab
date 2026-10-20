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

Validate a persisted report through the same fail-closed entry point CI uses:

```sh
nix run path:.#verify-kubernetes-api -- --check-report ./api-result.json
```

This creates a pinned disposable K3s fixture with explicit credentials and
a loopback endpoint. It disables K3s's embedded network-policy controller,
uses nftables kube-proxy and applies the canonical unprivileged
`kube-network-policies` enforcer before the scenarios. It then removes its
containers, volumes and credentials.
Full acceptance requires the fixed safety-scenario inventory, actual passing
operations, no skips or mutation/scoping, and successful owned cleanup. The
`--remove-gateway-tls-cel` and `--argo-mutation` counterfactuals must fail;
an empty `--test-dir`, `--exclude-test-regex '.*'`, an unmatched `--selector`,
or a skipped scenario must also fail. Reports contain sanitized progress,
outcomes and setup/image/scenario/cleanup timings, not kubeconfigs or raw
assertion errors. A successful scoped experiment is not full acceptance.
Other frontends require an explicit compatible `--fixture-settings` closure;
amd64 emulation is not native ARM evidence.

Hosted CI joins successful native execution receipts with the required
schema/policy and genuine host/recovery groups; an omitted group cannot make
the aggregate pass. An evaluated inventory or built app alone is not execution
evidence. Unsupported platform rows remain explicit rather than forcing their
derivations or silently claiming native acceptance.

The native fixture's `/var/run/netns` propagation setup is confined to its
owned privileged Docker node. It does not change the host's mount propagation
or establish a production node-startup NetworkPolicy barrier.

The rendered policy accepts identity's configured hostname independently of
the application base domains and requires its cross-namespace certificate.
Native Gateway cases verify that certificate in direct and trusted-edge modes.
The application fixture certificate excludes the identity hostname, so fallback
certificate selection fails.
The backend CA negative changes only the owned Kanidm backend TLS volume,
leaving the frontend identity certificate and its cross-namespace grant intact.
The separate public-edge VM retains identity-host trust/name transitions,
cross-edge SNI refusal, queryless logging, upstream TLS recovery and failover.

## Retained host and recovery verification

`runtime-secret-k3s` retains the real host/systemd staging and acknowledgment
seam. `prod-home-replacement` and `compute-guest-upgrade` retain state-root
markers, ZFS/FUSE/Incus ID maps, mapped read-only media, credential delivery,
firewall/device behavior, source loss/return and application state through
guest replacement. Detailed Argo retirement moved to required native
scenarios; it no longer runs twice in the broad host scenario.

```sh
nix build --no-link \
  .#checks.x86_64-linux.runtime-secret-k3s \
  .#checks.x86_64-linux.prod-home-replacement \
  .#checks.x86_64-linux.compute-guest-upgrade \
  .#checks.x86_64-linux.prepare-luks-storage-runtime
```

Use a disposable native Linux builder with KVM and the checks' declared
resources. On a sandboxed builder, launch the upstream `.driver` directly for
checks declaring `__noChroot`, rather than weakening the host's sandbox. Each
driver owns its VM, final synchronization and shutdown. Do not run these
fixtures against production Docker, Incus, mounts or credentials.

Use `python3 modules/tests/compute-network-policy-runtime.py --self-test` for
portable observer regression checks. The real VM check still exercises traffic,
migration and recovery; API/exec errors fail rather than count as policy denial.

## Media verification

On native x86_64 Linux with Docker Engine 26+, `nix run .#media-live-acceptance -- --docker-host unix:///var/run/docker.sock --platform linux/amd64` runs the full pinned media API suite using packaged manifests/policy inputs and owned disposable Docker volumes, without production mounts or credentials. Hosted CI requires its execution, not merely building the runner; Kubernetes/Incus/recovery evidence remains separate.

Initial Docker fixture failures include bounded, escaped stderr. Successful
setup and later application output stay quiet; infrastructure errors do not
count as expected application refusals.

Native service behavior is the category-integration proof. SABnzbd owns its default `*` category; the local initializer checks must not equate its complete category inventory with the configured Arr instances.