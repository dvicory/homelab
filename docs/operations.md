<!-- provenance: generated from evaluated Den/Nix declarations by modules/den/aspects/kubernetes/operations.nix; keep the committed copy in sync. -->
# Household operations

> This runbook is generated from the evaluated `prod-home` route, compute and runtime-secret declarations. It is a declaration reference, not a readiness result or production authorization.

Regenerate the committed copy after changing those declarations:

```sh
nix run .#write-files
```

Run it from the repository root.

## Scope

This runbook covers the declared household guest, Kubernetes bootstrap
boundary, route inventory, retained state and runtime-secret
references. It separates guest lifecycle, static bootstrap, normal
reconciliation and recovery. The tables below are generated from Nix
declarations; they do not inspect a live host or cluster.

**Stack:** `prod` / `prod-home` on `compute-1`
(`hvn-hyp1`), with the declared ingress NodePort
`30443`. Route declarations are inventory
only; edge objects and public reachability belong to later cuts.

Application-owned users, first-run owners, passkeys, libraries, media,
requests, history, dashboards and other records not named by a
declaration remain outside Nix ownership. Changes to Nix-managed fields
may be repaired by reconciliation.

Nothing here authorizes production deployment, destructive replacement,
credential creation, DNS/router changes or backup scheduling.

## Prerequisites

Before a mutating operation, obtain separate authorization for the
target environment and identify the tracked deployment branch or ref.
Once that ref is active, a merge to it changes production desired state;
review approval alone does not change production state.

## Deployment flow

The evaluated delivery path is:

```text
Nix/Den -> rendered manifests -> pull request review ->
merge tracked deployment branch -> Argo reconciliation
```

Nix/Den declarations render the committed manifests. Review happens in
the pull request, and the active tracked branch/ref is the source Argo
reconciles. Do not substitute an approved commit or local checkout for
the tracked deployment ref.

- Review this file and the matching guest descriptor at
  `/etc/homelab/compute.json`.
- Run `compute-guest` only as root on the physical Linux Incus host. It
  uses the local Incus socket and checks the declared project, profile,
  identity, ID range and required mounted host paths.
- Keep runtime credentials in the existing agenix/rekey flow. The host
  bootstrap path expects staged files and never generates replacement
  identities.
- Use a fresh kubeconfig for the selected guest. After guest
  replacement, the old CA and client identity are stale.
- Select a private management path. The routes in this document do not
  prove reachable edges, certificates, DNS, router forwarding or login
  success.
- Run compute replacement only with surviving durable storage, staged
  runtime credentials, and the matching guest descriptor. Keep staged
  credentials outside Git and the Nix store.

## Declared access and routes

These addresses come from evaluated route declarations. The first
hostname is primary; the second is the declared backup address. Backup
access, canonical identity failover and DNS changes require separate
operation and verification.

| Service | Primary | Backup | Authentication | Declared backend |
| --- | --- | --- | --- | --- |
| `argocd` | `https://argocd.plus2.danielvicory.dev` | `https://argocd.backup.plus2.danielvicory.dev` | administrator browser gate; native APIs remain private | `argocd/argocd-server:80` |

`native` routes retain application-native authentication for supported
clients. `admin` routes use an administrator browser gate while native
API access remains private. Neither label proves a deployed TLS
certificate or successful login. The declared trusted proxy CIDRs are
`[]`.

## Declared retained state

The table is the evaluated compute attachment interface. Host paths are
owned by the host declaration; guest paths are the paths mounted into
the unprivileged guest. A retained directory is not an independent
backup.

| Retained key | Host path | Guest path | Guest UID:GID | Mode | Access |
| --- | --- | --- | --- | --- | --- |
| `kubernetes-volumes` | `/var/lib/homelab/compute-1/state/kubernetes-volumes` | `/srv/state/kubernetes-volumes` | `0:0` | `0700` | writable |

The host-owned media namespace is attached at the stable `/srv/media`
parent and remains outside the retained state table and household
recovery set. Included application aspects own any workload-specific
library or download mounts; this declaration does not imply consumers
are deployed.
Incus uses one-way host-to-guest mount propagation. Only the `data/`
child is the replaceable filesystem; binding that child directly would
retain a dead mount after source restoration. Recreate affected pods to
refresh workload subtree binds; the compute guest need not restart.
Ordinary Helm PVCs use the `retained-local` storage class; their
application-specific declarations enter with their owning aspects.

## Runtime-secret references

