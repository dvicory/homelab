<!-- provenance: generated from evaluated Den/Nix declarations by modules/den/aspects/kubernetes/operations.nix; keep the committed copy in sync. -->
# Household operations

## Current stack

- **Environment:** `prod`
- **Cluster:** `prod-home`
- **Host:** `hvn-hyp1` (`x86_64-linux`)
- **Compute guest:** `compute-1`
- **Ingress:** `direct` on NodePort `30443`
- **Identity phase:** `normal`
- **Seerr publication phase:** `ready`
- **Homarr publication phase:** `initial`

## Deploy configuration

Argo tracks `main` from `https://github.com/dvicory/homelab.git`.
Publishing to that ref can change running services.

```sh
nix run .#sync-prod-home-manifests
jj file track generated/manifests/prod-home
```

Commit the generated YAML and check `prod-home-manifests-fresh`
against that Git revision before syncing.

A child Application's `ComparisonError` blocks later parent sync waves,
even when its existing workloads are Healthy. Inspect the child's
conditions and repair its source; normal reconciliation resumes when
the error clears and the child is healthy. This can delay unrelated
later-wave applications. It does not stop running workloads or pause
independently syncing child Applications.

## Software inventories and updates

`Software vulnerability inventory` collects declared host/compute roots,
exported packages and OCI images on source changes and twice weekly.
Host and image declarations are desired state; package exports are
exported state. Building or resolving an artifact does not make it deployed.
No live fleet dashboard or deployment discovery is installed by this workflow.

Download `security-plan` and the matching per-target inventory/report artifacts
from the workflow run. The plan lists unsupported targets and discovery
failures. Collection, provenance or report errors fail their jobs; a missing
report is not a successful scan. Artifacts are retained for 90 days.

Native inventories retain the original SBOM, closure/patch evidence and
opaque-path ledger. `native-identity.cdx.json` is a derived companion:
its `nix_drv` PURL qualifier carries the actual Nix derivation path without
changing package versions or CPEs. `native-identity.provenance.json` binds
the original, derived inventory and identity changes. Keep originals;
normalized dashboard exports need not preserve all source evidence.

Saved inventories can be rescanned with current advisory data without
rebuilding software or querying hosts/registries. Reuse verifies source,
producer, target identity and file hashes.
Reused image inventories keep the original software evidence; their
Homelab references come from the current plan, not the original scan.
Automated consumers use `.github/security_artifacts.py` to verify the trusted
producer and sealed files. Its `discover_plan(..., run_id=...)` recovery
option selects an exact run without bypassing source, event or artifact checks.
Scanner configuration and ignore files from the repository are not loaded. Raw portable reports
remain downloadable; this workflow does not submit Code Scanning alerts.

Version/CPE matches are candidates, not Nix backport or runtime-reachability
decisions. Missing versions/CPEs and opaque paths remain unknown coverage.
Referenced lockfiles and fixtures do not prove their software is deployed.
Complete artifact collection is not complete vulnerability coverage.

`Dependency update PRs` prepares ordinary Nix input and declared-source
updates with read authority. Candidate evaluation and generation run in a
disposable checkout/private store; package builds use unprivileged Nix
build users. A separate publisher accepts validated regular-file patches
with validated source revisions and exact updater-branch leases, not
executable candidate code. It never merges or activates software.
Unsupported source policies and incomplete coupled
releases remain explicit refusals, not guessed updates.
Publishers recheck main immediately before pushing and refuse already-stale
candidates. Main can still advance after that check; review against current
main before merging.

Read-only preparation does not require PR-creation permission. Publishing
requires GitHub's Settings → Actions → General → Workflow permissions →
Allow GitHub Actions to create and approve pull requests. Keep default
token permissions read-only and write authority confined to publisher jobs;
successful default-token publication still needs qualification.

Approve pending CI runs or dispatch Nix CI on an updater branch before
reviewing a merge. Merging generated manifests to main can roll out
services through Argo; host activation remains separate.

