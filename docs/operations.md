# Household operations

> This runbook is generated from the evaluated `prod-home` route, compute and runtime-secret declarations. It is a declaration reference, not a readiness result or production authorization.

Regenerate the committed copy after changing those declarations:

```sh
nix run .#write-operations
```

Run it from the repository root.

## Scope

This runbook covers the declared household guest, Kubernetes bootstrap
boundary, private service routes, retained state and runtime-secret
references. It separates guest lifecycle, static application delivery,
normal reconciliation and recovery. The tables below are generated from
Nix declarations; they do not inspect a live host or cluster.

**Stack:** `prod` / `prod-home` on `compute-1`
(`hvn-hyp1`), with Gateway API through private NodePort
`30443`.

Application-owned users, first-run owners, passkeys, libraries, media,
requests, history, dashboards and other records not named by a
declaration remain outside Nix ownership. Changes to Nix-managed fields
may be repaired by reconciliation.

Nothing here authorizes production deployment, destructive replacement,
credential creation, DNS/router changes or backup scheduling.

## Prerequisites

Before a mutating operation, obtain separate authorization for the
target environment and confirm the selected immutable flake revision.

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
- Run recovery only with a protected recovery destination, a matching
  descriptor and the exact packaged inventory. Keep recovery output and
  staged credentials outside Git and the Nix store.

## Declared access and routes

These addresses come from evaluated route declarations. The first
hostname is primary; the second is the declared backup address. Backup
access, canonical identity failover and DNS changes require separate
operation and verification.

| Service | Primary | Backup | Authentication | Declared backend |
| --- | --- | --- | --- | --- |
| `argocd` | `https://argocd.plus2.danielvicory.dev` | `https://argocd.backup.plus2.danielvicory.dev` | administrator browser gate; native APIs remain private | `argocd/argocd-server:80` |
| `grafana` | `https://grafana.plus2.danielvicory.dev` | `https://grafana.backup.plus2.danielvicory.dev` | administrator browser gate; native APIs remain private | `monitoring/monitoring-grafana:80` |
| `idm` | `https://idm.plus2.danielvicory.dev` | `https://idm.backup.plus2.danielvicory.dev` | native application authentication | `identity/kanidm:443` |
| `immich` | `https://immich.plus2.danielvicory.dev` | `https://immich.backup.plus2.danielvicory.dev` | native application authentication | `immich/immich-server:2283` |
| `jellyfin` | `https://jellyfin.plus2.danielvicory.dev` | `https://jellyfin.backup.plus2.danielvicory.dev` | native application authentication | `jellyfin/jellyfin:8096` |
| `radarr` | `https://radarr.plus2.danielvicory.dev` | `https://radarr.backup.plus2.danielvicory.dev` | administrator browser gate; native APIs remain private | `media/radarr:7878` |
| `requests` | `https://requests.plus2.danielvicory.dev` | `https://requests.backup.plus2.danielvicory.dev` | native application authentication | `media/seerr:5055` |
| `sabnzbd` | `https://sabnzbd.plus2.danielvicory.dev` | `https://sabnzbd.backup.plus2.danielvicory.dev` | administrator browser gate; native APIs remain private | `media/sabnzbd:8080` |
| `sonarr` | `https://sonarr.plus2.danielvicory.dev` | `https://sonarr.backup.plus2.danielvicory.dev` | administrator browser gate; native APIs remain private | `media/sonarr:8989` |

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
| `identity-kanidm` | `/var/lib/homelab/compute-1/state/identity-kanidm` | `/srv/state/identity-kanidm` | `1000:1000` | `0700` | writable |
| `immich-library` | `/var/lib/homelab/compute-1/state/immich-library` | `/srv/state/immich-library` | `1000:1000` | `0750` | writable |
| `immich-postgres` | `/var/lib/homelab/compute-1/state/immich-postgres` | `/srv/state/immich-postgres` | `999:999` | `0700` | writable |
| `jellyfin-config` | `/var/lib/homelab/compute-1/state/jellyfin-config` | `/srv/state/jellyfin-config` | `751:751` | `0750` | writable |
| `kubernetes-volumes` | `/var/lib/homelab/compute-1/state/kubernetes-volumes` | `/srv/state/kubernetes-volumes` | `0:0` | `0700` | writable |
| `media-data` | `/var/lib/homelab/compute-1/state/media-data` | `/srv/state/media-data` | `754:751` | `2770` | writable |
| `monitoring-alertmanager` | `/var/lib/homelab/compute-1/state/monitoring-alertmanager` | `/srv/state/monitoring-alertmanager` | `65534:65534` | `0750` | writable |
| `monitoring-grafana` | `/var/lib/homelab/compute-1/state/monitoring-grafana` | `/srv/state/monitoring-grafana` | `472:472` | `0750` | writable |
| `monitoring-loki` | `/var/lib/homelab/compute-1/state/monitoring-loki` | `/srv/state/monitoring-loki` | `10001:10001` | `0750` | writable |
| `monitoring-prometheus` | `/var/lib/homelab/compute-1/state/monitoring-prometheus` | `/srv/state/monitoring-prometheus` | `65534:65534` | `0750` | writable |
| `radarr` | `/var/lib/homelab/compute-1/state/radarr` | `/srv/state/radarr` | `752:751` | `0700` | writable |
| `sabnzbd` | `/var/lib/homelab/compute-1/state/sabnzbd` | `/srv/state/sabnzbd` | `754:751` | `0700` | writable |
| `seerr` | `/var/lib/homelab/compute-1/state/seerr` | `/srv/state/seerr` | `1000:1000` | `0700` | writable |
| `sonarr` | `/var/lib/homelab/compute-1/state/sonarr` | `/srv/state/sonarr` | `753:751` | `0700` | writable |

