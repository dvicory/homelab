## Context

Current specs remain authoritative. The existing compute slice supplies an unprivileged Incus guest, K3s, Flannel/kube-proxy, host-retained state and an independent host management path. Current compute-loss recovery is guest replacement → staged secrets → Argo seed/root handoff → Git reconciliation → reattachment of retained state; no whole-stack export/restore/resume path is supported. The x86_64 `prod-home-replacement` acceptance and broader Argo handoff, ingress, backup and monitoring evidence remain incomplete. This plan records the reviewed direction; implementation and production activation remain separate.

## Goals / Non-Goals

Use the operator's delegated authority to build useful, locally verifiable infrastructure. Generic contracts and mechanisms own delivery, storage, secrets, ingress and observability. Thin application aspects own upstream values and compatibility choices. Permanent tests defend our boundaries; representative application operations provide smoke evidence rather than duplicating upstream suites.

Do not replace the CNI, introduce distributed storage, migrate old service data, write a general application or backup framework, or require a live identity/cluster service to repair its own substrate. Do not turn routine backup capture into whole-guest maintenance.

## Decisions

### Den composition and delivery

Reuse Sini's Den cluster entity, `k8s-manifests` class and cluster-to-Nixidy policy. Both repositories pin the same Den revision. Pass the existing nixpkgs package set and pinned nixhelm charts to Nixidy; keep host metadata in host entities and cluster metadata in a cluster entity. Do not copy Sini's unrelated overlays, fleet inventory, network/storage topology or update automation.

Use Nixidy-rendered upstream charts and native resources, with Argo CD as the normal per-application reconciler. Pin application versions independently of node OS releases. Retained namespaces/PVs/PVCs have explicit protection from automatic pruning and deletion. Keep a static bootstrap artifact for controller/CRD installation and explicit root-Application handoff; after handoff Argo reconciles canonical Git manifests. A disposable Git repository can exercise this transport locally without publishing to the production origin.

Nixidy supports direct apply, but its environment-wide prune also includes namespaces and does not honor Argo retention annotations. It is not an unrestricted recovery shortcut. Bootstrap applies only the retained Argo seed resources and then hands off to the root Application; Argo owns workload reconciliation, while retained-resource protection controls retirement.

Ordinary Helm and application-owned manifests are supported alongside optional Den/Nixidy integrations. Argo owns the resources assigned to it, not every workload admitted to the cluster. Standard storage and secret interfaces must work without a Homelab application definition. Retain the chart/version, values, Helm release records and required credentials for reconstruction; an unrecorded exploratory install does not acquire a recovery guarantee merely by using persistent storage.

The existing K3s Jellyfin AddOn and Argo must never manage the same resources concurrently. Migrate the local fixture and operating commands in a clean cutover; a production handoff requires separate authorization. Do not add another renderer or a Nixflix-to-Kubernetes translation layer.

Consolidate facts at their existing owners: host placement and retained storage, application endpoints and container identities, environment domains, and shared agenix master identities. Project those declarations into mounts, PVs, routes, recovery membership and generated references rather than restating them. Reject missing environment/aspect references and mismatched endpoints during evaluation. Preserve existing paths, IDs, resource names and claims during consolidation; an ownership or storage migration needs separate treatment. Container/image IDs are not implicitly NixOS account IDs.

### Storage and runtime secrets

Generalize the compute envelope's hard-coded application state into explicit retained-path declarations carrying host path, guest path, guest UID/GID, mode and read-only status. Preserve fixed non-root host ID translation, encrypted host persistence and the existing read-only legacy-media boundary. Fresh writable download/library paths are separate from legacy data. Static local PVs bind only declared paths and node placement; missing paths must not create substitute storage.

For ordinary private PVCs, use a pinned upstream local-path provisioner producing local PVs under one explicitly retained host parent. Use `Retain`, delayed binding, explicit node placement and unique PV-based backing directories; keep existing static volumes unchanged. Private directories start root-owned and mode 0700 inside the mapped guest; Kubernetes local-volume ownership handling uses the chart's declared filesystem group. Application users do not allocate Unix IDs or host directories. Capacity requests are not filesystem quotas, and this is not distributed storage.

Guest replacement with surviving data restores recorded PV/PVC mappings before releasing their consumers. Do not adopt a retained directory by namespace/claim name alone. Record Helm-owned metadata outside the guest under protected host storage, separately from reconstructible platform resources and host-staged secrets. This reattachment proof is distinct from restoring lost data from an independent backup.

Keep agenix/rekey authoritative. Stage required runtime files on the physical host and expose a narrow read-only credential directory to the guest. Materialize named Kubernetes Secrets at runtime through the native API; secret references and file mappings may be rendered, plaintext values may not enter images, Nix store artifacts or Git. Reuse the existing missing-identity preflight pattern for unprovisioned production files. A secret operator and another encryption translation layer are not required merely to retain Sini's manifest composition.

### Backup capture and recovery

Keep the application-consistent recovery boundary, but do not equate it with the whole guest. A recovery point identifies a restorable set; an independently protected backup copies that set outside the failure domain it must survive. Retained directories, same-host snapshots and exports do not by themselves protect against losing the host.

