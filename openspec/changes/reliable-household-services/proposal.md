## Why

The operator wants Immich, Jellyfin, Arr services, and monitoring ready for reliable fresh deployment before a later migration from Proxmox. The existing Jellyfin slice establishes shared compute and recovery mechanisms, but the expanded platform still needs consolidation and end-to-end recovery, reconciliation, access and monitoring evidence. The operator reviewed the direction on 2026-09-08: prioritize clear ownership, minimally disruptive routine backups and configuration-driven TRaSH policy before continuing implementation.

## What Changes

- Deliver Immich and its version-compatible database/cache/ML dependencies, Jellyfin, Radarr, Sonarr, SABnzbd, and Seerr through reusable Nix-rendered application definitions on the existing unprivileged Incus/K3s compute boundary. Prefer Sini's Den/Nixidy/chart composition over extending custom packaging.
- Define application-specific durable state, narrow writer permissions, runtime secrets, bounded resources, readiness, consistent recovery points, and empty-target restores. Routine capture must not require stopping unrelated services; coordinate only the writers needed for data consistency. Preserve native application accounts and state rather than repeating setup after replacement.
- Add Prometheus, Alertmanager, Grafana, Loki, and a minimal Alloy collection configuration: usable dashboards, bounded retention, service/storage/recovery alerts, and tested failure visibility.
- Prepare independent NixOS remote and home ingress, configurable service hostnames and supported path prefixes, TLS, and native OIDC authentication where supported. Public household applications retain client-compatible authentication. Arr/downloader administration starts with public administrator-only browser access and private authenticated API access; later public API exposure must not require replacing applications or their state. Raw management protocols stay private.
- Consolidate repeated storage, identity, endpoint and secret declarations without changing existing persistent identities. Keep application aspects readable and reuse same-application instance definitions for future separate 1080p/4K Arr instances feeding one Jellyfin service.
- Replace custom TRaSH profile reconciliation with a supported configuration-driven tool, evaluating Configarr first. Keep managed fields explicit, personal overrides declarative and upstream policy inputs pinned; no competing writers for the same settings.
- Retain durable NixOS CI coverage and behavior-focused integration evidence. Separate maintained Markdown procedures from generated Markdown reference tables; state incomplete acceptance and environmental prerequisites plainly.
- Support ordinary Helm/application-owned resources through standard retained PVC and runtime Secret interfaces without requiring Nix application wrappers. Keep their installation inputs and protected recovery metadata explicit; prove guest replacement with a representative Helm application before migrating media permissions.
- Record the reviewed direction and remaining decisions. This revision changes planning only; implementation resumes separately. No workstation sudo, production inspection/deployment, production credentials, DNS/router mutation, or Proxmox migration is authorized by the planning update.
- Keep the normal public edge on the existing colo/VPS, with a normally available direct-home backup domain and explicit same-name DNS failover procedures. Home-origin discoverability through fallback is accepted; deployment and DNS mutation are not authorized.

## Capabilities

### New Capabilities

- `household-services`: Independently delivered household applications and instances with declared state, bounded ownership, reproducible managed policy, fresh-instance usability, and application-consistent recovery without unrelated routine shutdowns.
- `service-exposure`: Independently placed public edges, explicit primary/recovery URLs, client-compatible household authentication, administrator-only browser surfaces, and private raw management protocols.
- `operational-visibility`: Bounded metrics/log collection and actionable service, capacity, and recovery failure reporting without becoming a recovery dependency.

### Modified Capabilities

None. Current management, storage, secret, and access contracts remain applicable. The active `reproducible-jellyfin-compute` change remains separate; its proposed compute-recovery contracts are not promoted to current authority by this plan.

## Impact

Extends Den workload/service aspects, host/guest integration, application rendering, runtime secret delivery, and existing NixOS CI checks. Reuses the resolved identity/group graph, persistence declarations, Prometheus target collection, and application-neutral compute lifecycle. Select one application reconciler and migrate its callers rather than giving multiple controllers ownership of the same resources. Adds version-pinned application/platform dependencies without a wholesale nixpkgs update.

Out of scope: real-data migration, new physical storage topology, HA/distributed storage, CNI replacement without demonstrated need, production indexer/provider connections, production GPU validation, public activation, and purchasing/provisioning an external backup destination. SABnzbd and its Arr integration are in scope; live provider credentials are not. Proxy/auth work is part of local completion, not a claim of live public access.

Routine backup capture and destructive guest replacement are different operations; this change does not promise zero-downtime guest replacement or globally synchronized application history. It does not require a new storage topology, a custom dependency/backup controller, immediate deployment of 4K instances, or selection of an external backup destination. Backup cadence, tolerated data loss, retention and destination protection remain explicit operator policy to settle before scheduling production backups.