## Declared routes

| Service | Exposure | Canonical URL | Secondary URL | Backend | Auth |
| --- | --- | --- | --- | --- | --- |
| `argocd` | `public` | `https://argocd.plus2.danielvicory.dev` | `https://argocd.backup.plus2.danielvicory.dev` | `argocd/argocd-server:80` | `admin` |
| `grafana` | `public` | `https://grafana.plus2.danielvicory.dev` | `https://grafana.backup.plus2.danielvicory.dev` | `monitoring/grafana:80` | `admin` |
| `home` | `public` | `https://home.plus2.danielvicory.dev` | `https://home.backup.plus2.danielvicory.dev` | `portal/homarr:7575` | `native` |
| `idm` | `public` | `https://id.bzfx.net` | `not declared` | `identity/kanidm:443` | `native` |
| `jellyfin` | `private` | `https://jellyfin.plus2.danielvicory.dev` | `https://jellyfin.backup.plus2.danielvicory.dev` | `jellyfin/jellyfin:8096` | `native` |
| `prowlarr` | `public` | `https://prowlarr.plus2.danielvicory.dev` | `https://prowlarr.backup.plus2.danielvicory.dev` | `media/prowlarr:9696` | `admin` |
| `radarr` | `public` | `https://radarr.plus2.danielvicory.dev` | `https://radarr.backup.plus2.danielvicory.dev` | `media/radarr:7878` | `admin` |
| `requests` | `public` | `https://requests.plus2.danielvicory.dev` | `https://requests.backup.plus2.danielvicory.dev` | `media/seerr:5055` | `native` |
| `sabnzbd` | `public` | `https://sabnzbd.plus2.danielvicory.dev` | `https://sabnzbd.backup.plus2.danielvicory.dev` | `media/sabnzbd:8080` | `admin` |
| `sonarr` | `public` | `https://sonarr.plus2.danielvicory.dev` | `https://sonarr.backup.plus2.danielvicory.dev` | `media/sonarr:8989` | `admin` |

`admin` requires Gateway administrator sign-in; `native` uses the
application's own sign-in.

Public edges publish only `public` routes. The `idm` canonical hostname
remains the identity issuer across direct and secondary-edge access;
failover changes DNS, not the issuer or certificate identity.

The `home` route is omitted from Gateway and edges until
Homarr is `ready` and identity is `normal`. Complete private onboarding
and audience checks in [the Homarr runbook](operations/homarr.md)
before publishing it.

For `direct` ingress, point each hostname at the host's LAN or Tailscale
address. TCP 443 forwards to the guest's NodePort. For `trustedEdges`,
point DNS at the edge.

## Retained state

| Retained key | Host path | Guest path | Guest UID:GID | Mode | Access |
| --- | --- | --- | --- | --- | --- |
| `homarr` | `/var/lib/homelab/compute-1/state/homarr` | `/srv/state/homarr` | `1000:1000` | `0700` | writable |
| `identity-kanidm` | `/var/lib/homelab/compute-1/state/identity-kanidm` | `/srv/state/identity-kanidm` | `1000:1000` | `0700` | writable |
| `jellyfin-config` | `/var/lib/homelab/compute-1/state/jellyfin-config` | `/srv/state/jellyfin-config` | `751:751` | `0750` | writable |
| `kubernetes-volumes` | `/var/lib/homelab/compute-1/state/kubernetes-volumes` | `/srv/state/kubernetes-volumes` | `0:0` | `0700` | writable |
| `media-seerr-configuration` | `/var/lib/homelab/compute-1/state/media-seerr-configuration` | `/srv/state/media-seerr-configuration` | `1000:1000` | `0700` | writable |
| `monitoring-metrics` | `/var/lib/homelab/compute-1/state/monitoring-metrics` | `/srv/state/monitoring-metrics` | `3100:3100` | `0700` | writable |
| `prowlarr` | `/var/lib/homelab/compute-1/state/prowlarr` | `/srv/state/prowlarr` | `755:755` | `0700` | writable |
| `radarr` | `/var/lib/homelab/compute-1/state/radarr` | `/srv/state/radarr` | `752:752` | `0700` | writable |
| `sabnzbd` | `/var/lib/homelab/compute-1/state/sabnzbd` | `/srv/state/sabnzbd` | `757:757` | `0700` | writable |
| `seerr` | `/var/lib/homelab/compute-1/state/seerr` | `/srv/state/seerr` | `1000:1000` | `0700` | writable |
| `sonarr` | `/var/lib/homelab/compute-1/state/sonarr` | `/srv/state/sonarr` | `753:753` | `0700` | writable |

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