Use supported online application/database backups first. Pause writers only when needed to capture mutually consistent state, and only within the affected data boundary. Where the actual host filesystem supports suitable snapshots, obtain a stable capture, resume writers, then perform the slow backup transfer. A filesystem snapshot is not automatically application-consistent. Do not assume snapshot support on every mount or introduce a new storage topology to satisfy this plan.

The coordination rule is data safety, not connectivity: include another component only if independently captured state can lose records, omit referenced files or make restoration unsupported. A temporary API error is not enough. Sonarr calling SAB does not alone require stopping both; shared-file mutation or non-retryable work requires concrete examination. No dependency discovery engine or recursive service shutdown graph is planned. Each application's capture procedure identifies its durable data and relevant writers, using existing declarations and native tools.

Immich's database and referenced assets remain a matched recovery set. PostgreSQL supports online backups, but that alone does not synchronize the asset filesystem. Verify the pinned application's supported capture method, including concurrent upload, deletion and move behavior; do not silently substitute a weaker live-copy guarantee. Record any unavoidable interruption and seek an operator decision if it requires extended downtime or weaker consistency.

Restore validates the complete selected set before mutation, preserves displaced contents without renaming retained mount roots, and leaves affected writers stopped on failure until explicitly resumed. Resume checks actual application readiness and restores any paused reconciliation owner only when safe. Routine capture must restore its temporary writer/reconciliation pauses and report failure if service resumption fails; it must not leave the guest stopped awaiting a manual resume. Destructive restore and guest replacement remain separately authorized operations with different interruption expectations.

Measure capture interruption, completion, per-application recovery-point age and restore results. A successful export does not establish that an independent backup transfer succeeded. Independent applications may have different capture times; do not promise a globally synchronized history. Backup cadence, tolerated data loss, retention, destination protection and any pause limit require operator policy before production scheduling.

Implementation targets second-scale capture pauses, accepting minutes overnight when that materially simplifies implementation or maintenance. Prefer application-specific native procedures when they substantially shorten interruption, sharing common safety and reporting rather than forcing a generic capture mechanism. Actual interruption remains to be measured before scheduling.

### Thin service aspects

| Service group | Initial implementation choices |
| --- | --- |
| Jellyfin | Preserve the official pinned image, native authentication and read-only legacy media. Move resource rendering to the shared Nixidy path. CPU operation is the local baseline; GPU passthrough remains a hardware gate. |
| Immich | Official OCI Helm chart, matching server/CPU-ML release, dedicated VectorChord-compatible PostgreSQL and Valkey. Keep database and uploaded assets in one recovery set. Native OIDC is optional configuration with a local recovery account. Hostname root only. |
| Radarr / Sonarr / SABnzbd | Sini's bjw-s app-template shape, pinned multiarchitecture images, local configuration databases, consistent fresh download/library paths. Keep API-key authentication for internal automation and protect browser administration. Do not combine this fresh deployment with PostgreSQL migration. |
| Seerr | Official image/chart, one replica, retained configuration, internal Jellyfin service URL and user-facing external URL. Native Jellyfin/local sign-in; do not promise undocumented stable OIDC. |
| Monitoring | One kube-prometheus-stack release for Prometheus, Alertmanager, Grafana and kube-state-metrics; bounded Loki single-binary filesystem storage and an Alloy CRI-log collector. No monitoring PostgreSQL, HA or per-application logging sidecars. |

Nix owns explicitly declared service connections, paths, exposure and selected quality policy; UI edits to those fields may be overwritten. Preserve media, users, history and other undeclared records. Prefer native configuration, then independent supported-API reconciliation Jobs—not cross-service setup on every application restart. Nixflix's NixOS/systemd and private-helper coupling is not a Kubernetes interface. See [ADR-0004](../../../docs/architecture/decisions/0004-declarative-application-configuration.md).

Use an existing configuration-driven TRaSH tool instead of the custom quality-profile reconciler. Evaluate Configarr first: it supports templates, local custom formats, runtime secret references and revision controls; broader root-folder/download-client management is documented as experimental. Recyclarr is the narrower alternative if those broader features do not replace our code reliably. Clonarr's browser-managed policy is less aligned with repository ownership. Tool selection remains subject to disposable verification, not an accepted dependency merely because it appears here.

Pin the tool and upstream TRaSH/template revisions, keep personal overrides in repository configuration, and retain the selected inputs for reconstruction without live upstream content. Review upstream changes rather than silently following a moving branch. Verify managed-field repair, preservation of unrelated records and credential updates before cutting over; remove overlapping custom writers. Do not assume that configuring an Arr download client also configures SAB itself or Seerr.

Initial acquisition policy is balanced, WEB-oriented 1080p with straightforward declarative changes. An imported library need not match that policy: policy reconciliation must not itself search for upgrades, replace, or delete existing media merely because profiles differ. Acquisition and upgrade actions remain distinct from configuration reconciliation.

