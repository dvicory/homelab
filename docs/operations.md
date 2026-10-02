<!-- provenance: generated from evaluated Den/Nix declarations by modules/den/aspects/kubernetes/operations.nix; keep the committed copy in sync. -->
# Household operations

## Current stack

- **Environment:** `prod`
- **Cluster:** `prod-home`
- **Host:** `hvn-hyp1` (`x86_64-linux`)
- **Compute guest:** `compute-1`
- **Ingress:** `direct` on NodePort `30443`
- **Identity phase:** `initial`

## Deployment flow

```text
Nix/Den -> rendered manifests -> pull-request review ->
merge tracked deployment ref -> Argo reconciliation
```

The host bootstrap hands the replacement guest to Argo through the
canonical root Application. Argo then reconciles the tracked deployment
ref.

Once this production path is active, merging generated manifests to
the tracked ref changes production desired state.

## Declared routes

| Service | Exposure | Canonical URL | Secondary URL | Backend |
| --- | --- | --- | --- | --- |
| `argocd` | `public` | `https://argocd.plus2.danielvicory.dev` | `https://argocd.backup.plus2.danielvicory.dev` | `argocd/argocd-server:80` |
| `idm` | `public` | `https://idm.plus2.danielvicory.dev` | `https://idm.backup.plus2.danielvicory.dev` | `identity/kanidm:443` |
| `jellyfin` | `private` | `https://jellyfin.plus2.danielvicory.dev` | `https://jellyfin.backup.plus2.danielvicory.dev` | `jellyfin/jellyfin:8096` |

Public edges publish only `public` routes. The `idm` canonical hostname
remains the identity issuer across direct and secondary-edge access;
failover changes DNS, not the issuer or certificate identity.

In `direct` ingress mode every declared hostname must resolve to an
address that reaches the physical host — its LAN uplink for LAN
clients or its Tailscale address for tailnet clients. The host DNATs
TCP 443 to the compute guest's NodePort without terminating TLS or
rewriting the client source, so the guest sees the real peer address.
In `trustedEdges` mode this forward does not exist and reachability is
the edge's responsibility.

## Kanidm bootstrap

The checked-in `initial` phase keeps the identity route private and
omits the provisioning credential, Job, and administrator policy.

Certificates are issued in-cluster by cert-manager through the
`letsencrypt-prod` ClusterIssuer (Let's Encrypt production, Cloudflare
DNS-01). The operator prerequisite is the Cloudflare DNS-edit token
`cert-manager--cloudflare-api-token--api-token` runtime secret;
`gateway/gateway-tls` and `identity/kanidm-tls` are Certificate
resources. Check issuance with `kubectl get certificate -A` and note
the shared Let's Encrypt rate limits.

1. Through an authorized private interactive `kubectl exec` session,
   run Kanidm `recover-account` for the stock accounts. Immediately
   escrow or encrypt the output; do not copy it into ordinary files.
2. Encrypt the `idm_admin` credential with agenix/rekey and commit
   `provisioning`. Wait for the identity Application's publication RBAC
   and PostSync provisioning Job to succeed. Administrator routes stay
   absent while the Job creates the named people and client.
3. Enroll durable human authentication for those people and verify
   native login over the private canonical identity route.
4. Commit `normal`; wait for the provisioning Job to grant administrator
   membership. Argo then publishes each administrator route together
   with its policy, ordered before the route.

Never persist plaintext recovery output in Git, generated files, CI,
service logs, durable agent transcripts, or ordinary workspace files.

The retained `identity-kanidm` path and Kanidm's native online-export
capability are facts for a future Preserve integration. This change
defines no capture schedule, retention, target, adapter, recovery point,
or restore policy.

## Retained state

| Retained key | Host path | Guest path | Guest UID:GID | Mode | Access |
| --- | --- | --- | --- | --- | --- |
| `identity-kanidm` | `/var/lib/homelab/compute-1/state/identity-kanidm` | `/srv/state/identity-kanidm` | `1000:1000` | `0700` | writable |
| `jellyfin-config` | `/var/lib/homelab/compute-1/state/jellyfin-config` | `/srv/state/jellyfin-config` | `751:751` | `0750` | writable |
| `kubernetes-volumes` | `/var/lib/homelab/compute-1/state/kubernetes-volumes` | `/srv/state/kubernetes-volumes` | `0:0` | `0700` | writable |

A retained path is not a backup. Incus propagates host mounts one way;
after restoring a source, recreate affected pods to refresh child
mounts.

The `retained-directories` Sync hook creates declared directories before
later waves in its own Application. It is not a cross-Application
declaration barrier: a consumer may be declared while the hook refuses,
but it cannot start against a missing directory or create substitute data.
Like the other retained-storage resources, the hook resists pruning and
Application deletion; `BeforeHookCreation` replaces the Job on the next
sync without removing retained data.

## Jellyfin storage and startup

