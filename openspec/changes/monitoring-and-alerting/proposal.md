## Why

During its first library scan, Jellyfin hit its 2Gi memory limit and the kernel killed it (OOMKilled). Argo CD still showed the application as Healthy, and nothing told the owner. The fleet has no monitoring at all. No contract says which failures must be noticed, who hears about them, or what happens when monitoring itself stops working.

This active change proposes deltas; current OpenSpec specs remain authoritative until the change is synchronized. The baseline below describes the original planning state, not current integration readiness.

## What Changes

Current behavior: no metrics are collected, no alerts are evaluated, and no notifications are sent. A pod restart, a degraded ZFS pool, a missing media mount or an expiring certificate is visible only if someone happens to look. The `prometheus-targets` quirk and its collection pipe exist, but no aspect emits targets into them and nothing consumes them.

Target behavior:

- **Detection.** Declared failure classes produce an alert within a stated time:
  - workload restarts, OOM kills, crash loops, pods that are not ready (finished pods excluded), evictions (once each), and Jobs that fail terminally (not a pod that a retry recovers from);
  - GitOps Applications that stay degraded, out of sync, or unable to read their source;
  - host storage faults: pool health, scrub and device errors, disk SMART health, the media pool and encrypted media mounts being present, and free space;
  - failed host systemd units;
  - unreachable administrator and household endpoints (Jellyfin, the identity service, Argo CD);
  - TLS certificates nearing expiry.
- **Missing data is a fault.** If a telemetry source stops reporting, that raises an alert. It never reads as "healthy". This includes a source that keeps answering while the data behind it goes stale, and a source that drops a declared disk or pool.
- **Silence is a failure.** A heartbeat goes to a dead man's switch outside the fleet, and only while fresh telemetry is still being ingested, evaluated and routed. When the heartbeat stops, for any reason from stalled ingestion up to total loss of the host, that outside service notifies the owner.
- **Delivery.** Alerts go to the fleet owner through two independent third-party channels: Pushover (primary) and Telegram (secondary, through a dedicated bot). Every critical alert reaches both channels without quiet-hours delay; every warning reaches at least one channel and may wait for quiet hours to end. Ongoing conditions send resolution notices. Discrete SMART new-error warnings do not: an event window ending is not evidence of disk recovery. Actual failing-health and missing/stale conditions retain explicit recovery semantics. Notifications carry no secret values, and a failed send through one channel is reported through the other. A channel that breaks while idle is found at its next send attempt. Active channel checks are deferred; design.md records a silent daily probe as the recommended follow-up. Concrete routing is in Nix (design.md, Decision 6).
- **Dashboards.** Normal dashboard access is available only to central administrators through central sign-in. Dashboards are published on the internet, like Argo CD. The entrance requires administrator sign-in before forwarding requests, and Grafana independently requires central administrator sign-in with anonymous, basic and local password sign-in disabled. Both layers share one identity-service client. Deliberate emergency management remains private and does not relax the published route. Metrics, alerting and exporter endpoints are not published.
- **Host-to-cluster boundary.** Host telemetry reaches the in-cluster collector only over the private host–guest link. It is not reachable from the LAN, the tailnet or the internet, and it gives the guest no other new access to the host.
- **Failure domain.** Monitoring never gates the platform. Its failure does not block GitOps syncs, the identity rollout or applications, and its resource use is bounded.
- **Retention and storage bounds.** Bounded metrics history lives on host-retained storage and survives compute-guest replacement. It is bounded by retention and by a free-space floor on the shared pool, with alerts before the floor and on unexpected growth. It is not isolated from other workloads: per-workload quota-limited storage is a deferred storage change. Without its retained storage, the metrics store does not start rather than writing elsewhere. Dashboards, data sources and alert rules are rebuilt from the declaration. Dashboard database state and alert-manager runtime state (silences) are disposable.
- **Secrets.** Delivery credentials, the watchdog ping URL, and generated Grafana administrator credentials use agenix and the existing runtime-secret flow. Git stores only encrypted source values; generated manifests contain references, never plaintext credentials.

### Decisions recorded from the owner

