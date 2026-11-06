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

Host deployment with deploy-rs `--test` changes the system profile and
running configuration, but not the boot-loader selection. Automatic
rollback requires the previous generation's `deploy-rs-activate` hook;
a plain NixOS profile needs a wrapper around its exact existing system first.

On an x86 Linux checkout, run `nix run path:.#stock-go-audit` to audit
the selected Incus daemon/client and Tailscale multicall ELF without
contacting their daemons. It checks compiled Go symbols, compiler and
linked module versions; application versions come from evaluated Nix.
It does not audit C libraries or replace application security review.

`nix flake update nixpkgs-security` updates the package-only input,
not the fleet's root Nixpkgs. Review source overrides and regenerate
dependency patches/vendor hashes when advancing supported releases.
Before restarting Incus, retain a stopped full-state backup and each
external storage pool; a profile rollback cannot undo database changes.

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

The shared direct listener also serves `private` routes. Do not forward
it to the Internet expecting the exposure label or missing DNS records
to protect those routes. Plan public ingress with an explicit private
access path: trusted-edge mode admits only declared edge peers at the
origin, while public edges omit private routes.

Incus TCP 8443 is not open on LAN or compute-guest interfaces. Use
Tailscale for remote API access, subject to tailnet access policy, or SSH
to the host and use its local Incus socket. The local SSH/socket recovery
path does not depend on the identity service.

Public edges retain queryless access records with upstream status and
request ID. journald drops whole nginx request-context error records,
so their detailed failure causes are lost. Lifecycle diagnostics remain
available; older retained logs are unchanged.

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

The enforcer fails closed while it is down with its rules in place:
every new Pod connection is refused, including allowed ones, until the
kubelet restarts it. A deliberate stop (deleting or updating the
DaemonSet) removes its rules first, leaving a gap until rules are
installed again. Initial startup also has no enforcement guarantee.
Its readiness probe checks metrics, not packet enforcement.
Close or qualify these lifecycle gaps before broader public exposure.
Connection verdict logging is off normally. To investigate a refusal,
set its `--log-verdicts` argument to `all` in
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