For a single-line credential that must not end in a newline, run this
in Bash at the repository root, replacing `<source>` with its table
entry. Input is hidden and kept out of command arguments; the temporary
editor contains only commands, never the credential:

```sh
(
  set +x
  umask 077
  editor=$(mktemp)
  trap 'rm -f "$editor"' EXIT
  cat >"$editor" <<'BASH'
IFS= read -rsp 'Secret: ' value || exit 1
printf '\n'
printf '%s' "$value" > "$1"
BASH
  EDITOR="bash $editor" agenix edit ".secrets/hosts/compute-1/<source>.age"
)
```

Track new encrypted sources with `jj file track` before running
`agenix rekey`, so the Git-backed flake includes their conditional
declarations. Track any new encrypted host rekeys too, then commit
the sources and rekeys before following the deployment procedure.
Do not commit plaintext or invent replacement values for unavailable secrets.

| Kubernetes Secret | Source -> key | Type |
| --- | --- | --- |
| `argocd/argocd-secret` | `argocd--argocd-secret--admin.password` → `admin.password`, `argocd--argocd-secret--admin.passwordMtime` → `admin.passwordMtime`, `argocd--argocd-secret--server.secretkey` → `server.secretkey` | `Opaque` |
| `cert-manager/cloudflare-api-token` | `cert-manager--cloudflare-api-token--api-token` → `api-token` | `Opaque` |
| `identity/kanidm-provision` | `identity--kanidm-provision--idm-admin-password` → `idm-admin-password` | `Opaque` |
| `jellyfin/jellyfin-admin` | `jellyfin--jellyfin-admin--password` → `password` | `Opaque` |
| `media/media-runtime` | `media--media-runtime--PROWLARR_API_KEY` → `PROWLARR_API_KEY`, `media--media-runtime--RADARR_API_KEY` → `RADARR_API_KEY`, `media--media-runtime--SABNZBD_API_KEY` → `SABNZBD_API_KEY`, `media--media-runtime--SEERR_API_KEY` → `SEERR_API_KEY`, `media--media-runtime--SONARR_API_KEY` → `SONARR_API_KEY` | `Opaque` |
| `monitoring/alertmanager-delivery` | `monitoring--alertmanager-delivery--heartbeat-url` → `heartbeat-url`, `monitoring--alertmanager-delivery--pushover-token` → `pushover-token`, `monitoring--alertmanager-delivery--pushover-user-key` → `pushover-user-key`, `monitoring--alertmanager-delivery--telegram-bot-token` → `telegram-bot-token`, `monitoring--alertmanager-delivery--telegram-chat-id` → `telegram-chat-id` | `Opaque` |
| `monitoring/grafana-admin` | `monitoring--grafana-admin--admin-password` → `admin-password`, `monitoring--grafana-admin--secret-key` → `secret-key` | `Opaque` |
| `portal/homarr` | `portal--homarr--SECRET_ENCRYPTION_KEY` → `SECRET_ENCRYPTION_KEY` | `Opaque` |

## Certificates

