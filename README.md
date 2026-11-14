<!-- provenance: generated from evaluated Den entities and Nixidy Gateway objects by modules/flake/docs/readme.nix; regenerate with nix run .#write-files. -->
# homelab

NixOS homelab and nix-darwin workstation configuration, composed with
[Den](https://github.com/denful/den) and flake-parts.

## Fleet

| Host | Environment | Platform | IPv4 | Managed guest of |
| --- | --- | --- | --- | --- |
| [`daniels-2021-mbp`](modules/den/hosts/daniels-2021-mbp/default.nix) | `home` | `aarch64-darwin` | — | — |
| [`builder`](modules/den/hosts/builder/default.nix) | `dev` | `aarch64-linux` | `192.168.65.90` | — |
| [`compute-1`](modules/den/hosts/compute-1/default.nix) | `prod` | `x86_64-linux` | `10.210.0.10` | [`hvn-hyp1`](modules/den/hosts/hvn-hyp1/default.nix) |
| [`hvn-hyp1`](modules/den/hosts/hvn-hyp1/default.nix) | `prod` | `x86_64-linux` | `172.27.50.17` | — |

## Services and topology

### `prod-home`

- **Kubernetes API:** `1.35.8`; ingress `direct` on NodePort `30443`.
- **Persistent state:** `/var/lib/homelab/compute-1/state` on [`hvn-hyp1`](modules/den/hosts/hvn-hyp1/default.nix), mounted at `/srv/state` in the guest. [Paths and owners](docs/operations.md#retained-state).
- **GitOps:** [generated manifests](generated/manifests/prod-home/), tracked from `main` by Argo CD. [Deployment runbook](docs/operations.md#deploy-configuration).

| Backend | Canonical hostname | Exposure | Route auth | In manifests |
| --- | --- | --- | --- | --- |
| `argocd/argocd-server` | [`argocd.plus2.danielvicory.dev`](https://argocd.plus2.danielvicory.dev/) | `public` | Gateway admin | yes |
| `monitoring/grafana` | [`grafana.plus2.danielvicory.dev`](https://grafana.plus2.danielvicory.dev/) | `public` | Gateway admin | yes |
| `portal/homarr` | `home.plus2.danielvicory.dev` | `public` | Application | no |
| `identity/kanidm` | [`id.bzfx.net`](https://id.bzfx.net/) | `public` | Application | yes |
| `jellyfin/jellyfin` | [`jellyfin.plus2.danielvicory.dev`](https://jellyfin.plus2.danielvicory.dev/) | `private` | Application | yes |
| `media/prowlarr` | [`prowlarr.plus2.danielvicory.dev`](https://prowlarr.plus2.danielvicory.dev/) | `public` | Gateway admin | yes |
| `media/radarr` | [`radarr.plus2.danielvicory.dev`](https://radarr.plus2.danielvicory.dev/) | `public` | Gateway admin | yes |
| `media/seerr` | [`requests.plus2.danielvicory.dev`](https://requests.plus2.danielvicory.dev/) | `public` | Application | yes |
| `media/sabnzbd` | [`sabnzbd.plus2.danielvicory.dev`](https://sabnzbd.plus2.danielvicory.dev/) | `public` | Gateway admin | yes |
| `media/sonarr` | [`sonarr.plus2.danielvicory.dev`](https://sonarr.plus2.danielvicory.dev/) | `public` | Gateway admin | yes |

**Route auth:** Gateway admin requires Kanidm administrator sign-in
in addition to any application checks. Application leaves sign-in
and access control to the app; it does not imply OIDC.

Routes reflect generated manifests, not live health.
[Route details and publication gates](docs/operations.md#declared-routes) cover secondary hostnames and onboarding.

## Operate and recover

- [Household operations](docs/operations.md): deployment, retained state and runtime secrets.
- [Identity](docs/operations/identity.md) · [Homarr](docs/operations/homarr.md) · [Media](docs/operations/media.md) · [Jellyfin](docs/operations/jellyfin.md) · [Monitoring](docs/operations/monitoring.md).
- [Storage layout](docs/storage.md) · [Disk migration](docs/operations/luks-storage-migration.md).

## Sources and checks

- [Cluster and route declarations](modules/den/clusters/home.nix) · [Service implementations](modules/den/aspects/kubernetes/services/) · [Compute lifecycle](modules/den/aspects/virtualization/compute.nix).
- [CI and local checks](CI.md) · [Regenerate this page](CI.md#regenerate-documentation).
- [Current contracts](openspec/specs/) · [Architecture decisions](docs/architecture/decisions/).