1. **Alert delivery:** Pushover first, Telegram second, through a dedicated Telegram bot. Discord was considered as the second channel and stays the recorded alternative.
2. **Stack shape:** alerts plus dashboards: a metrics store, alert evaluation and routing, and dashboards. No log aggregation for now.
3. **Coverage:** Kubernetes workloads and GitOps; host, storage and units; endpoints and certificates. This is the list under "Detection" above.
4. **Placement:** in the cluster, deployed by Argo CD, with an external dead man's switch. Running on the host, or splitting between host and cluster, are recorded in design.md as alternatives considered.
5. **Watchdog:** hosted healthchecks.io on the free tier, pinged by a "Watchdog" alert that fires only while fresh data arrives. It notifies through Pushover and Telegram when the pings stop. Pushover alone cannot be a watchdog: it only delivers messages it receives and cannot notice silence. The check is configured by hand for now; declaring it may come later.
6. **Retention:** 90 days on a retained path, which survives guest replacement, with a 50 GiB free-space floor. After review, the owner deferred per-workload quota-limited retained datasets (useful for Kanidm, Jellyfin config, the Arr databases, Immich and metrics) to their own future storage change.
7. **Severity routing:** warnings go to Pushover at normal priority, which respects quiet hours, and to Telegram. Critical alerts go to Pushover at priority 1, which bypasses quiet hours, and to Telegram. This is configuration, not contract: the owner can change it in Nix without a spec change, as long as the `fleet-monitoring` delivery requirement still holds.
8. **Out-of-memory kills:** a single OOM kill is critical.
9. **Time bounds:** the bounds in `fleet-monitoring` are confirmed as proposed.
10. **Dashboard exposure:** public, behind central administrator sign-in, like Argo CD.
11. **Host scope:** SMART collection automatically discovers OS-exposed non-USB physical disks, including newly attached disks and unused spares, without another inventory entry. USB, virtual and synthetic devices are excluded. Existing named required-disk expectations remain an independent absence floor; stable private identities never use raw serial numbers. The required mounts are media4's encrypted mount and the media pool `/srv/media/data`; legacy gocryptfs mounts are not required. Free-space alerts remain 10% (warning) and 5% (critical). This scope choice does not authorize a live producer or activation.
12. **SMART error growth:** a new error-count increase produces a warning event, without a later resolved/recovered message when the event window ends. Failing health and missing/stale telemetry remain ongoing conditions requiring matching healthy recovery evidence.
13. **Grafana emergency credentials:** generate and manage the local administrator password through agenix and the existing runtime Secret/file flow, rather than generating a Pod-memory-only password. Normal central-admin sign-in and the private emergency management boundary are unchanged.

### Non-goals

- **Backups and recovery monitoring are deferred to a future change.** That includes backup freshness, restore verification and off-host copies of monitoring state. This change defines no backup, RPO or restore policy for anything, including metrics history.
- No log aggregation (pods, host journal or Incus).
- No application-specific semantic metrics, dashboards or alerts, such as Jellyfin transcodes or Arr queues. Those stay with the application integration, following `management-boundaries`.
- **External probing of public routes is deferred to a follow-up change.** This change has no probing from outside the household network and no public status page. The external service only watches the heartbeat.
- No declarative configuration of the healthchecks.io check, the Pushover application or the Telegram bot. The owner creates them once by hand.
- **Per-workload quota-limited retained datasets are deferred** to their own storage change (design.md, Deferred follow-ups). Until then, metrics storage is bounded but not isolated.
- No active channel checks, and no dashboards beyond the minimal set. Both are recorded as follow-ups.
- No high availability for monitoring and no multi-site collection.
- No cleanup of existing dead quirk, pipe or schema code. design.md records it as a follow-up.

## Capabilities

### New Capabilities

- `fleet-monitoring`: which failures the fleet must detect and how fast; how alerts reach the owner; the external watchdog; payload and credential handling; the host-to-cluster telemetry boundary; monitoring's failure domain and resource bounds; and the lifecycle of metrics history and monitoring configuration.

### Modified Capabilities

- `access-control`: adds three requirements. Monitoring dashboards grant access only to central administrator sign-in. Every entrance to the dashboards, including the public one, requires administrator sign-in before forwarding a request. Monitoring data and control endpoints are not exposed through any entrance.

## Impact

- **Den / Nix (cluster):** a new monitoring aspect group renders the metrics store, alert evaluation, the alert manager, dashboards, kube-state-metrics and the blackbox prober as Argo Applications in the last sync wave, plus one retained path. It starts with a minimal dashboard set: host, Kubernetes workloads and a Homelab overview. Grafana gets a public administrator route (`exposure = "public"`) with a display name, like Argo CD. design.md, "What lives in Nix and what doesn't", lists what is declared and what is not.
- **Identity:** Grafana's route gets its own Kanidm client, shared with Grafana's native sign-in, and identity provisioning publishes its secret into the monitoring namespace. The smallest change is a Grafana case beside Argo CD's existing one; it is generalized into a declared per-route setting only if Argo CD's generated objects and identity tests stay unchanged.
- **Den / Nix (host):** `hvn-hyp1` gains node_exporter plus ZFS and SMART status timers that feed it, with declared pools and disks. The exporter listens only on the host–guest bridge address, and the firewall admits only the guest. It becomes the first real producer of the `prometheus-targets` quirk.
- **Host storage:** one new retained path, `monitoring-metrics`, under the existing state root. No new dataset, device or mount.
- **Secrets:** agenix runtime secrets under `.secrets/hosts/compute-1/` for delivery and Grafana. The operator supplies external provider credentials with `agenix edit`; Grafana's administrator password and secret key use the existing generator and rekey flow.
- **Generated output:** new manifests under `generated/manifests/prod-home/`, and a regenerated `docs/operations.md`. A monitoring runbook in `docs/operations/` documents the watchdog, silences and credential rotation.
- **External accounts:** a healthchecks.io check (free tier), a Pushover application, and a dedicated Telegram bot and chat. The bot is separate from Hermes's bot. The owner creates these once by hand.
- **Resources:** about 0.25 CPU and 0.8Gi requested in the guest, at most about 2.9 CPU and 3.3Gi at limits. On the host, about 4–8.4 GiB of shared ZFS space for 90 days of metrics history, plus small host units.
- **Authorization:** this change authorizes planning only. Implementation, credential provisioning, deployment and live acceptance are separate operator decisions.