Separate Radarr, Sonarr, SAB and Seerr application definitions rather than extending the application-name exception loop. Reuse a Radarr definition across Radarr instances and a Sonarr definition across Sonarr instances, with distinct configuration volumes, credentials, library roots, categories and profile selections. Share unchanged defaults and image metadata, not an all-application runtime model. Exercise two same-application instance declarations locally; production 4K deployment is outside this change. One Jellyfin instance is the intended reader of both library trees, initially presented as separate libraries.

### Independent public ingress and identity

Kubernetes application routes are the only per-service routing inventory. NixOS edges forward the declared domain families to the same private ingress; moving the public edge does not move workloads or make the edge a cluster member. Use existing Tailscale connectivity first, with explicit origin reachability and narrow trusted peer addresses; live tailnet changes require separate authorization.

Use a Gateway API implementation that works with the current CNI, not a CNI replacement. Prefer ordinary HTTP reverse proxying with TLS termination at each edge and authenticated, certificate-verified private transport to the origin. Overwrite client-supplied forwarding headers at the Internet edge and trust them only from declared peers at the origin. Backend bypass denial is part of runtime acceptance, not an assumed property of an OIDC login page.

The normal domain points to a colo/VPS edge. A normally available home edge serves a configurable backup domain. Prepare manual same-name DNS failover, accounting for TTL/cache delays. The accepted privacy goal is keeping home addressing out of normal service DNS, not preventing discovery. Neither entrance survives loss of the home connection or origin.

Kanidm retains one canonical issuer and passkey origin. A fresh administrator login through a backup application hostname still needs that identity hostname; when its normal edge fails, explicitly fail canonical identity DNS over and wait for cache expiry. Native-authentication backup access and fresh OIDC session availability are different claims. See [ADR-0003](../../../docs/architecture/decisions/0003-independent-ingress-and-canonical-identity.md).

Preserve application-native authentication for public media/photo/request clients and centralize where supported. Kanidm is the preferred household identity service; its placement must not become a substrate recovery dependency. Arr and SAB start with public administrator-only browser access and private API-key-authenticated access for automation and private-network clients. The public browser UI may make its own authenticated API requests; “private API” means no separate public non-browser API access path, not blocking the UI's requests. Keep application-native API authentication independent of the browser gateway. Any reviewed public client path must not require replacing application state or disabling authentication. No public API route is added by this change. Raw SSH, Kubernetes and database protocols remain private. Jellyfin's archived third-party SSO plugin is not a required dependency.

### Verification and operator handoff

Use the authorized disposable Linux environment for platform runtime evidence; report native Darwin evidence separately. Exercise the shipped guest-replacement/bootstrap/Argo path through `modules/tests/prod-home-replacement.{nix,py}`, with `modules/tests/jellyfin_smoke.py` limited to HTTP application behavior. Broader household capture/restore is outside this change.

Concentrate durable checks on evaluated storage/secret/access boundaries and owned lifecycle behavior. Exercise matched database/assets, unrelated-service availability during capture, failure and resumption, mount-root preservation, route/authentication denial, Argo ownership/retirement, and Alertmanager firing/resolution against disposable destinations. Verify native private API access and public browser authorization separately. Do not create per-application upstream feature suites.

Check Incus adoption conflicts before preseed can modify an existing envelope. Static bootstrap must distinguish successful apply from ready services and explicit first-enrollment prerequisites; exercise the transition to Argo ownership. Maintain Markdown orientation and operating procedures with prerequisites and expected outcomes. Generate Markdown tables only for evaluated inventories and artifact references, not duplicate procedural prose. Keep disposable evidence in local continuity notes and production/hardware/provider gates explicit.

## Risks / Trade-offs

- Argo adds a controller and Git dependency for normal reconciliation; static bootstrap remains usable without live Git until root handoff, while replacement acceptance requires Git and registry access.
- Single-node local storage accepts guest-replacement and host-failure outages, not routine whole-guest backup shutdowns. Online capture can add IO load; short pauses depend on actual application and filesystem support. Host capacity and pause duration need evidence before scheduling.
- Missing runtime credentials intentionally block their consumers; they must not silently select anonymous access or generated replacement identities.
- Alternate hostnames may require coordinated canonical URL and OIDC callback changes. Immich does not support subpaths; reject incompatible routing.
- Image/chart versions evolve independently. Pin compatible pairs and inspect architecture support rather than copying Sini's amd64-only image pins.
- Declarative integration may overwrite explicitly managed configuration, but must preserve undeclared application records on restart and recovery.

## Evidence informing this revision

- [PostgreSQL online dumps](https://www.postgresql.org/docs/14/app-pgdump.html) provide database consistency, not consistency with external files.
- [Immich backup ordering](https://docs.immich.app/administration/backup-and-restore/#backup-ordering) distinguishes stopped-server capture from live database-first/file-second backup.
- [Configarr configuration](https://configarr.de/docs/configuration/config-file/) documents revision controls, templates, runtime secrets and experimental broader settings; verify against the selected release.
- [Recyclarr](https://recyclarr.dev/guide/getting-started/) and [Clonarr](https://github.com/ProphetSe7en/clonarr) offer different configuration ownership and interaction models.
