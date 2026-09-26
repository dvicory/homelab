## Context

See proposal.md for the media-family boundary. PR22 supplies the compute, chart, retained-storage and runtime-secret substrate; PR23 supplies Argo Application health propagation and edge routing; PR24 owns Jellyfin first-start state, Jellarr configuration, libraries and integration readiness. This change uses those contracts instead of copying their implementations. Current media manifests and offline policy exist, but rendered shape and mock-based tests alone do not establish acceptance against the pinned application APIs.

## Goals / Non-Goals

**Goals:** Keep media workloads independently retained, native authentication and managed configuration explicit; prove initial convergence and repeatability with actual pinned APIs; state the coarse filesystem capability truthfully.

**Non-Goals:** Rebuild platform/Helm/secret transport, edge or identity infrastructure, Jellyfin account/library setup, general backup/restore, Immich or monitoring. Do not provision live indexers/providers, production credentials or a production 4K instance.

## Decisions

### Service and storage ownership

Keep separate thin Radarr, Sonarr, Prowlarr, SABnzbd and Seerr aspects. Reuse an Arr definition within each application kind, with distinct private configuration volume, native API key, root, category and profile per instance. Media acquisition shares `/data` under GID 505; this is a coarse write capability, not per-application POSIX isolation. Evaluate logical root/category collisions and explicit shared-path grants, and verify them as configuration invariants rather than tests purporting to prove OS-level path denial. Keep the Jellyfin reader boundary owned by PR24. A lost retained path must not silently be replaced with fresh data.

### Selected policy and API ownership

Use pinned Configarr plus vendored selected TRaSH/template inputs for offline reconstruction. Tie the claimed upstream revision to actual selected paths/content hashes so a mismatched policy fails CI. Own only explicitly declared Arr roots, quality/profile and download-client settings. Prove against the pinned Arr APIs whether Configarr's root-folder support can replace the thin native root reconciler; remove the custom writer if supported, otherwise retain it only for the unsupported field with recorded evidence. Prowlarr application registration, SAB's native configuration and Seerr onboarding remain distinct owners. Reconcilers must not erase UI-owned data or trigger media search/replacement just because a profile changes.

Select Seerr's Radarr and Sonarr defaults with an instance-local media role. The canonical named instance defaults to the role, additional instances do not; reject zero or multiple defaults instead of using sorted instance names. This is a media-family setting, not a global registry. Give Seerr the household-facing native-auth route; retain administrator-only edge routes for Arr, Prowlarr and SAB with native API-key authentication for internal automation.

### Dependency and Jellyfin integration

Put cross-application media configuration in an Argo Application wave after the workload Applications and Jellyfin/Jellarr configuration wave, using the PR23 Application-health propagation. Its one-shot PostSync Jobs order root reconciliation, Configarr/Prowlarr and Seerr within that Application. Bounded API readiness checks remain useful despite Application readiness. Remove suspended CronJobs that have no supported operator run contract; a Git change or explicit Argo re-sync reruns the hooks. Prove a fresh cluster converges from one revision without manually resyncing.

Consume only the Jellyfin-owned service endpoint, configured library identities, usable integration credential and readiness boundary. Do not generate an owner password, initialize Jellyfin users, or reconfigure its libraries in this slice. Seerr's own steady-state automation credential should use a supported API-key mechanism where proven by the pinned version; use actual API evidence before claiming first-owner or library synchronization automation. If an upstream-supported step cannot be automated reliably, identify the exact operator gate rather than invent an undocumented API or credential.

### Verification boundary

Use a bounded disposable integration environment running the pinned Jellyfin configuration path, Radarr, Sonarr, Prowlarr, SABnzbd, Seerr and Configarr. Verify real credentials and API payload acceptance, first integration and reapplication, unmanaged record preservation, selected Seerr backends and recognized Jellyfin library availability. No live Usenet provider or indexer is needed. Keep `prod-home-replacement` focused on the existing compute/storage/Jellyfin replacement contract; media API compatibility belongs in this cheaper dedicated run. Nix evaluation covers route, role, secret-reference and root/category invariants.

## Risks / Trade-offs

- Shared GID 505 can write any accessible shared media location; explicit logical ownership does not confine a compromised acquisition container. Per-application filesystem ACL/group isolation is a separate design if required.
- Cross-application readiness depends on healthy child Applications and bounded API availability; a health status cannot prove every application API operation succeeds.
- Upstream API or Configarr behavior may differ from assumed payloads. Keep the real pinned-version result authoritative and delete unsupported custom/configured behavior rather than recording mock success as proof.
- External provider credentials and production rollout remain operator-controlled; their absence does not justify placeholder integrations or weakened authentication.
