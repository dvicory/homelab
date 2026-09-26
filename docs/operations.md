<!-- provenance: generated from evaluated Den/Nix declarations by modules/den/aspects/kubernetes/operations.nix; keep the committed copy in sync. -->
# Household operations

## Current stack

- **Environment:** `prod`
- **Cluster:** `prod-home`
- **Host:** `hvn-hyp1` (`x86_64-linux`)
- **Compute guest:** `compute-1`
- **Descriptor:** `/etc/homelab/compute.json`

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

## Retained state

Host declarations own the source paths; guest paths are their
unprivileged mounts. The evaluated attachment inventory is:

| Retained key | Host path | Guest path | Guest UID:GID | Mode | Access |
| --- | --- | --- | --- | --- | --- |
| `kubernetes-volumes` | `/var/lib/homelab/compute-1/state/kubernetes-volumes` | `/srv/state/kubernetes-volumes` | `0:0` | `0700` | writable |

Incus propagates host mounts one way. After restoring a source,
recreate affected pods to refresh child mounts.

## Runtime-secret references

This table contains references only. Never put plaintext Secret values
in Git, the Nix store, manifests, images, or this document.

| Kubernetes Secret | Agenix source -> key | Type |
| --- | --- | --- |
| `argocd/argocd-secret` | `argocd--argocd-secret--admin.password` → `admin.password`, `argocd--argocd-secret--admin.passwordMtime` → `admin.passwordMtime`, `argocd--argocd-secret--server.secretkey` → `server.secretkey` | `Opaque` |

## Lifecycle and bootstrap

Run `compute-guest` as root on the physical Linux Incus host:

```sh
compute-guest adopt
compute-guest inspect
compute-guest create --bundle BUNDLE
compute-guest replace --bundle BUNDLE --confirm compute-1
```

`adopt` verifies the NixOS-owned Incus resources. Use `create` only
when the guest is absent. `replace` is destructive and requires the
exact `--confirm compute-1` acknowledgement.

For a newly created or replacement Running guest before Argo handoff, run:

```sh
household-bootstrap-host /etc/homelab/compute.json --confirm compute-1
```

The host command validates the descriptor, guest, kubeconfig, node
placement, Argo state, and runtime-secret inputs, then establishes
namespaces, runtime Secrets, Argo, and the canonical root Application.

## Verify

With the replacement guest selected in `KUBECONFIG`:

```sh
household-bootstrap --status
household-bootstrap --check-ready
```

`--status` is read-only and reports the declared Argo controllers and
bootstrap Jobs. `--check-ready` waits for the replacement node, Argo
seed, and declared bootstrap Jobs; success means the canonical root
Application can be applied.

## Failure and retry

If preflight cannot verify a required input, fix the reported
prerequisite and start a new explicit operation. A failed bootstrap
leaves the replacement guest in place; inspect the failed layer before
retrying.

```sh
household-bootstrap --retry-jobs
```

`--retry-jobs` recreates only declared terminal `Failed` hook Jobs.
Missing, active, unknown, or non-terminal Jobs are refused. Run
`--status` or `--check-ready` after a retry.

## Compute-loss recovery

```text
replace guest (attach retained state) -> verify retained mounts ->
stage runtime Secrets -> seed Argo -> apply root Application ->
Argo reconciles Git
```

The guest root, K3s datastore, container cache, and prior object
identities are disposable. Replace them from the declared inputs;
never restore the old K3s datastore over the replacement.