Jellyfin's legacy media export is a separate read-only attachment. It
is not part of the retained state table or the household recovery set.
The `retained-local` capability for ordinary Helm PVCs is documented in
the [retained-storage notes](../modules/den/aspects/kubernetes/services/retained-storage.md).

## Runtime-secret references

These rows contain references only. No plaintext value is rendered.
Agenix source files are materialized on the host and delivered to the
declared Kubernetes Secret keys before their consumers start. Never
copy secret values into Git, manifests, images or this document.

| Kubernetes Secret | Agenix source → key | Type |
| --- | --- | --- |
| `argocd/argocd-secret` | `argocd--argocd-secret--admin.password` → `admin.password`, `argocd--argocd-secret--admin.passwordMtime` → `admin.passwordMtime`, `argocd--argocd-secret--server.secretkey` → `server.secretkey` | `Opaque` |
| `gateway/gateway-tls` | `gateway--gateway-tls--ca.crt` → `ca.crt`, `gateway--gateway-tls--tls.crt` → `tls.crt`, `gateway--gateway-tls--tls.key` → `tls.key` | `kubernetes.io/tls` |
| `identity/kanidm-provision` | `identity--kanidm-provision--idm-admin-password` → `idm-admin-password` | `Opaque` |
| `identity/kanidm-tls` | `identity--kanidm-tls--ca.crt` → `ca.crt`, `identity--kanidm-tls--tls.crt` → `tls.crt`, `identity--kanidm-tls--tls.key` → `tls.key` | `kubernetes.io/tls` |
| `immich/immich-runtime` | `immich--immich-runtime--DB_PASSWORD` → `DB_PASSWORD` | `Opaque` |
| `media/media-runtime` | `media--media-runtime--JELLYFIN_OWNER_EMAIL` → `JELLYFIN_OWNER_EMAIL`, `media--media-runtime--JELLYFIN_OWNER_PASSWORD` → `JELLYFIN_OWNER_PASSWORD`, `media--media-runtime--JELLYFIN_OWNER_USERNAME` → `JELLYFIN_OWNER_USERNAME`, `media--media-runtime--RADARR_API_KEY` → `RADARR_API_KEY`, `media--media-runtime--SABNZBD_API_KEY` → `SABNZBD_API_KEY`, `media--media-runtime--SABNZBD_PASSWORD` → `SABNZBD_PASSWORD`, `media--media-runtime--SABNZBD_USERNAME` → `SABNZBD_USERNAME`, `media--media-runtime--SONARR_API_KEY` → `SONARR_API_KEY` | `Opaque` |
| `monitoring/grafana-admin` | `monitoring--grafana-admin--admin-password` → `admin-password`, `monitoring--grafana-admin--admin-user` → `admin-user` | `Opaque` |

## Deploy

Guest lifecycle and application delivery are separate. The lifecycle
command accepts `inspect`, `create` and `replace`; `replace` deletes an
existing guest only after its explicit confirmation.

```sh
compute-guest inspect
compute-guest create --bundle BUNDLE
compute-guest replace --bundle BUNDLE --confirm compute-1
```

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
absent Argo Applications, staged runtime credentials and the pinned
provisioning image before mutation. It does not create or delete
guests, deploy the host OS, publish Git or enable Argo.

The wrapper applies static namespaces, runtime Secrets and workload
resources without live Git or pruning. Normal Argo reconciliation is a
separate, explicit handoff after static delivery and native first-run
enrollment. Do not use environment-wide pruning or manual scale/copy
operations as a substitute.

## Verify

Run these commands with an explicitly selected `KUBECONFIG`:

```sh
household-bootstrap --status
household-bootstrap --check-ready
```

`--status` reports declared controllers and bootstrap Jobs without
mutation. `--check-ready` waits for the declared node, controllers and
persistent bootstrap Jobs. It does not prove application acceptance,
native first-run enrollment, authenticated clients, provider delivery,
GPU/transcoding behavior or backup success.

Inspect each service through its supported private route or native API.
Confirm that managed routes, mounts and Secret references match the
generated tables. Verify service connections against the selected
service declarations, and that application-owned records remain
present after a restart or reconciliation. Do not record a successful
apply as readiness.

An empty identity database still needs its native recovery-account and
passkey setup, and Jellyfin still needs its native first owner. Escrow
generated credentials through agenix/rekey and never put them in this
runbook.

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

A failed recovery operation leaves the guest and reconcilers stopped.
Inspect its journal and staged/displaced paths, correct the cause, and
do not resume blindly. There is no automatic rollback for a partial
restore.

## Recovery limits

The packaged recovery interface is:

```sh
household-recovery export|restore|resume DESCRIPTOR POINT METRICS_DIRECTORY
household-recovery --help
```

It is an investigation interface, not a routine backup recipe. Its
whole-stack export/restore procedure remains unverified and does not
establish guest-loss recovery, application-consistent capture or
production readiness. Follow the packaged guidance only when
investigating an explicitly authorized operation.

A recovery point contains only the declared retained set. Host identity,
runtime credentials, read-only media, external providers and any
undeclared application data need separate protection and reconstruction.
Same-host retained directories and exports do not survive loss or
corruption of that host and are not independent backups. Copy a complete
trusted point and its pinned inputs to a separately protected destination
only under the backup policy approved for the environment.

## Remaining gates

The declarations and commands above do not establish physical mount,
encryption, capacity, subordinate-ID or GPU evidence; production
credentials, DNS/router/provider changes; authenticated primary/backup
client access; routine capture/restore/resume results; independent
off-host backup; or production approval.
