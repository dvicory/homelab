<!-- provenance: generated from evaluated Den/Nix declarations by modules/den/aspects/kubernetes/operations.nix; keep the committed copy in sync. -->
# Household operations

## Current stack

- **Environment:** `prod`
- **Cluster:** `prod-home`
- **Host:** `hvn-hyp1` (`x86_64-linux`)
- **Compute guest:** `compute-1`
- **Ingress:** `direct` on NodePort `30443`
- **Identity phase:** `normal`

## Deploy configuration

Argo tracks `main` from `https://github.com/dvicory/homelab.git`.
Publishing to that ref can change running services.

```sh
nix run .#sync-prod-home-manifests
jj file track generated/manifests/prod-home
```

Commit the generated YAML and check `prod-home-manifests-fresh`
against that Git revision before syncing.

## Declared routes

| Service | Exposure | Canonical URL | Secondary URL | Backend |
| --- | --- | --- | --- | --- |
| `argocd` | `public` | `https://argocd.plus2.danielvicory.dev` | `https://argocd.backup.plus2.danielvicory.dev` | `argocd/argocd-server:80` |
| `idm` | `public` | `https://idm.plus2.danielvicory.dev` | `https://idm.backup.plus2.danielvicory.dev` | `identity/kanidm:443` |
| `jellyfin` | `private` | `https://jellyfin.plus2.danielvicory.dev` | `https://jellyfin.backup.plus2.danielvicory.dev` | `jellyfin/jellyfin:8096` |

Public edges publish only `public` routes. The `idm` canonical hostname
remains the identity issuer across direct and secondary-edge access;
failover changes DNS, not the issuer or certificate identity.

For `direct` ingress, point each hostname at the host's LAN or Tailscale
address. TCP 443 forwards to the guest's NodePort. For `trustedEdges`,
point DNS at the edge.

## Retained state

| Retained key | Host path | Guest path | Guest UID:GID | Mode | Access |
| --- | --- | --- | --- | --- | --- |
| `identity-kanidm` | `/var/lib/homelab/compute-1/state/identity-kanidm` | `/srv/state/identity-kanidm` | `1000:1000` | `0700` | writable |
| `jellyfin-config` | `/var/lib/homelab/compute-1/state/jellyfin-config` | `/srv/state/jellyfin-config` | `751:751` | `0750` | writable |
| `kubernetes-volumes` | `/var/lib/homelab/compute-1/state/kubernetes-volumes` | `/srv/state/kubernetes-volumes` | `0:0` | `0700` | writable |

A retained path is not a backup. Incus propagates host mounts one way;
after restoring a source, recreate affected pods to refresh child
mounts.

Wait for `retained-storage` to become Healthy before syncing stateful
applications. Its `retained-directories` hook creates the declared
directories and refuses, rather than creating substitute data, when the
persistent state root is missing. The hook survives pruning and
Application deletion.

## Runtime-secret references

Manage operator secrets with `agenix edit` and rekey under
`.secrets/hosts/`; use `agenix generate` for generated secrets.
Never put plaintext credentials or recovery output in Git, Nix
outputs, images, documentation, or logs.

| Kubernetes Secret | Source -> key | Type |
| --- | --- | --- |
| `argocd/argocd-secret` | `argocd--argocd-secret--admin.password` → `admin.password`, `argocd--argocd-secret--admin.passwordMtime` → `admin.passwordMtime`, `argocd--argocd-secret--server.secretkey` → `server.secretkey` | `Opaque` |
| `cert-manager/cloudflare-api-token` | `cert-manager--cloudflare-api-token--api-token` → `api-token` | `Opaque` |
| `identity/kanidm-provision` | `identity--kanidm-provision--idm-admin-password` → `idm-admin-password` | `Opaque` |
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

For `READY=False`, inspect the Certificate's `status.conditions` and
run `kubectl -n cert-manager describe challenge`. Avoid repeated
issuance attempts: Let's Encrypt production rate limits can block
recovery.

## Lifecycle and bootstrap

Build both bundles from the same commit on the physical Linux Incus host:

```sh
nix build .#nixosConfigurations.compute-1.config.system.build.computeBundle --out-link guest-bundle
nix build .#packages.x86_64-linux.household-bootstrap-bundle --out-link bootstrap-bundle
```

Run guest lifecycle commands as root.

Adopt and inspect an existing guest:

```sh
compute-guest adopt
compute-guest inspect
```

Create a new guest:

```sh
compute-guest create --bundle ./guest-bundle
```

Replace an existing guest (**destructive**):

```sh
compute-guest replace --bundle ./guest-bundle --confirm compute-1
```

Once the new or replacement guest is Running, bootstrap it as root:

```sh
./bootstrap-bundle/bin/household-bootstrap-host /etc/homelab/compute.json --confirm compute-1
```

## Verify

With `KUBECONFIG` selecting the guest's cluster:

```sh
./bootstrap-bundle/bin/household-bootstrap --status
./bootstrap-bundle/bin/household-bootstrap --check-ready
```

`--check-ready` covers the node, Argo seed, and bootstrap Jobs.
Also verify service routes, TLS, and native login.

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

## Service runbooks

- [`identity`](operations/identity.md)
- [`jellyfin`](operations/jellyfin.md)
- [`luks-storage-migration`](operations/luks-storage-migration.md)

