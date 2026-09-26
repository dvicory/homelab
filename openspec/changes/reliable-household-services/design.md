## Context

See proposal.md for the media-family boundary. PR22 supplies the compute, chart, retained-storage and runtime-secret substrate; PR23 supplies Argo Application health propagation and edge routing; PR24 owns Jellyfin first-start state, Jellarr configuration, libraries and integration readiness. This change uses those contracts instead of copying their implementations. Current media manifests and offline policy exist, but rendered shape and mock-based tests alone do not establish acceptance against the pinned application APIs.

## Goals / Non-Goals

**Goals:** Keep media workloads independently retained, native authentication and managed configuration explicit; prove initial convergence and repeatability with actual pinned APIs; state the coarse filesystem capability truthfully.

**Non-Goals:** Rebuild platform/Helm/secret transport, edge or identity infrastructure, Jellyfin account/library setup, general backup/restore, Immich or monitoring. Do not provision live indexers/providers, production credentials or a production 4K instance.

## Decisions

### Service and storage ownership

Keep separate thin Radarr, Sonarr, Prowlarr, SABnzbd and Seerr aspects. Reuse an Arr definition within each application kind, with distinct private configuration volume, native API key, root, category and profile per instance. Media acquisition shares `/data` under GID 505; this is a coarse write capability, not per-application POSIX isolation. Evaluate logical root/category collisions and explicit shared-path grants, and verify them as configuration invariants rather than tests purporting to prove OS-level path denial. Keep the Jellyfin reader boundary owned by PR24. A lost retained path must not silently be replaced with fresh data.

### Selected policy and API ownership

Use pinned Configarr 1.32 plus locally vendored, content-verified selected TRaSH profiles and custom formats for offline reconstruction. Configarr is the sole writer of declared Arr root records, semantic quality profiles, scored custom formats and SAB download-client settings; it also owns only the named managed Prowlarr application registrations. Unlisted Arr root records may be removed, but that API operation must leave filesystem media intact. Preserve unrelated Arr accounts/media and UI-owned Prowlarr applications. SAB's own native initializer owns its providers, categories and every declared root directory; no custom Arr-root or Prowlarr-registration writer remains. Configuration must fail visibly on malformed inputs or rejected API writes without initiating search, upgrades or deletion of media.

Select Seerr's Radarr and Sonarr defaults with an instance-local standard media role. Optional 4K instances retain independent state and semantic policy but are not selected by naming or sort order. Reject zero or multiple defaults. This is a media-family setting, not a global registry. Give initialized Seerr the household-facing native-auth route; retain administrator-only edge routes for Arr, Prowlarr and SAB with native API-key authentication for internal automation.

### Dependency and Jellyfin integration

Put cross-application media configuration in an Argo Application wave after healthy workload Applications and Jellyfin/Jellarr configuration, using PR23 Application-health propagation. Its PostSync Jobs order Configarr and then Seerr; bounded API checks handle residual startup variance. Publish non-suspended Configarr and Seerr CronJobs on separate six-hour schedules, offset by 30 minutes with `Forbid` concurrency and bounded deadlines, reusing the same Job specs. A Git revision reruns the hooks; the periodic Jobs repair later drift. A fresh cluster must converge without manual Argo re-sync, and no reconciliation alone should start an acquisition.

Consume the Jellyfin-owned service endpoint, configured Movies library, integration username and administrator Secret only for Seerr's first-owner claim. Do not generate another Jellyfin owner password or reconfigure its libraries. Pinned Seerr 3.4.1 rejects an injected API key before an owner exists; after the private first claim, use the stable operator-owned `SEERR_API_KEY` for repeat runs. Keep the public `requests` route absent in the checked-in `initial` phase. Switch to `ready` only after the Seerr Job succeeds, `/settings/public` confirms initialization, the Movies library is synchronized and the standard Arr defaults are verified. The route then exposes Seerr's native sign-in, never its claimable setup page.

### Verification boundary

Use a bounded disposable environment running the pinned Jellyfin, Radarr, Sonarr, Prowlarr, SABnzbd, Seerr and Configarr releases, with a synthetic Kubernetes Secret API only at Jellyfin's owned credential boundary. Exercise real initial setup and reapplication, malformed policy, a rejected API write, credential rotation, unrelated-record preservation, safe Arr root-record removal, Seerr owner/library/defaults and absence of search/upgrade commands. No live Usenet provider or indexer is needed. Keep `prod-home-replacement` focused on compute/storage/Jellyfin and whole-cluster Argo convergence; local API compatibility is not a substitute for its hosted run. Nix evaluation covers routes, roles, secret references, root/category invariants and periodic Job equivalence.

## Risks / Trade-offs

- Shared GID 505 can write any accessible shared media location; explicit logical ownership does not confine a compromised acquisition container. Per-application filesystem ACL/group isolation is a separate design if required.
- Cross-application readiness depends on healthy child Applications and bounded API availability; a health status cannot prove every application API operation succeeds.
- Upstream API or Configarr behavior may differ from assumed payloads. Keep the real pinned-version result authoritative and delete unsupported custom/configured behavior rather than recording mock success as proof.
- External provider credentials and production rollout remain operator-controlled; their absence does not justify placeholder integrations or weakened authentication.