The stable compute attachment is `/srv/media`; its replaceable merged
filesystem is `/srv/media/data`. Jellyfin consumes only the semantic
`/srv/media/data/library` directory, mounted read-only as `/media`.
`/config` is the statically bound retained volume. `/cache` is a
disposable 4 GiB `emptyDir` under a 5 GiB container ephemeral-storage
limit.

Before deployment, encrypt and rekey a strong, unique password for
Jellyfin administrator `daniel` as
`jellyfin--jellyfin-admin--password` for `compute-1`. Use the existing
password instead if restoring already initialized state; this secret
does not reset it. Missing input fails closed. The patched
initContainer creates the initial administrator through its internal
`SetupServer`. No stock-runtime backend is externally routable until
provisioning succeeds. The subsequent one-shot Jellarr Job owns the
`Movies` library at `/media/movies`, the `Shows` library at
`/media/tv`, and selected supported API settings.

## Runtime-secret references

This table contains references only. Never put plaintext Secret values
in Git, the Nix store, manifests, images, or this document. Each source
is either operator-supplied through agenix (`agenix edit`/rekey under
`.secrets/hosts/`) or a generated value produced by `agenix generate`.
`gateway-tls` and `kanidm-tls` are not listed: cert-manager issues them
in the cluster from its Cloudflare DNS-01 ClusterIssuer.

| Kubernetes Secret | Source -> key | Type |
| --- | --- | --- |
| `argocd/argocd-secret` | `argocd--argocd-secret--admin.password` → `admin.password`, `argocd--argocd-secret--admin.passwordMtime` → `admin.passwordMtime`, `argocd--argocd-secret--server.secretkey` → `server.secretkey` | `Opaque` |
| `cert-manager/cloudflare-api-token` | `cert-manager--cloudflare-api-token--api-token` → `api-token` | `Opaque` |
| `jellyfin/jellyfin-admin` | `jellyfin--jellyfin-admin--password` → `password` | `Opaque` |

## Certificates

cert-manager issues TLS in the cluster: the `letsencrypt-prod`
ClusterIssuer does Cloudflare DNS-01 (the `cloudflare-api-token` runtime
Secret) and writes `gateway-tls` in `gateway` and `kanidm-tls` in
`identity`. Check issuance inside the guest:

```sh
kubectl get clusterissuer letsencrypt-prod
kubectl get certificate -A
```

A `READY=False` Certificate's `status.conditions` and
`kubectl -n cert-manager describe challenge` name the failing step.
Let's Encrypt production limits repeated identical issuances, so a
flapping Certificate or weekly guest rebuilds will eventually stall
new issuance until the window clears.

## Lifecycle and bootstrap

Two artifacts are built from the same checkout of this repository on the
physical Linux Incus host:

```sh
nix build .#nixosConfigurations.compute-1.config.system.build.computeBundle --out-link guest-bundle
nix build .#packages.x86_64-linux.household-bootstrap-bundle --out-link bootstrap-bundle
```

`guest-bundle` is the guest image (`metadata.tar.xz`, `rootfs.tar.xz`,
`system`). `bootstrap-bundle` holds the bootstrap commands with their
pinned manifests (`bin/household-bootstrap-host`,
`bin/household-bootstrap`, `manifests/`).

Run `compute-guest` as root:

```sh
compute-guest adopt
compute-guest inspect
compute-guest create --bundle ./guest-bundle
compute-guest replace --bundle ./guest-bundle --confirm compute-1
```

`replace` is destructive and requires the exact
`--confirm compute-1` acknowledgement.

For a newly created or replacement Running guest before Argo handoff, run
as root:

```sh
./bootstrap-bundle/bin/household-bootstrap-host /etc/homelab/compute.json --confirm compute-1
```

The host command validates the descriptor, guest, kubeconfig, node
placement, Argo state, and runtime-secret inventory before it mutates
namespaces, stages runtime Secrets, seeds Argo's restricted `default`
project, and applies the canonical root Application.

## Verify

With `KUBECONFIG` selecting the guest's cluster:

```sh
./bootstrap-bundle/bin/household-bootstrap --status
./bootstrap-bundle/bin/household-bootstrap --check-ready
```

`--status` reports the declared Argo controllers and bootstrap Jobs.
`--check-ready` waits for the replacement node, Argo seed, and declared
bootstrap Jobs. Service acceptance additionally requires the route,
certificate, origin trust, and native-login checks owned by this edge
cut.

## Failure and retry

Fix the reported preflight prerequisite and start a new explicit
operation. Retry only declared terminal failed hook Jobs:

```sh
./bootstrap-bundle/bin/household-bootstrap --retry-jobs
```

Missing, active, unknown, or non-terminal Jobs are refused.

## Compute-loss recovery

```text
replace guest (attach retained state) -> verify retained mounts ->
stage runtime Secrets -> seed Argo -> apply root Application ->
Argo reconciles Git
```

Replace the disposable guest root, K3s datastore, cache, and object
identities from declared inputs; never restore the old K3s datastore
over the replacement.

