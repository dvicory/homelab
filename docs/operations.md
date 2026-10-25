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

## Declared routes

| Service | Exposure | Canonical URL | Secondary URL | Backend | Auth |
| --- | --- | --- | --- | --- | --- |
| `argocd` | `public` | `https://argocd.plus2.danielvicory.dev` | `https://argocd.backup.plus2.danielvicory.dev` | `argocd/argocd-server:80` | `admin` |
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

For `direct` ingress, point each hostname at the host's LAN or Tailscale
address. TCP 443 forwards to the guest's NodePort. For `trustedEdges`,
point DNS at the edge.

## Retained state

| Retained key | Stable identity | Host path | Guest path | Guest UID:GID | Mode | Access |
| --- | --- | --- | --- | --- | --- | --- |
| `identity-kanidm` | `prod-home/identity-kanidm` | `/var/lib/homelab/compute-1/state/identity-kanidm` | `/srv/retained/state/identity-kanidm` | `1000:1000` | `0700` | writable |
| `jellyfin-config` | `prod-home/jellyfin-config` | `/var/lib/homelab/compute-1/state/jellyfin-config` | `/srv/retained/state/jellyfin-config` | `751:751` | `0750` | writable |
| `media-seerr-configuration` | `prod-home/media-seerr-configuration` | `/var/lib/homelab/compute-1/state/media-seerr-configuration` | `/srv/retained/state/media-seerr-configuration` | `1000:1000` | `0700` | writable |
| `prowlarr` | `prod-home/prowlarr` | `/var/lib/homelab/compute-1/state/prowlarr` | `/srv/retained/state/prowlarr` | `755:755` | `0700` | writable |
| `radarr` | `prod-home/radarr` | `/var/lib/homelab/compute-1/state/radarr` | `/srv/retained/state/radarr` | `752:752` | `0700` | writable |
| `sabnzbd` | `prod-home/sabnzbd` | `/var/lib/homelab/compute-1/state/sabnzbd` | `/srv/retained/state/sabnzbd` | `757:757` | `0700` | writable |
| `seerr` | `prod-home/seerr` | `/var/lib/homelab/compute-1/state/seerr` | `/srv/retained/state/seerr` | `1000:1000` | `0700` | writable |
| `sonarr` | `prod-home/sonarr` | `/var/lib/homelab/compute-1/state/sonarr` | `/srv/retained/state/sonarr` | `753:753` | `0700` | writable |

The default native runtime validates actual retained local-PV publications
before every init/app start, including cached restarts. The compared
`retained-directories` ConfigMap declares application identities; Argo does
not create or bless data. Missing/wrong state blocks affected writers, not
the node or unrelated applications. Source-mount loss retires dependent
native scopes. This is not continuous application-content verification or
a backup.

### Explicit provisioning and adoption

Root identity is `hvn-hyp1/compute-1/retained-v1`. Inspect the declared backing
in `/etc/homelab/retained-root.json` on the host before any mutation.
Ordinary validation is read-only:

```sh
retained-directories validate --spec /etc/homelab/retained-root.json --root
```

Only an explicitly authorized fresh root may use `provision --root`;
existing verified data uses `adopt --root`. Both require
`--confirm 'hvn-hyp1/compute-1/retained-v1'`. Neither repairs ownership,
overwrites data, or establishes that application contents are healthy.
A missing ledger is not permission to initialize replacement empty state.

Inside the guest, use the trusted node backing and compared inventory to
prepare an ephemeral CLI spec (requires `jq`). Select `ENTRY` and
`REVIEWED_ID` from that inspected inventory before validating an entry:

```sh
umask 077
k3s kubectl -n local-path-storage get configmap retained-directories -o json |
  jq --slurpfile node /etc/homelab/retained-node.json \
    '{version:1,root:$node[0].root,entries:(.data["directories.json"]|fromjson)}' \
    > /run/retained-spec.json
retained-directories validate --spec /run/retained-spec.json --entry "$ENTRY"
```

