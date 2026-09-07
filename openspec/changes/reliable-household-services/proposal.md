## Why

The operator wants Immich, Jellyfin, Arr services, and monitoring ready for reliable fresh deployment this week, before a later migration from Proxmox. The existing Jellyfin slice establishes shared compute and recovery mechanisms, but does not yet provide a complete household service platform or public-access integration.

## What Changes

- Deliver Immich and its version-compatible database/cache/ML dependencies, Jellyfin, Radarr, Sonarr, SABnzbd, and Seerr through reusable Nix-rendered application definitions on the existing unprivileged Incus/K3s compute boundary. Prefer Sini's Den/Nixidy/chart composition over extending custom packaging.
- Define application-specific durable state, narrow writer permissions, runtime secrets, bounded resources, readiness, consistent recovery points, and empty-target restores. Preserve native application accounts and state rather than repeating setup after replacement.
- Add Prometheus, Alertmanager, Grafana, Loki, and a minimal Alloy collection configuration: usable dashboards, bounded retention, service/storage/recovery alerts, and tested failure visibility.
- Prepare independent NixOS remote and home ingress, configurable service hostnames and supported path prefixes, TLS, and native OIDC authentication where supported. Public household applications retain client-compatible authentication; selected browser administration requires strong administrator-only authentication, while raw management protocols stay private.
- Retain durable NixOS CI coverage, add behavior-focused application and integration scenarios, and produce a concise deployment handoff with remaining environmental prerequisites.
- Make architectural decisions under the operator's delegated authority and record them for later review. No workstation sudo, production inspection/deployment, production credentials, DNS/router mutation, or Proxmox migration is part of unattended execution.
- Keep the normal public edge on the existing colo/VPS, with a normally available direct-home backup domain and explicit same-name DNS failover procedures. Home-origin discoverability through fallback is accepted; deployment and DNS mutation are not authorized.

## Capabilities

### New Capabilities

- `household-services`: Independently delivered household applications with declared state, bounded ownership, fresh-instance usability, and application-consistent recovery.
- `service-exposure`: Independently placed public edges, explicit primary/recovery URLs, client-compatible household authentication, administrator-only browser surfaces, and private raw management protocols.
- `operational-visibility`: Bounded metrics/log collection and actionable service, capacity, and recovery failure reporting without becoming a recovery dependency.

### Modified Capabilities

None. Current management, storage, secret, and access contracts remain applicable. The active `reproducible-jellyfin-compute` change remains separate; its proposed compute-recovery contracts are not promoted to current authority by this plan.

## Impact

Extends Den workload/service aspects, host/guest integration, application rendering, runtime secret delivery, and existing NixOS CI checks. Reuses the resolved identity/group graph, persistence declarations, Prometheus target collection, and application-neutral compute lifecycle. Select one application reconciler and migrate its callers rather than giving multiple controllers ownership of the same resources. Adds version-pinned application/platform dependencies without a wholesale nixpkgs update.

Out of scope: real-data migration, new physical storage topology, HA/distributed storage, CNI replacement without demonstrated need, production indexer/provider connections, production GPU validation, public activation, and purchasing/provisioning an external backup destination. SABnzbd and its Arr integration are in scope; live provider credentials are not. Proxy/auth work is part of local completion, not a claim of live public access.
