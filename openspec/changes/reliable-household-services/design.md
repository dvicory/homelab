## Context

See [proposal.md](proposal.md) for scope. Current specs remain authoritative. The existing compute slice supplies an unprivileged Incus guest, K3s 1.35.8, Flannel/kube-proxy, host-retained state and an independent host management path. Its native Darwin recovery run currently fails at CoreDNS container creation; the earlier Lima proof is separate evidence. Production inspection, credentials, deployment, DNS changes and migration remain gated.

## Goals / Non-Goals

Use the operator's delegated authority to build useful, locally verifiable infrastructure. Generic contracts and mechanisms own delivery, storage, secrets, ingress and observability. Thin application aspects own upstream values and compatibility choices. Permanent tests defend our boundaries; representative application operations provide smoke evidence rather than duplicating upstream suites.

Do not replace the CNI, introduce distributed storage, migrate old service data, write a general application framework, or require a live identity/cluster service to repair its own substrate.

## Decisions

### Den composition and delivery

Reuse Sini's Den cluster entity, `k8s-manifests` class and cluster-to-Nixidy policy. Both repositories pin the same Den revision. Pass the existing nixpkgs package set and pinned nixhelm charts to Nixidy; keep host metadata in host entities and cluster metadata in a cluster entity. Do not copy Sini's unrelated overlays, fleet inventory, network/storage topology or update automation.

Use Nixidy-rendered upstream charts and native resources, with Argo CD as the normal per-application reconciler. Pin application versions independently of node OS releases. Retained namespaces/PVs/PVCs have explicit protection from automatic pruning and deletion. Keep a static bootstrap artifact for controller/CRD installation and a documented no-live-Git recovery path. A disposable Git repository can exercise reconciliation locally without publishing to the production origin.

Nixidy supports direct apply, but its environment-wide prune also includes namespaces and does not honor Argo retention annotations. It is not an unrestricted recovery shortcut. Recovery applies retained resources and selected workload manifests without pruning, with the normal reconciler paused when required. Resource retirement uses the selected owner and an explicit retained-data gate.

The existing K3s Jellyfin AddOn and Argo must never manage the same resources concurrently. Migrate the local fixture and operating commands in a clean cutover; a future production handoff is a separately authorized operation. Do not add another renderer or a Nixflix-to-Kubernetes translation layer.

### Storage and runtime secrets

Generalize the compute envelope's hard-coded application state into explicit retained-path declarations carrying host path, guest path, guest UID/GID, mode and read-only status. Preserve fixed non-root host ID translation, encrypted host persistence and the existing read-only legacy-media boundary. Fresh writable download/library paths are separate from legacy data. Static local PVs bind only declared paths and node placement; missing paths must not create substitute storage.

Keep agenix/rekey authoritative. Stage required runtime files on the physical host and expose a narrow read-only credential directory to the guest. Materialize named Kubernetes Secrets at runtime through the native API; secret references and file mappings may be rendered, plaintext values may not enter images, Nix store artifacts or Git. Reuse the existing missing-identity preflight pattern for unprovisioned production files. A secret operator and another encryption translation layer are not required merely to retain Sini's manifest composition.

Use application-consistent recovery boundaries: quiesce writers before exporting a matched set, validate before restore, and preserve displaced state. Standard database/native backup tools own application-specific formats; infrastructure owns ordering, retained inputs, permissions, completion publication and failure visibility. Same-host exports are recovery points, not independent backups.

### Thin service aspects

| Service group | Initial implementation choices |
| --- | --- |
| Jellyfin | Preserve the official pinned image, native authentication and read-only legacy media. Move resource rendering to the shared Nixidy path. CPU operation is the local baseline; GPU passthrough remains a hardware gate. |
| Immich | Official OCI Helm chart, matching server/CPU-ML release, dedicated VectorChord-compatible PostgreSQL and Valkey. Keep database and uploaded assets in one recovery set. Native OIDC is optional configuration with a local recovery account. Hostname root only. |
| Radarr / Sonarr / SABnzbd | Sini's bjw-s app-template shape, pinned multiarchitecture images, local configuration databases, consistent fresh download/library paths. Keep API-key authentication for internal automation and protect browser administration. Do not combine this fresh deployment with PostgreSQL migration. |
| Seerr | Official image/chart, one replica, retained configuration, internal Jellyfin service URL and user-facing external URL. Native Jellyfin/local sign-in; do not promise undocumented stable OIDC. |
| Monitoring | One kube-prometheus-stack release for Prometheus, Alertmanager, Grafana and kube-state-metrics; bounded Loki single-binary filesystem storage and an Alloy CRI-log collector. No monitoring PostgreSQL, HA or per-application logging sidecars. |

Nixflix directly owns NixOS/systemd services. Borrow narrowly useful idempotent API configuration patterns only when upstream declarative configuration or an existing tool cannot supply required service connections. Configarr/Recyclarr are existing choices for explicitly selected quality-policy fields, not reasons to overwrite backup-owned libraries, users or history.

### Independent public ingress and identity

Kubernetes application routes are the only per-service routing inventory. NixOS edges forward the declared domain families to the same private ingress; moving the public edge does not move workloads or make the edge a cluster member. Use existing Tailscale connectivity first, with explicit origin reachability and narrow trusted peer addresses; live tailnet changes remain gated.

Use a Gateway API implementation that works with the current CNI, not a CNI replacement. Prefer ordinary HTTP reverse proxying with TLS termination at each edge and authenticated, certificate-verified private transport to the origin. Overwrite client-supplied forwarding headers at the Internet edge and trust them only from declared peers at the origin. Backend bypass denial is part of runtime acceptance, not an assumed property of an OIDC login page.

The normal domain points to a colo/VPS edge. A normally available home edge serves a configurable backup domain. Prepare manual same-name DNS failover, accounting for TTL/cache delays. The accepted privacy goal is keeping home addressing out of normal service DNS, not preventing discovery. Neither entrance survives loss of the home connection or origin.

Preserve application-native authentication for public media/photo/request clients and centralize where supported. Kanidm is the preferred household identity service; its placement must not become a substrate recovery dependency. Browser-only administration uses strong identity and administrator authorization. Raw SSH, Kubernetes and database protocols remain private. Jellyfin's archived third-party SSO plugin is not a required dependency.

### Verification and operator handoff

Run the existing infrastructure recovery scenario where practical, but do not spend the work window repeatedly chasing a Darwin-only runtime limitation. Use the authorized disposable Linux environment for application/platform runtime evidence. Keep environment-specific failures visible.

Concentrate durable checks on evaluated storage/secret/access boundaries and the owned lifecycle. Exercise real rendered manifests, a representative retained marker/database set, route and authentication denial, Argo ownership/retirement, and Alertmanager firing/resolution against disposable destinations. Do not create per-application regression suites for upstream authentication, playback or library behavior. Record exact checks and unverified production/hardware/provider gates.

## Risks / Trade-offs

- Argo adds a controller and Git dependency for normal reconciliation; static bootstrap and non-pruning recovery artifacts must remain usable without live Git.
- Single-node local storage accepts planned outages and host failure. Host disk capacity and memory need production inspection before deployment.
- Missing runtime credentials intentionally block their consumers; they must not silently select anonymous access or generated replacement identities.
- Alternate hostnames may require coordinated canonical URL and OIDC callback changes. Immich does not support subpaths; reject incompatible routing.
- Image/chart versions evolve independently. Pin compatible pairs and inspect architecture support rather than copying Sini's amd64-only image pins.
- Declarative integration must not overwrite user-managed application state on restart or recovery.