cert-manager issues TLS in the cluster: the `letsencrypt-prod`
ClusterIssuer does Cloudflare DNS-01 (the `cloudflare-api-token` runtime
Secret) and writes `gateway-tls` in `gateway` and `kanidm-tls` in
`identity`.
The token must cover each certificate zone, including the canonical
identity zone; see [identity operations](operations/identity.md#canonical-name-and-certificate-renewal).
Gateway reads that identity certificate through its name-scoped grant;
application wildcard certificates remain separate.

Check issuance inside the guest:

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

The guest bundle keeps the native LXC `metadata.tar.xz`, `rootfs.tar.xz`
and `system` interface. Rootfs compression uses pixz level 0 to reduce
preparation time at the cost of a larger archive; the decompressed
guest payload and metadata are unchanged.
The production guest remains an unprivileged container. Do not substitute
a qcow2 disk or change its Incus instance type for this bundle; changing
backends requires a separately validated retained-data handoff.

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

## Private Dependency-Track (available, not enrolled)

`kubernetes.services.dependency-track` is an opt-in stock API/frontend
integration. No fleet includes it, and no public route, host listener,
trusted-interface rule or ingress identity client is created.
Selecting it still requires placement/resource admission and working
NetworkPolicy enforcement; this is independent of any CNI or guest
backend migration. Its 1344MiB/2CPU limits are a bounded pilot budget,
not full-feed or full-fleet capacity qualification.

After an explicit deployment admission, use the existing authenticated
Kubernetes administrative path with two loopback-only forwards:

```sh
kubectl -n dependency-track port-forward --address 127.0.0.1 service/dependency-track-api 18080:8080
kubectl -n dependency-track port-forward --address 127.0.0.1 service/dependency-track-frontend 18081:8080
```

The stock UI is `http://127.0.0.1:18081`; its browser API URL defaults
to `http://127.0.0.1:18080`. Keep both forwards on the same operator
machine. Public exposure, central sign-in and automatic acquisition
are not inferred from selecting this service.

The task scheduler and telemetry default off. Before accepting
inventories, rotate the stock bootstrap password and disable remote
analyzers, package repositories, KEV and EPSS through the native
administrative interface. Egress allows PostgreSQL, cluster DNS and
public HTTPS; the stock outbound policy further restricts HTTP
destinations to `storage.googleapis.com` and `nvd.nist.gov`.

Apply the packaged, source-owned advisory policy using an existing
mode-0600 administrative session file, not the ingestion key:

```sh
dependency-track-sync configure --api-url http://127.0.0.1:18080 --admin-session-file "$DT_ADMIN_SESSION_FILE"
```

This idempotent command disables GitHub and JVN sources, enables
official NVD and OSV Go data, and verifies configuration readback.
It neither grants credentials nor starts an import. Other language
ecosystems remain outside this profile.
Admit the first mirrors separately. Select `initialMirror = true`
with scheduled refresh off to serialize mirror work and pause
analysis/import workers. Drain existing work first; a disabled worker
does not cancel queued activity. Keep a consistent DB/API-keyset
recovery point. A failed or uncertain NVD import requires recovery
disposition before any retry; do not edit upstream watermarks.
Require each native mirror workflow, including its metrics tail, to
reach `COMPLETED`. Then leave initial-mirror mode and require
successful sequential project analyses.
Refresh the initial portfolio metrics through the supported
`GET /api/v1/metrics/portfolio/refresh` and require its workflow to
complete before trusting the first dashboard. Findings may already
exist while the dashboard still shows stale zeros. Dashboard totals
deduplicate advisory aliases; raw finding rows need not match them.
Only after that admission, select `advisoryRefresh = true` with
`initialMirror = false` for stock scheduled refresh. Activity,
analysis, reconciliation and artifact-import concurrency are bounded
separately; portfolio-dispatch concurrency alone is insufficient.
Do not enable the scheduler before applying and qualifying the policy.
More sources need separate capacity, destination and freshness checks.

Give the dedicated ingestion team only `VIEW_PORTFOLIO`,
`PORTFOLIO_MANAGEMENT` and `BOM_UPLOAD`. Those are the stock operation
permissions, not per-project credentials; use a dedicated private
instance and do not claim project-level key isolation.
Keep its key in a mode-0600 file for manual use:

```sh
dependency-track-sync sync --api-url http://127.0.0.1:18080 --api-key-file "$DT_API_KEY_FILE" --inventory "$SEALED_INVENTORY" --state-dir "$RETAINED_EVIDENCE"
```

The source-owned CLI acquires only explicit artifact inputs and verifies
the producer seal; it neither enrolls the fleet nor uploads to Code
Scanning. Its `status` command reports missing, stale and failed coverage.
Projects follow actual Nix derivation/output or image/platform identity,
not report timestamps. Recollection may change only document UUID,
timestamp or JSON formatting without replacing accepted projects.
Changed software content for the same immutable root fails closed;
the last complete snapshot and every byte-exact original remain.
Cached projects must still have their expected identity, owner, parent
and leaf layout before activation, staging updates or retirement.
Failure status is published only after the same ownership check;
rejected collections keep the failure in the local journal.
The UI uses readable Host, Package and Image names; short display
suffixes do not replace full managed identity checks. Within Nix
targets, Nix packages lists the derivation-backed package inventory;
Contents scan lists Trivy's executable metadata, package metadata and
dependency declarations. Neither view proves software is executing.
Component Details → Properties exposes the preserved Trivy `PkgType`
and `Type`: `gobinary`/`rustbinary` are binary-associated metadata,
`cargo` is a lockfile catalogue, `node-pkg` is package-manifest identity,
and `python-pkg` is distribution-style metadata. The stock UI has no
arbitrary-property evidence filter. Do not hide declarations or call
all contents compiled libraries. The source Application/Library
classifier does not establish deployment or exposure.

For a host's Homelab inclusion paths, supply a separately trusted
`github:dvicory/homelab/<full-commit-SHA>` as `PINNED_HOMELAB_FLAKE`:

```sh
dependency-track-sync origins --api-url http://127.0.0.1:18080 --api-key-file "$DT_API_KEY_FILE" --inventory "$SEALED_INVENTORY" --state-dir "$RETAINED_EVIDENCE" --flake "$PINNED_HOMELAB_FLAKE"
```

The evaluated derivation/output must match the already-imported build.
Coverage currently includes `environment.systemPackages` and
`systemd.package`, not every option, exported package or image.
View Details → Properties shows inclusion paths and declarations;
the chain-link menu opens pinned source files. Unresolved paths remain
unknown, not guessed ownership. Original sealed inventories stay intact.

Source update preparation remains the existing artifact/update-PR path;
findings are not automatic merges, activations or package affectedness
decisions.

`workloads.dependency-track-sync` is a separate optional NixOS oneshot.
Select it on a host with the existing agenix and persistence profiles;
it does not enable those host-wide facilities or reconfigure storage.
Set its private `apiUrl` and admitted `inventoryDirectory` explicitly.
Its `onCalendar=null` default installs no timer. Its canonical evidence
and journal live at deliberately persisted
`/var/lib/dependency-track-sync`, owned by non-login UID/GID 705.
Supply `dependency-track-sync-api-key.age` under that host's secret
directory: the matching secret request and systemd credential pass a
file, not a key in argv or the Nix store. For a manually operated
compute-local ingestor, use the separately retained
`/srv/state/dependency-track-evidence` path (also 705:705).

### Dependency-Track bootstrap, backup and recovery

The normal `databasePhase=restore` refuses a missing encrypted database
credential, missing/non-18 PostgreSQL data, or a missing API encryption
keyset. Only an explicitly admitted empty new service may select
`bootstrap`; switch back to `restore` after initialization and secret
generation. Never use bootstrap to repair missing state.

Bootstrap creates the restricted `dtrack` owner of its dedicated database
and schema. `postgres` administration uses local Unix-socket peer
authentication, with no password or TCP access. The API refuses
elevated role flags or dangerous memberships on bootstrap and restore;
recover correct roles and object ownership rather than weakening that
check. The existing encrypted application password is the only DB secret.

Retain the three host-owned `dependency-track-postgres` (70:70),
`dependency-track-api` (1000:0) and `dependency-track-evidence` (705:705)
directories, their configured encrypted storage, and the original
agenix database credential. PostgreSQL18 uses
`/var/lib/postgresql/18/docker`; the stock API key-encryption keyset is
inside `/data/.dependency-track/keys`. DT-normalized exports are not
substitutes for sealed originals, companions, provenance or the journal.
No automatic evidence deletion is configured.

For a cold backup, first record and hold automated sync for both the
root `apps` Application and `dependency-track`, as in
[Homarr recovery](operations/homarr.md#full-portable-capture).
Stop every ingestor, including its timer. Scale
both API and PostgreSQL Deployments to zero and wait until all their
Pods have terminated. Do not copy while a writer remains or Argo can
restart one. Snapshot/copy all three retained host directories and the
encrypted secret source, then restore the recorded sync policies and
ingestion schedule. Restore the directories and credential together
with their declared ownership on encrypted retained storage before
reconstructing disposable compute/Kubernetes state.
Recreate static retained claims against those existing directories;
do not provision substitute storage or restore an old container cache,
root filesystem or Kubernetes object UID. Use `restore`, then start
PostgreSQL before the API and inspect native login and coverage.
Backup/restore rehearsal and retention/capacity qualification remain
rollout gates; no recovery SLA is introduced.

Images stay digest-bound to the tested stock API/frontend5.2.1 pair
and PostgreSQL18. Review API/frontend releases together. PostgreSQL
major or image-variant changes require an explicit migration and
identity review, never an independent automatic image upgrade.

## Verify

With `KUBECONFIG` selecting the guest's cluster:

```sh
./bootstrap-bundle/bin/household-bootstrap --status
./bootstrap-bundle/bin/household-bootstrap --check-ready
```

`--check-ready` covers the node, Argo seed, and bootstrap Jobs.
Also verify service routes, TLS, and native login.

### NetworkPolicy enforcement after a reboot

kube-network-policies (`kube-system/kube-network-policies`) enforces
NetworkPolicy; K3s's embedded controller is disabled. After every host
reboot, guest restart or guest replacement, check on the host, as root:

```sh
incus --project compute exec compute-1 -- \
  k3s kubectl -n kube-system rollout status daemonset/kube-network-policies --timeout=2m
incus --project compute exec compute-1 -- \
  journalctl -u k3s -b --no-pager -o cat |
  grep -E 'Failed to execute iptables-restore|Failed to run iptables-restore|nftables sync failed|Message too long'
```

The first command must report the DaemonSet rolled out. The second
must print nothing; a line means kube-proxy (in either its iptables or
its nftables mode) or another component failed to update the guest's
firewall.

The enforcer fails closed: while it is down with its rules in place,
every new Pod connection is refused, including allowed ones, until the
kubelet restarts it. A deliberate stop (deleting or updating the
DaemonSet) removes its rules first, leaving a gap until rules are
installed again. Its readiness probe checks metrics, not packet
enforcement. Connection verdict logging is off normally. To investigate
a refusal, set its `--log-verdicts` argument to `all` in
`kubernetes.services.network-policy`; Argo reverts edits made only in
the cluster.

### Remove kube-router's leftover rules

When K3s stops running its embedded controller, its iptables rules and
ipsets stay behind (k3s-io/k3s#7244) and keep applying stale
decisions to whatever Pod now holds an old address. From the
repository checkout on the host, as root:

```sh
incus --project compute exec compute-1 -- \
  sh -s < modules/den/aspects/kubernetes/_kube-router-cleanup.sh
```

It must end with `kube-router rules left: 0`. It is safe to repeat.

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

- [`homarr`](operations/homarr.md)
- [`identity`](operations/identity.md)
- [`jellyfin`](operations/jellyfin.md)
- [`luks-storage-migration`](operations/luks-storage-migration.md)
- [`media`](operations/media.md)
- [`monitoring`](operations/monitoring.md)