For one authorized new entry, run `retained-directories provision --spec
/run/retained-spec.json --entry "$ENTRY" --confirm "$REVIEWED_ID"`.
For one verified restored entry, use `adopt` instead. Provisioning cannot
recreate an established missing leaf; adoption requires an existing
directory and changes only its trusted identity ledger. New dynamic claims
use entry key `namespace.claimName`; declare and explicitly provision that
entry before expecting `retained-local` publication to succeed. No node OS
deployment, RuntimeClass, annotation or image opt-in is required.

### Restore an unavailable source

Keep the source absent while deleting affected Pods and waiting for their
old kubelet volume publications to disappear. Do not reattach underneath
stale publications. Restore the original backing and ledger. If the
restored root has a new filesystem identity, explicitly adopt the
verified root on the host with `retained-directories adopt --spec
/etc/homelab/retained-root.json --root --confirm 'hvn-hyp1/compute-1/retained-v1'`
before read-only root validation. After host validation succeeds, start
`compute-retained-export.service` and require successful publication.
Only then, inside the guest, explicitly adopt any verified restored
entries with changed identities and validate each required entry before
recreating affected Pods. Do not clear receipts or reprovision.
Unrelated services need no restart. Generation-bearing filesystem
export handles are required; unsupported filesystems fail closed rather
than trusting recycled inode numbers.

For an initial guard installation or guest-path migration, arrange the
approved affected-application/Argo hold before publishing to the tracked
ref; account for parent Applications restoring sync. Merging manifests
can reconcile running storage resources; it does not activate the OS or
automatically migrate data. Quiesce affected writers, retire their
Pods/publications and the old automatic creating-hook behavior first.
A removed desired hook may still have a retained live object.
Install the trusted host/guest boundary and explicitly adopt the verified
existing root. Validate it and start `compute-retained-export.service` on
the host; do not continue until publication succeeds.
StorageClass parameters and `PV.spec.local.path` are
immutable: separately authorize recreation of `retained-local` with the
new parameters while preserving existing PVs/data, then recreate affected
PV/PVC declarations at current guest paths rather than force-patching
bound volumes. Reconcile the compared inventory, explicitly adopt
verified existing entries, validate, then resume affected applications.
Never provision substitute empty state to clear a rollout refusal.
Routine host activation leaves the live retained parent and child export
mounted, even when their unit scripts or runtime package change. It does
not apply export/root changes to a running publication. For those changes,
arrange the same affected-writer/Argo hold, quiesce writers and retire
Pods/publications, then explicitly stop the export before activating
changed root/export configuration so its backing dependency cannot be
retargeted beneath an old publication. Validate the intended root with
the newly installed helper before explicitly starting the export and
resuming entry validation/workloads. Parent changes also
require a planned guest restart; do not replace a running guest's live
propagation parent. Actual backing/parent loss still stops the export
and retires affected writers; activation lifetime settings do not disable
that fail-closed boundary.

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
| `media/media-runtime` | `media--media-runtime--PROWLARR_API_KEY` → `PROWLARR_API_KEY`, `media--media-runtime--RADARR_API_KEY` → `RADARR_API_KEY`, `media--media-runtime--SABNZBD_API_KEY` → `SABNZBD_API_KEY`, `media--media-runtime--SEERR_API_KEY` → `SEERR_API_KEY`, `media--media-runtime--SONARR_API_KEY` → `SONARR_API_KEY` | `Opaque` |

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
DaemonSet) removes its rules first, so Pods are unprotected until the
new Pod is ready. To log each connection's verdict while
investigating a refusal, raise its `--v` argument to 2 in
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

- [`identity`](operations/identity.md)
- [`jellyfin`](operations/jellyfin.md)
- [`luks-storage-migration`](operations/luks-storage-migration.md)
- [`media`](operations/media.md)