These rows contain references only. No plaintext value is rendered.
Agenix source files are materialized on the host and delivered to the
declared Kubernetes Secret keys before their consumers start. Never
copy secret values into Git, manifests, images or this document.

| Kubernetes Secret | Agenix source → key | Type |
| --- | --- | --- |
| `argocd/argocd-secret` | `argocd--argocd-secret--admin.password` → `admin.password`, `argocd--argocd-secret--admin.passwordMtime` → `admin.passwordMtime`, `argocd--argocd-secret--server.secretkey` → `server.secretkey` | `Opaque` |

## Deploy

Guest lifecycle and application delivery are separate. The lifecycle
command accepts `adopt`, `inspect`, `create` and `replace`; `replace`
deletes an existing guest only after its explicit confirmation.

```sh
compute-guest adopt
compute-guest inspect
compute-guest create --bundle BUNDLE
compute-guest replace --bundle BUNDLE --confirm compute-1
```

`adopt` checks existing project, pool, network and profile definitions
without changing them. Host preseed runs this check first and holds the
same lifecycle lock through the native preseed operation. A
conflicting resource stops preseed before it creates or changes resources.

Use `create` only when the declared guest is absent. Use `replace` only
when the destructive operation and retained-data prerequisites have
been authorized. `BUNDLE` must be an immutable guest bundle accepted by
the command; do not substitute a mutable checkout.

For an existing Running guest, the host wrapper performs the
non-destructive adoption and static delivery checks:

```sh
household-bootstrap-host /etc/homelab/compute.json --confirm compute-1
```

It verifies the target guest, fresh kubeconfig, declared node placement,
absent Argo Applications and runtime Secret metadata before mutation.
It does not create or delete guests, deploy the host OS, publish Git,
or generate credentials. Locally built workload images are delivered
through the guest's native K3s image inputs, not by the host wrapper.

The wrapper creates declared namespaces and waits for the guest's sole
runtime Secret writer to supply the declared types and keys. Only the
readiness result crosses back to the host, not Secret values. It then
applies the Argo namespace/controllers, waits for the seed, and applies
the canonical root Application. Argo then
owns workload reconciliation from Git. Do not statically apply application
workloads, use environment-wide pruning, or use manual scale/copy
operations as a substitute.

## Verify

Run these commands with an explicitly selected `KUBECONFIG`:

```sh
household-bootstrap --status
household-bootstrap --check-ready
```

`--status` reports Argo seed controllers and bootstrap Jobs without
mutation. `--check-ready` waits for the replacement node and Argo seed.
Neither command proves child synchronization, workload acceptance,
application enrollment, client authentication, provider delivery,
GPU/transcoding behavior or production approval.

This platform cut has no application service acceptance to inspect.
Later workload and edge cuts own service routes, native APIs, first-run
enrollment, and application-owned records. Do not record a successful
bootstrap apply as workload readiness.

Keep service-specific requirements with their owning declaration.
Escrow generated credentials through agenix/rekey and never put them in
this runbook.

## Failure handling

Static bootstrap refuses to mutate when it cannot inspect Argo ownership,
when Argo Applications already exist, when the target guest or node does
not match, or when staged runtime credentials are missing. Fix the
prerequisite and start a new explicit operation.

If a declared bootstrap hook Job is terminal `Failed`, and no Argo
Applications are present, retry only eligible declared hooks:

```sh
household-bootstrap --retry-jobs
```

Active, missing, unknown and non-terminal Jobs are refused. TTL-managed
Job completion is not retained as evidence. A failed guest lifecycle
operation leaves retained inputs in place and stops the guest when
possible; inspect the reported layer before retrying.

A failed bootstrap leaves the replacement guest and cluster in place.
Inspect the failed layer, correct the prerequisite, and start a new
explicit operation. Do not resume blindly and do not restore a prior
Kubernetes database over the replacement.

## Recovery limits

The supported compute-loss path is:

```text
replace guest -> stage secrets -> seed Argo -> apply root Application ->
Argo reconciles Git -> reattached storage serves applications
```

The instance root, Kubernetes datastore, container cache, and prior
identities are disposable. Host identity, runtime credentials, retained
application state and any external provider inputs need separate
protection and reconstruction by their owning cuts.

## Remaining gates

The declarations and commands above do not establish physical mount,
encryption, capacity, subordinate-ID or GPU evidence; production
credentials, DNS/router/provider changes; workload acceptance; or
production approval.

