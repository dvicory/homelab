<!-- provenance: generated from evaluated Den/Nix declarations by modules/den/aspects/kubernetes/operations.nix; keep the committed copy in sync. -->
# Household operations

## Current stack

- **Environment:** `prod`
- **Cluster:** `prod-home`
- **Host:** `hvn-hyp1` (`x86_64-linux`)
- **Compute guest:** `compute-1`
- **Ingress:** `direct` on NodePort `30443`
- **Identity phase:** `initial`
- **Seerr publication phase:** `initial`

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
| `prowlarr` | `public` | `https://prowlarr.plus2.danielvicory.dev` | `https://prowlarr.backup.plus2.danielvicory.dev` | `media/prowlarr:9696` |
| `radarr` | `public` | `https://radarr.plus2.danielvicory.dev` | `https://radarr.backup.plus2.danielvicory.dev` | `media/radarr:7878` |
| `requests` | `public` | `https://requests.plus2.danielvicory.dev` | `https://requests.backup.plus2.danielvicory.dev` | `media/seerr:5055` |
| `sabnzbd` | `public` | `https://sabnzbd.plus2.danielvicory.dev` | `https://sabnzbd.backup.plus2.danielvicory.dev` | `media/sabnzbd:8080` |
| `sonarr` | `public` | `https://sonarr.plus2.danielvicory.dev` | `https://sonarr.backup.plus2.danielvicory.dev` | `media/sonarr:8989` |

Public edges publish only `public` routes. The `requests` route is
declared public but is omitted from Gateway and edge configuration
while Seerr remains in the `initial` phase. The `idm` canonical hostname
remains the identity issuer across direct and secondary-edge access;
failover changes DNS, not the issuer or certificate identity.

## Kanidm bootstrap

The checked-in `initial` phase keeps the identity route private and
omits the provisioning credential, Job, and administrator policy.

Before the first identity deployment, provision a publicly trusted
Kanidm leaf certificate and key as `tls.crt` and `tls.key` in the declared
`identity/kanidm-tls` runtime Secret. This is a deployment prerequisite,
not an automated certificate issuance path.

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
| `prowlarr` | `/var/lib/homelab/compute-1/state/prowlarr` | `/srv/state/prowlarr` | `755:755` | `0700` | writable |
| `radarr` | `/var/lib/homelab/compute-1/state/radarr` | `/srv/state/radarr` | `752:752` | `0700` | writable |
| `sabnzbd` | `/var/lib/homelab/compute-1/state/sabnzbd` | `/srv/state/sabnzbd` | `757:757` | `0700` | writable |
| `seerr` | `/var/lib/homelab/compute-1/state/seerr` | `/srv/state/seerr` | `1000:1000` | `0700` | writable |
| `sonarr` | `/var/lib/homelab/compute-1/state/sonarr` | `/srv/state/sonarr` | `753:753` | `0700` | writable |

A retained path is not a backup. Incus propagates host mounts one way;
after restoring a source, recreate affected pods to refresh child
mounts.

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
`Movies` library at `/media`
and selected supported API settings.

## Seerr first-owner boundary

The checked-in `initial` phase starts Seerr privately. After Jellyfin's
patched initializer and Jellarr Job succeed, the media-configuration
PostSync Job uses Jellyfin's owned administrator Secret once to claim
Seerr's distinguished owner. It selects and synchronizes the `Movies`
library, then installs the standard Radarr and Sonarr connections.
The declared `media/media-runtime` `SEERR_API_KEY` is used for subsequent
reconciliation; it cannot authorize the pre-owner API.

Verify the Seerr Job succeeded, `/settings/public` reports
`initialized=true`, the `Movies` library remains enabled, and both
standard Arr servers have their intended profiles. Only then commit
`settings.kubernetes.services.seerr.phase = "ready"` and let Argo
publish the native-auth `requests` route. Never switch to `ready`
before first-owner initialization: the fresh setup page is claimable.
Configarr and Seerr perform immediate Git reconciliation and separate
six-hour repair runs; an unhealthy dependency must be repaired before
publishing Seerr.

## Runtime-secret references

This table contains references only. Never put plaintext Secret values
in Git, the Nix store, manifests, images, or this document.

| Kubernetes Secret | Agenix source -> key | Type |
| --- | --- | --- |
| `argocd/argocd-secret` | `argocd--argocd-secret--admin.password` → `admin.password`, `argocd--argocd-secret--admin.passwordMtime` → `admin.passwordMtime`, `argocd--argocd-secret--server.secretkey` → `server.secretkey` | `Opaque` |
| `gateway/gateway-tls` | `gateway--gateway-tls--ca.crt` → `ca.crt`, `gateway--gateway-tls--tls.crt` → `tls.crt`, `gateway--gateway-tls--tls.key` → `tls.key` | `kubernetes.io/tls` |
| `identity/kanidm-tls` | `identity--kanidm-tls--tls.crt` → `tls.crt`, `identity--kanidm-tls--tls.key` → `tls.key` | `kubernetes.io/tls` |
| `jellyfin/jellyfin-admin` | `jellyfin--jellyfin-admin--password` → `password` | `Opaque` |
| `media/media-runtime` | `media--media-runtime--PROWLARR_API_KEY` → `PROWLARR_API_KEY`, `media--media-runtime--RADARR_API_KEY` → `RADARR_API_KEY`, `media--media-runtime--SABNZBD_API_KEY` → `SABNZBD_API_KEY`, `media--media-runtime--SABNZBD_PASSWORD` → `SABNZBD_PASSWORD`, `media--media-runtime--SABNZBD_USERNAME` → `SABNZBD_USERNAME`, `media--media-runtime--SEERR_API_KEY` → `SEERR_API_KEY`, `media--media-runtime--SONARR_API_KEY` → `SONARR_API_KEY` | `Opaque` |

## Lifecycle and bootstrap

Run `compute-guest` as root on the physical Linux Incus host:

```sh
compute-guest adopt
compute-guest inspect
compute-guest create --bundle BUNDLE
compute-guest replace --bundle BUNDLE --confirm compute-1
```

`replace` is destructive and requires the exact
`--confirm compute-1` acknowledgement.

For a newly created or replacement Running guest before Argo handoff, run:

```sh
household-bootstrap-host /etc/homelab/compute.json --confirm compute-1
```

The host command validates the descriptor, guest, kubeconfig, node
placement, Argo state, and runtime-secret inventory before it mutates
namespaces, stages runtime Secrets, seeds Argo's restricted `default`
project, and applies the canonical root Application.

## Verify

```sh
household-bootstrap --status
household-bootstrap --check-ready
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
household-bootstrap --retry-jobs
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

