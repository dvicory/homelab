## Context

See proposal.md, "Why" and "What Changes". The specs are `specs/fleet-monitoring/spec.md` and `specs/access-control/spec.md`. This document chooses the mechanisms.

### Current state, from the repository (main at `03cbc3e7`)

- **No monitoring components exist.**
  - `docs/operations/identity.md:122-124` says the stack "does not configure a scraper or alerts".
  - `den.quirks.prometheus-targets` (`modules/den/quirks/prometheus-targets.nix`) and the `collect-prometheus-targets` policy (`modules/den/policies/pipes.nix:19-25,47`) exist, but no aspect emits into the quirk and no aspect consumes it.
- **Sync waves.**
  - Argo Applications use waves -4 to 4. The highest is `identity-gateway` at 4.
  - Since PR #43, a child Application that is Degraded, or has a source comparison error, blocks later waves of its parent.
  - Applications sync automatically with `selfHeal`.
- **Network.**
  - The guest reaches the host over the Incus bridge `incus-compute`: host 10.210.0.1, guest 10.210.0.10 (`modules/den/aspects/virtualization/compute.nix:385`).
  - The host firewall on that interface allows only DNS and DHCP (`compute.nix:532-538`).
  - Household HTTPS is DNATed only when it arrives on the LAN uplink or Tailscale (`compute.nix:615-628`). Traffic from inside the guest to the household hostnames therefore does not take the household path.
- **Guest kubelet.** The guest already opens the kubelet port 10250 on `cni0` "for metrics collectors" (`modules/den/aspects/services/kubernetes.nix:15-17`).
- **Identity and sign-in.**
  - Identity gives every administrator route a Kanidm client named after the route.
  - Argo CD shares its route's client through a hard-coded special case (`modules/den/aspects/kubernetes/services/identity.nix:116-150`).
  - Kanidm's NetworkPolicy has a matching hard-coded allow for `argocd-server` (`identity.nix:648-664`).
- **Existing metrics endpoints.**
  - The Argo CD controller's metrics port already accepts traffic from any namespace (`generated/manifests/prod-home/argocd/NetworkPolicy-argocd-application-controller.yaml`).
  - cert-manager exposes metrics on 9402 and has no NetworkPolicy.
- **Charts and runtime secrets.**
  - Charts come from pinned nixhelm (`modules/meta/inputs.nix:46`), or from `lib.helm.downloadHelmChart` with a version and hash (`modules/den/aspects/kubernetes/services/retained-storage.nix:35-40`). Images are pinned as `tag@digest`.
  - Runtime secrets are declared as `runtimeSecrets` entries named `namespace--secret--key`. Agenix decrypts them on the host and `compute-stage-secrets` stages them into the guest.

### Current state, from the host (read-only inspection, 2026-10-10)

- **Machine.** `hvn-hyp1` runs NixOS with kernel 6.18 and has 56 CPUs and 220 GiB RAM.
- **Compute guest.** `compute-1` currently has 4 CPUs and 12 GiB. PR #52 raises that to 12 CPUs and 32 GiB.
- **rpool.** A mirror of two Intel NVMe drives: ONLINE, 55% used, 341 GiB free. The last scrub (2026-10-01) found 0 errors, and the scrub timer is monthly. OpenZFS is 2.4.4, so `zpool status -j -p` (JSON) is available. It also works without root.
- **Retained state.** The state root `/var/lib/homelab/compute-1/state` is on `rpool/safe/persist`.
- **Media disks.** Seven 12 TB HGST drives: six SAS (`HUH721212AL4200`) and one SATA (`HUH721212ALE601`).
  - media1–3 are btrfs plus gocryptfs and still mounted.
  - media4 is LUKS2 plus XFS at `/mnt/storage-clear/media4`.
  - `/srv/media/data` is `fuse.mergerfs` over media4's `pool/` only.
  - All media filesystems are 58–60% used.
  - `sdc` and `sdg` carry old `zfs_member` partitions that are not imported. `sdf` is blank.
- **Health tooling.** `zfs-zed` runs. `smartd` does not, and no exporters run. No systemd units are failed.
- **Listening ports.** 22, 8443 (Incus), the Tailscale ports, and DNS on 10.210.0.1:53.

### Prior material considered

An unmerged draft, `household-observability-integration` (jj commit `4365f7bedaa8`, capability `operational-visibility`, 2026-09-22), proposed local metrics, Loki pod logs, about 60 days of Prometheus history on retained storage, and declaratively provisioned Grafana. It explicitly deferred notification and detection from outside the fleet. It is supporting material, not authority.

- **Kept:** retained metrics history, declarative dashboards, disposable Grafana database and Alertmanager state, the distinction between a failed target and a failed collector, and host telemetry delivered through the quirk over a private path.
- **Changed:**
  - logs are dropped, as the owner decided;
  - notifications and an external watchdog are added;
  - the metrics store is VictoriaMetrics instead of Prometheus;
  - the design targets the current Den cluster, route and identity model.

## What you get

This section is a plain summary for the owner.

**Components**

| Component | Where | What it does |
| --- | --- | --- |
| VictoriaMetrics (single-node) | cluster, `monitoring` namespace | Collects metrics every 30 s from everything below and keeps 90 days of history on host-retained ZFS storage. |
| vmalert | cluster | Evaluates alert rules every 30 s against the stored metrics. |
| Alertmanager | cluster | Groups, de-duplicates and routes alerts. Sends every alert to Pushover and Telegram, and pings healthchecks.io with the heartbeat. |
| Grafana | cluster, `grafana.<domain>` | Dashboards, reachable from anywhere like Argo CD. Admins only: the Gateway requires Kanidm admin sign-in first, then Grafana signs the admin in through Kanidm too. |
| kube-state-metrics | cluster | Reports Kubernetes object state: restarts, OOM kills, readiness, Jobs. |
| blackbox exporter | cluster | Probes Jellyfin, Kanidm and Argo CD through the gateway, and reads the certificates they serve. |
| kubelet / cAdvisor | guest (already running) | Reports per-container CPU, memory and OOM events. |
| Argo CD and cert-manager metrics | cluster (already running) | Report Application health and sync status, and certificate expiry and readiness. |
| node_exporter | host | Reports host CPU, memory, filesystems, mounts and systemd unit state. |
| ZFS status check | host | A 2-minute timer that records pool state, device errors and scrub results for each declared pool. |
| SMART status check | host | A 15-minute timer that records SMART and SCSI health for each declared physical disk, including unused ones. USB and virtual devices are excluded. |
| healthchecks.io | outside the fleet | Expects a heartbeat every 5 minutes. The heartbeat is sent only while fresh metrics are still arriving. If it stops, healthchecks.io alerts you through Pushover and Telegram. |

**Example alerts** (C means critical: Pushover at priority 1, which bypasses quiet hours, and Telegram. W means warning: Pushover at normal priority, which respects quiet hours, and Telegram. This is the current routing, which the owner can change in Nix; see Decision 6.)

- C `KubeContainerOOMKilled`: "jellyfin/jellyfin container `jellyfin` was OOMKilled (limit 4Gi) and restarted." This is the alert the Jellyfin incident would have produced. A single kill is critical.
- C `KubePodCrashLooping`, C `KubePodNotReady`, W `KubeContainerRestarted`, W `KubeJobFailed`, W `KubePodEvicted`.
- C `ArgoApplicationDegraded`, W `ArgoApplicationOutOfSync`.
- C `HostZpoolUnhealthy`: "rpool is DEGRADED."
- C `HostZpoolDeviceErrors`, C `HostZpoolScrubErrors`, W `HostZpoolScrubOverdue`.
- C `HostDiskSmartFailing`: "media4 (wwn-0x5000cca27061f6b4) reports SMART FAILED."
- C `HostRequiredMountMissing`: "/srv/media/data (mergerfs) is not mounted."
- W/C `HostFilesystemLowSpace` (W below 10% free, C below 5%), W `HostSystemdUnitFailed`.
- C `EndpointDown`: "jellyfin.<domain> has not answered for 5 minutes."
- W `CertificateExpiringSoon` (21 days left), C at 14 days, W `CertificateNotReady`.
- C `TelemetrySourceDown`: "host node_exporter on hvn-hyp1 is not reporting."
- C `HostZpoolStatusStale`: "zpool.prom on hvn-hyp1 has not been refreshed for 10 minutes."
- C `HostDiskTelemetryMissing`: "disk media4 (wwn-0x5000cca27061f6b4) was not read in the last two SMART runs."
- W/C `MonitoringStorageLow`: "rpool has 68 GiB free; metrics ingestion stops at 50 GiB." W `MonitoringStorageGrowth`: "metrics history is 21 GiB, expected under 9 GiB."
- C `AlertDeliveryFailing`: "Pushover notifications are failing." This one is sent through Telegram, and the reverse for Telegram.
- Watchdog, through healthchecks.io: "Homelab monitoring heartbeat is down." This means monitoring can no longer report faults: the guest or host is down, or metrics stopped arriving, or alert evaluation or routing stopped.

**Dashboards in this change** (a minimal first set; alerts do not depend on any of them)

- **Homelab overview:** firing alerts, endpoint status, pool, SMART and mount state, free space, guest memory, and the pods using the most memory relative to their limit.
- **Host:** Node Exporter Full.
- **Kubernetes workloads:** namespace and pod views of CPU, memory, restarts and OOM events.

Argo CD, cert-manager, SMART, blackbox and VictoriaMetrics dashboards are deferred ("Deferred follow-ups").

## What lives in Nix and what doesn't

Most of monitoring is declared in this repository and rendered from it. Credential values are in Git only in encrypted form. A small amount of account setup and runtime state lives outside Nix.

**Declared in Nix and rendered:**

- **Deployments and charts.** Charts and images are pinned (version and hash, `tag@digest`) and rendered to manifests under `generated/manifests/prod-home/`. Argo CD syncs those manifests.
- **Alert rules.** Rendered as Prometheus-format YAML and unit-tested in a flake check (Decision 5).
- **Scrape targets.** Host exporters declare themselves through the `prometheus-targets` quirk; cluster targets are derived from the cluster declaration (Decisions 3 and 4).
- **Alertmanager routing.** Routes, inhibition, grouping and templates (Decision 6). Credentials appear only as file paths.
- **Grafana data sources and dashboards.** Dashboard JSON lives in the repository under `assets/monitoring/dashboards/` and is provisioned read-only (Decision 9).
- **Host exporters and status timers.** NixOS services on `hvn-hyp1`, the declared pools and disks they must report, and the firewall rule that admits only the guest (Decision 4).
- **The Kanidm client for Grafana.** Identity derives it from Grafana's route, as for every administrator route (Decision 9).
- **Retention and sizes.** The retained path, the retention period, VictoriaMetrics' free-space floor, the storage alert thresholds and every resource limit (Decisions 12 and 14).

**Encrypted in Git:**

- **Credential values.** The Pushover token and user key, the Telegram bot token and chat ID, and the heartbeat URL are agenix secrets that the owner supplies with `agenix edit`. Grafana's admin password and secret key are agenix secrets too, but agenix-rekey's `alnum-no-newline` generator creates them, so nobody types them. `compute-stage-secrets` stages all of them into the guest (Decision 13).

**Outside Nix:**

- **One-time manual setup by the owner.** Creating the Pushover application, the dedicated Telegram bot and its chat, and the healthchecks.io check with its Pushover and Telegram integrations. Tasks 9.1–9.4 list the steps, and the runbook records the exact settings. Declaring the healthchecks.io check may come later.
- **Runtime state.** Metrics data on the retained path, Alertmanager silences and notification log, and Grafana sessions and database. Only metrics data survives guest replacement (Decision 12).
- **The Grafana OIDC client secret.** Kanidm generates it, and identity provisioning publishes it into `monitoring/grafana-oidc` at runtime, as for Argo CD. The client itself is declared; only its secret value is runtime state.

## Goals / Non-Goals

**Goals:**

- Meet each `fleet-monitoring` time bound with ordinary scrape and evaluation intervals, and prove the bounds with rule unit tests.
- Keep the alerting path (collection → evaluation → routing → internet) independent of Kanidm, the Gateway and cert-manager. Only dashboards depend on them.
- Use one declaration path for host targets: the existing `prometheus-targets` quirk.
- Add no CRDs or operators, so monitoring cannot hold up other Applications through shared API types.

**Non-Goals:**

- Probing household hostnames from outside the LAN, and testing the host DNAT path end to end. That is a follow-up change. See Risks.
- Alerts specific to an application, such as Jellyfin's own `/metrics` or Kanidm's `/stats/prometheus`.
- Managing healthchecks.io, Pushover or Telegram account configuration declaratively. Declaring the healthchecks.io check may come later.
- Cleaning up the dead code listed under "Cleanup note".

## Decisions

### 1. Placement: in the cluster, with an external dead man's switch

Monitoring runs in the cluster as Argo Applications. An external heartbeat check covers the failure the cluster cannot report on itself: losing the guest, the host, power or the uplink.

| Option | For | Against |
| --- | --- | --- |
| **In-cluster + external watchdog (chosen)** | One GitOps owner, like every other workload. Reuses Gateway, Kanidm sign-in, runtime secrets and retained storage. Keeps the host a substrate, not an application host (ADR-0001). | Monitoring dies with the guest. The watchdog turns that into a notification but gives no detail. The host must expose telemetry to the guest. |
| Host-run (NixOS services on `hvn-hyp1`) | Survives guest and cluster failure, and needs no host-to-guest exposure for host metrics. | Grafana needs a second entrance or a guest-to-host route. Puts application services and their state on the impermanent host. A second config owner for monitoring. Still blind to host loss without the same watchdog. |
| Split: alerting on the host, dashboards in the cluster | Strongest failure independence. | Two stacks, two config owners and two upgrade paths, for a single-host fleet whose total-loss case the watchdog already covers. |

**Revisit when:** a second host or compute guest exists. A host-level alerting core then becomes cheaper than its independence is worth.

### 2. Metrics store: VictoriaMetrics single-node, with no operator

**Recommendation:** VictoriaMetrics single-node, using its built-in Prometheus-compatible scraping (`-promscrape.config`), plus vmalert and upstream Alertmanager. Scrape config and rules are rendered by Nix in Prometheus format. No Prometheus Operator, VictoriaMetrics operator or CRDs.

| Option | For | Against |
| --- | --- | --- |
| **VictoriaMetrics single + vmalert (chosen)** | About 3–5× less RAM and about 2–3× less disk per sample than Prometheus at this scale. Fast restart with no WAL replay spike, which matters for a guest that is replaced routinely (ADR-0008). Retention is a single flag. PromQL and Prometheus rule and scrape formats, so leaving is cheap. | One extra component (vmalert). The single-node and alert charts are not in pinned nixhelm, so they need `downloadHelmChart` with a hash. MetricsQL differs from PromQL in edge cases. |
| Prometheus (plain `prometheus-community/prometheus` chart) | Most familiar. Evaluates rules itself. Chart available in nixhelm (29.27.0). | Higher memory, plus a WAL replay memory spike after restart. Otherwise equivalent. **This is the fallback:** the scrape config and rules carry over unchanged. |
| kube-prometheus-stack (88.6.2 in nixhelm) | Batteries included: about 150 rules and about 25 dashboards. | Operator plus about 10 CRDs (some too large for client-side apply). Default control-plane rules fire falsely on K3s, whose scheduler, controller-manager and etcd are not separately scrapable. Rules are hidden inside generated objects rather than inspectable Nix. Heaviest option. |
| victoria-metrics-k8s-stack (0.91.2) | The VictoriaMetrics equivalent of kube-prometheus-stack. | Same operator and CRD costs. |
| vmagent in front of a store | Buffers when remote storage is down, or scrapes from another location. | Not needed. Single-node VictoriaMetrics scrapes locally, and there is no remote store. |

### 3. Cluster telemetry sources

- **kube-state-metrics** (Deployment, read-only cluster RBAC). Run with `--resources` that exclude `secrets` and `configmaps`, and with no label or annotation allowlist. This keeps cardinality low and keeps Secret metadata out of metrics.
  - It supplies `kube_pod_container_status_last_terminated_reason`, `kube_pod_container_status_restarts_total`, `kube_pod_container_status_waiting_reason`, `kube_pod_status_ready`, `kube_pod_status_phase`, `kube_pod_status_reason`, `kube_job_status_condition` (terminal `Failed` and `Complete` conditions) and `kube_node_status_condition`.
- **kubelet and cAdvisor.** Scrape `https://<node>:10250/metrics` and `/metrics/cadvisor` with the collector's service-account token (RBAC: `nodes/metrics` get). It supplies `container_oom_events_total` and memory working set compared with the limit. The guest firewall already allows 10250 on `cni0`.
  - There is no in-guest node_exporter. Inside an unprivileged LXC guest it reports lxcfs-shaped numbers. Host node_exporter plus cAdvisor cover the real needs.
- **Argo CD.** Set `controller.metrics.enabled = true` in `argocd.nix` and scrape the application controller's metrics Service on 8082. Its NetworkPolicy already allows this.
  - It supplies `argocd_app_info{health_status,sync_status}`.
  - Source comparison errors appear as `Degraded` on parent Applications through the existing health Lua. For the Application itself, enable the controller's `--metrics-application-conditions=ComparisonError` so `argocd_app_condition` is exported.
- **cert-manager.** Scrape the controller on 9402. It supplies `certmanager_certificate_expiration_timestamp_seconds` and `certmanager_certificate_ready_status`.
- **blackbox exporter** (nixhelm `prometheus-blackbox-exporter` 11.18.0).
  - It probes the gateway's NodePort on the node address, with SNI and `Host` set to each route's primary hostname. This is the hop the host DNAT forwards to.
  - Probe targets are derived from `cluster.routes`:
    - `native` routes expect 2xx on a health path (Jellyfin `/health`, Kanidm `/status`);
    - `admin` routes accept a 302 whose `Location` is on the identity hostname.
  - A per-route override table lives in the monitoring aspect, not in the route schema. An evaluation check fails if a declared route has no probe, so the PR #25 routes are covered when they land.
  - It also supplies `probe_ssl_earliest_cert_expiry` for the certificate actually served.
- **Monitoring self.** Scrape VictoriaMetrics, vmalert, Alertmanager and Grafana. This exposes `alertmanager_notifications_failed_total`, rule evaluation failures and free disk.

### 4. Host telemetry and the host-to-cluster boundary

- **New host aspect** (working name `services.host-telemetry`, included by `hvn-hyp1`). It adds one exporter and two status timers that feed it:
  - `services.prometheus.exporters.node` on port 9100, with the `systemd`, `filesystem`, `zfs` and `textfile` collectors.
  - A `zpool-status` oneshot on a 2-minute timer. It runs `zpool status -j -p` (no root needed) and atomically writes `zpool.prom` into node_exporter's textfile directory. That file holds pool state, per-device read, write and checksum errors, scan state, last scrub end time and scrub errors, plus `homelab_zpool_present{pool} 1` for each pool that `zpool status` reported. The file is replaced only after a successful run, so a failing or stuck timer leaves an old modification time behind instead of a fresh-looking file.
  - A `smart-status` oneshot on a 15-minute timer. It runs `smartctl --json -a` on each declared disk and atomically writes `smart.prom` into the same textfile directory: health status, SCSI grown defects and ATA pending and reallocated sectors, and per disk a `homelab_smart_device_up{disk,id}` series that is 1 only if this run read that disk.
- **Declared pools and disks.** Host data declares what must keep reporting, so a source that stays up but drops an item is caught. The host consumer publishes both lists as read-only options next to `scrapeTargets`, and the cluster monitoring aspect renders one rule per item from them (Decision 5). The rules therefore do not depend on the converter remembering what it should have reported.
  - **Pools:** derived from host data (`zfs.rootPool.name`, today only `rpool`).
  - **Disks:** a new `expectedDisks` attribute set in `hvn-hyp1`'s host data, keyed by a readable name (for example `media4`, `rpool-a`), with each disk's stable `/dev/disk/by-id/` path: `wwn-0x…` for the SAS and SATA drives and `nvme-eui.…` for the NVMe drives. That is 9 disks: the 2 rpool NVMe drives and the 7 HGST drives, which include the unused `sdc`, `sdg` and `sdf`. USB devices (the IDSDM) and virtual devices (iDRAC) are not declared, so they are excluded. The IDs come from a read-only inspection of the host (task 2.1).
  - Using by-id paths rather than `sdX` names keeps each series attached to the same physical disk across reboots and controller reordering. No serial numbers are stored in the repository.
- **Why a SMART timer instead of `smartctl_exporter`.** The first draft used `services.prometheus.exporters.smartctl`. That exporter polls on its own interval and serves cached values on every scrape, and it exposes no per-device collection time. A disk that stopped reading would keep serving its last good value, which looks fresh to the collector. The timer gives SMART the same freshness model as ZFS: a file modification time, plus an explicit per-disk "read this run" flag. It also removes a second listening port, and raw device access runs in a short-lived oneshot instead of a network-facing service. The cost is one more small converter, which task 2.4 unit-tests against recorded `smartctl --json` output. SAS drives report SCSI health and grown defects rather than ATA attributes; the converter maps both. **Recorded alternative:** `smartctl_exporter` with an explicit `--smartctl.device` list, if a pinned version gains a per-device collection timestamp.
- **Exporter binding.** node_exporter binds to the bridge address from host data (`settings.virtualization.compute`: the network's host address), not to a wildcard.
  - The unit orders after Incus has created the bridge, and uses `Restart=always` with `RestartSec=10s`.
  - Neither the exporter nor the timers are wanted by any target that activation waits on.
  - Each unit has `MemoryMax` (64M) and `CPUQuota`.
- **Firewall.** One nftables input rule admits only `iifname "<compute network>" ip saddr <guest address>` to the exporter port. A guest pod's traffic leaves the node with the node address through Flannel masquerading, so the guest address is the only source. The LAN, Tailscale and the internet cannot reach the port, because the bind address is bridge-only and the firewall checks both interface and source.
- **Quirk producer.** The aspect emits `prometheus-targets` entries: `{ job; port; path; interval; labels }`. This makes it the first real producer of the quirk.
- **Quirk consumer.** A host consumer aspect, in the style of `persist-collector` and `firewall-collector`, takes `{ prometheus-targets, ... }` and does two things:
  - renders the firewall rule above;
  - exposes the resolved list, with the bridge address filled in, as a read-only NixOS option (for example `homelab.monitoring.scrapeTargets`).
- **How the cluster reads the targets.** The cluster monitoring aspect reads that option from `inputs.self.nixosConfigurations.${cluster.hostName}`. It is pure evaluation of repository state, as `identity.nix` already does for the guest's `pkgs`, so `fleet-composition`'s independent-evaluation rule holds.
- **Required mounts.** The host consumer also publishes the list of required mounts derived from host data: each `services.mergerfs.pools` mountpoint and each provisioned `disk.luks-storage` mountpoint. `HostRequiredMountMissing` alerts on `absent(node_filesystem_size_bytes{mountpoint=...})` for each one. New pools and disks are then covered without editing rules.
  - On `hvn-hyp1` today the list is exactly `/srv/media/data` (MergerFS) and `/mnt/storage-clear/media4` (LUKS2 and XFS).
  - The legacy gocryptfs mounts (media1–3) are not required mounts, as the owner decided. They are not in `disk.luks-storage`, so the derivation leaves them out without a special case.
  - To cover another mount later, add its mountpoint to one declared list in the host telemetry aspect (working name `extraRequiredMounts`, empty today). A legacy disk that is converted to `disk.luks-storage` joins the list by itself.

### 5. Alert rules and time bounds

Collection runs every 30 s and vmalert evaluates every 30 s. Alertmanager uses `group_wait: 30s` and `group_interval: 2m`. Worst-case delay from condition to notification is therefore `for` + about 3.5 minutes, plus the source's own polling interval for host checks (2 minutes for ZFS status, 15 minutes for SMART). Rule files are Nix-rendered Prometheus YAML, unit-tested with `vmalert-tool unittest` (or `promtool test rules`) in a flake check.

The owner confirmed the spec's time bounds as proposed, decided that a single OOM kill is critical, and set the free-space thresholds at 10% (warning) and 5% (critical) for every monitored filesystem.

| Spec bound | Alert | Expression (sketch) | `for` | Severity |
| --- | --- | --- | --- | --- |
| OOM ≤ 5 min | `KubeContainerOOMKilled` | restarts increased in 10m **and** last terminated reason `OOMKilled`; or `increase(container_oom_events_total[10m]) > 0` | 0 | critical |
| restart ≤ 5 min | `KubeContainerRestarted` | `increase(kube_pod_container_status_restarts_total[10m]) > 0`, unless OOM | 0 | warning |
| crash loop ≤ 20 min | `KubePodCrashLooping` | waiting reason `CrashLoopBackOff` | 15m | critical |
| not ready ≤ 20 min | `KubePodNotReady` | `kube_pod_status_ready{condition="true"} == 0`, only for pods whose `kube_pod_status_phase` is `Pending`, `Running` or `Unknown`; `Failed` and `Succeeded` pods are excluded | 15m | critical |
| eviction ≤ 15 min | `KubePodEvicted` | `kube_pod_status_reason{reason="Evicted"} == 1 unless (kube_pod_status_reason{reason="Evicted"} offset 30m == 1)`: true only during the first 30 minutes after a pod is evicted | 0 | warning |
| Job ≤ 15 min | `KubeJobFailed` | `kube_job_status_condition{condition="Failed",status="true"} == 1`: the Job's terminal Failed condition, set only after `backoffLimit` or `activeDeadlineSeconds` is exhausted | 0 | warning |
| degraded ≤ 20 min | `ArgoApplicationDegraded` | `health_status=~"Degraded\|Missing"`, or a `ComparisonError` condition | 15m | critical |
| out of sync ≤ 40 min | `ArgoApplicationOutOfSync` | `sync_status="OutOfSync"` | 30m | warning |
| pool ≤ 10 min | `HostZpoolUnhealthy` | pool state ≠ ONLINE | 1m | critical |
| device errors ≤ 10 min | `HostZpoolDeviceErrors` | any device read, write or checksum error count > 0 | 1m | critical |
| mounts ≤ 10 min | `HostRequiredMountMissing` | `absent(...)` per required mount | 2m | critical |
| scrub ≤ 1 h | `HostZpoolScrubErrors` | last scrub errors > 0 | 0 | critical |
| (extra) | `HostZpoolScrubOverdue` | last scrub ended more than 35 days ago | 1h | warning |
| SMART ≤ 1 h | `HostDiskSmartFailing` | SMART health status not passed, or grown defects or pending sectors increased (from `smart.prom`) | 0 | critical (status), warning (counters) |
| space ≤ 1 h | `HostFilesystemLowSpace` | available below 10% (warn) or 5% (crit) of size | 30m | warning / critical |
| unit ≤ 15 min | `HostSystemdUnitFailed` | `node_systemd_unit_state{state="failed"} == 1` | 10m | warning |
| endpoint ≤ 10 min | `EndpointDown` | `probe_success == 0` | 5m | critical |
| cert ≥ 14 d left | `CertificateExpiringSoon` | served or managed expiry under 21 d (warn) or under 14 d (crit) | 1h | warning / critical |
| cert not ready | `CertificateNotReady` | `certmanager_certificate_ready_status{condition="False"} == 1` | 1h | warning |
| missing source ≤ 15 min | `TelemetrySourceDown` | per declared job: `up == 0`, **or** `absent(up{job="…"})` so a target that vanishes from discovery also fires | 5m | critical for the core sources (kubelet, cAdvisor, kube-state-metrics, host node_exporter); warning for the rest |
| stale data ≤ 15 min | `HostZpoolStatusStale` | `time() - node_textfile_mtime_seconds{file=~"(.*/)?zpool\\.prom"} > 600` (five missed 2-minute runs), or that series is absent, or `node_textfile_scrape_error == 1` | 0 | critical |
| missing item ≤ 15 min | `HostZpoolMissing` | one rule per declared pool: `absent(homelab_zpool_present{pool="<name>"} == 1)` | 2m | critical |
| stale data ≤ 1 h | `HostSmartStatusStale` | `time() - node_textfile_mtime_seconds{file=~"(.*/)?smart\\.prom"} > 2700` (three missed 15-minute runs), or that series is absent | 0 | critical |
| missing item ≤ 1 h | `HostDiskTelemetryMissing` | one rule per declared disk: `absent(homelab_smart_device_up{disk="<name>"} == 1)`, which covers both "not read this run" (0) and "series gone" | 20m (two runs) | critical |
| watchdog | `Watchdog` | depends on fresh ingestion end to end; see Decision 8 | 0 | none (special route) |
| delivery | `AlertDeliveryFailing` | `increase(alertmanager_notifications_failed_total{integration=X}[15m]) > 0` | 0 | critical, routed to the other channel |
| storage | `MonitoringStorageLow` | `vm_free_disk_space_bytes` (pool free space, as VictoriaMetrics sees it) below 100 GiB (warn) or 70 GiB (crit); read-only at 50 GiB (Decision 12) | 5m | warning / critical |
| storage | `MonitoringStorageGrowth` | `sum(vm_data_size_bytes)` above 20 GiB | 30m | warning |
| (extra) | `KubeNodeMemoryPressure` | node `MemoryPressure` condition | 15m | warning |

Lowering Jellyfin's limit in a scratch namespace reproduces the motivating incident. Acceptance uses exactly that drill (task 10.2).

**Missing telemetry has three layers.** Each catches a failure the one before it cannot see:

1. **Source down.** `TelemetrySourceDown` fires when a declared scrape job fails (`up == 0`) or vanishes from discovery (`absent(up{job=…})`). The `absent` branch matters: a target that disappears produces no `up == 0` sample at all.
2. **Producer stale behind a live exporter.** node_exporter keeps answering even if the timers behind its textfile collector stop. `HostZpoolStatusStale` and `HostSmartStatusStale` read the file modification time that node_exporter reports, so a stuck or failing timer is visible within its bound. Worst case for ZFS: last good write, plus 600 s, plus about 1.5 minutes for scrape, evaluation and `group_wait`, is about 11.5 minutes, inside the 15-minute bound. For SMART: 45 minutes plus about 1.5 minutes, inside the 1-hour bound.
3. **Item missing from a fresh source.** `HostZpoolMissing` and `HostDiskTelemetryMissing` fire when a declared pool or disk is absent from an otherwise fresh file. Worst case for a disk: it fails just after a run, is marked unread at the next run 15 minutes later, and fires after 20 more minutes: about 37 minutes, inside the 1-hour bound.

Inhibition (Decision 6) keeps one cause to one alert: a down node_exporter inhibits layers 2 and 3 for that host, and a stale file inhibits its own missing-item alerts.

**Missing data must not resolve a firing storage alert.** If node_exporter stops while `HostZpoolUnhealthy` fires, the series vanish, the rule returns nothing and vmalert would resolve the alert, which reads as "healthy". Inhibition does not prevent that. The host storage rules therefore wrap their inputs in `last_over_time(…[2h])`. When data stops, the last reported state holds for 2 hours while `TelemetrySourceDown` fires. When fresh data arrives, it is the newest sample and wins at once, so a real recovery still resolves immediately. A stale textfile needs no wrapper, because node_exporter keeps serving its last content.

**Finished pods do not count as not ready, and an eviction alerts once.** A finished pod can stay in the API indefinitely. For example, an evicted Jellyfin pod remains in phase `Failed`, with its container in `ContainerStatusUnknown`, after its replacement is Ready, and Kubernetes only garbage-collects such pods at a cluster-wide threshold. A not-ready rule that counted it would fire forever. `KubePodNotReady` therefore joins on `kube_pod_status_phase` and counts only `Pending`, `Running` and `Unknown` pods.

The eviction itself is still worth one notice, so `KubePodEvicted` fires on the rising edge: it is true only while the evicted pod is less than 30 minutes old in that state. That gives one warning, then one resolution, with no daily repeats while the pod object lingers. Rule unit tests cover both: a lingering `Failed` pod raises no not-ready alert, and an eviction fires once and then resolves (task 4.1). If the replacement pod does not become ready, `KubePodNotReady` fires for the replacement as usual.

**Jobs alert on terminal failure only.** `kube_job_status_failed` counts failed pods and becomes non-zero on the first failed attempt, even if a retry then succeeds. The `Failed` Job condition is set only when Kubernetes gives up: `backoffLimit` exhausted or `activeDeadlineSeconds` passed. The alert needs no `for`, because the condition is terminal. It resolves when the Job is deleted, for example by its `ttlSecondsAfterFinished` or by a CronJob's history limit. A rule unit test covers a Job that fails once and then succeeds (task 4.1).

### 6. Alertmanager routing and inhibition

- **Grouping.** Group by `alertname`, `namespace`, `host` and `instance`. Use `repeat_interval` 4h for critical and 24h for warning. Send resolved notifications.
- **Routes, in order:**
  1. `alertname="Watchdog"` goes to `heartbeat` (webhook to the healthchecks.io ping URL), with `group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 5m`, and `continue: false`. The `heartbeat` receiver sets `send_resolved: false`. Otherwise the "resolved" message that Alertmanager sends when the Watchdog stops would reach the ping URL and count as one more successful ping.
  2. `AlertDeliveryFailing{integration="pushover"}` goes to the receiver `telegram-only`, and `{integration="telegram"}` goes to `pushover-only` (priority 1). Each failing channel is reported only through the other one.
  3. `severity="critical"` goes to the receiver `critical`, which holds a Pushover config at priority 1 and a Telegram config.
  4. The default (`severity="warning"`) goes to the receiver `warning`, which holds a Pushover config at priority 0 and a Telegram config.
  - One receiver with two integrations, rather than two routes with `continue: true`, keeps each alert on a single route, so grouping, repeats and resolution notices stay in step across both channels. Alertmanager still counts failures per integration, which `AlertDeliveryFailing` needs.
- **This routing is configuration, not contract.** The `fleet-monitoring` spec requires only that critical alerts reach both channels without being held by quiet hours, that warnings reach at least one channel, that resolutions are sent, and that each channel's failures are reported through the other. Which channel gets which severity, and at what priority, is concrete desired state in the Alertmanager config that Nix renders. The owner can change it there, for example to send warnings to Telegram only, without a spec change. Task 4.2's route tests are the guard that the config still meets the spec.
- **Quiet hours and priorities.**
  - **Pushover.** The owner sets quiet hours in the Pushover app, not in Homelab. The sender only chooses each message's priority. Priority 1 (high) bypasses quiet hours and always alerts audibly; priority 0 (normal) respects them, so a warning during quiet hours arrives silently. Critical alerts use priority 1 and warnings priority 0. Emergency priority 2 is not used, because it needs acknowledgement and retry settings.
  - **Telegram.** The Bot API has no sender-side quiet hours. Every message, warning or critical, notifies when it arrives, unless the owner mutes the chat in the Telegram app. Muting the alert chat would also silence critical alerts there, so the runbook advises against it; Pushover priority 1 still covers critical alerts if the owner does mute it.
- **Messages.** Both channels use a short template: alert name, severity, object, summary and a Grafana link.
- **Inhibition:**
  - critical inhibits warning with the same `alertname` and object labels (for example free space at 5% versus 10%);
  - `TelemetrySourceDown{job="host-node"}` inhibits `HostRequiredMountMissing`, `HostSystemdUnitFailed`, `HostZpoolStatusStale`, `HostSmartStatusStale`, `HostZpoolMissing` and `HostDiskTelemetryMissing` for the same `host`, so one cause raises one alert;
  - `HostZpoolStatusStale` inhibits `HostZpoolMissing`, and `HostSmartStatusStale` inhibits `HostDiskTelemetryMissing`, for the same `host`;
  - `KubePodCrashLooping` inhibits `KubePodNotReady` and `KubeContainerRestarted` for the same pod;
  - `EndpointDown` for a route is not inhibited by pod alerts. They tell different stories.
- **Credentials from files.** Every credential field uses its `*_file` form, so the rendered config contains only paths: Pushover `user_key_file` and `token_file`, Telegram `bot_token_file`, webhook `url_file`.
  - If the pinned Alertmanager has no file form for Telegram `chat_id`, an init container fills the chat ID into the config inside a memory-backed volume from the mounted Secret. The value is still not in Git.
- **Missing credentials.** The Secret volume is mounted with `optional: true`. A missing credential then makes that integration fail at send time, which shows up in `alertmanager_notifications_failed_total` and as missing heartbeats. Alertmanager itself still runs and stays Healthy. This keeps the spec's "fails visibly, never a placeholder" rule without Degrading the Application. Task 4.3 verifies the pinned version's behavior.
- **Delivery failures are seen only on send attempts.** `AlertDeliveryFailing` reads `alertmanager_notifications_failed_total`, which grows only when Alertmanager tries to send through an integration and fails. A channel that breaks while nothing is firing, for example a revoked Pushover token or a bot removed from the chat, goes unnoticed until the next notification through it. That notification is often the important one. The other channel still carries it, and `AlertDeliveryFailing` then reports the broken channel. The heartbeat does not help here: it proves Alertmanager can reach healthchecks.io, not Pushover or Telegram. The spec states this limit.
- **Active channel checks are deferred.** This change keeps detection on send attempts as the contract. The options and the recommendation (a silent daily probe through Alertmanager) are recorded under "Deferred follow-ups".

### 7. Second channel: Telegram, with Discord as the recorded alternative

**Decided by the owner:** Telegram, with a dedicated bot.

- The owner already uses it daily for Hermes (`modules/den/aspects/workloads/hermes.nix:620`).
- Alertmanager has native `telegram_configs`.
- healthchecks.io has a native Telegram integration.
- Use a **dedicated bot**, not Hermes's bot. Hermes credentials and outages then stay separate from alerting, and either bot token can be revoked alone.

**Recorded alternative:** Discord.

- Its webhook URL is a single write-only credential with no bot to create.
- Alertmanager (`discord_configs`, `webhook_url_file`) and healthchecks.io both support it natively.
- Choose it if the owner prefers a server channel or shared visibility.
- Switching later changes one receiver and one secret. The specs do not change.

### 8. Watchdog: healthchecks.io, and why Pushover cannot be the watchdog

The `Watchdog` rule fires only while fresh telemetry is being stored, so the heartbeat exercises the whole chain: collection → storage → vmalert → Alertmanager → egress → internet. Alertmanager re-sends the alert every 5 minutes to the healthchecks.io ping URL.

**Why not `vector(1)`.** An always-firing `vector(1)` proves only that vmalert can evaluate and Alertmanager can send. If scraping stopped, or VictoriaMetrics turned read-only because its disk filled, `vector(1)` would keep firing and the heartbeat would keep arriving while no fresh data existed. Every other rule would then evaluate old or missing data, and nothing would say so.

**The expression:**

```promql
vector(1)
  and on() (sum(increase(vm_rows_added_to_storage_total[3m])) > 0)
  and on() (
    time() - max(
        timestamp(kubelet_running_pods{job="kubelet"})
      or timestamp(machine_cpu_cores{job="cadvisor"})
      or timestamp(kube_node_info{job="kube-state-metrics"})
      or timestamp(node_time_seconds{job="host-node"})
    ) < 180
  )
```

- **First term: the store is still writing.** `vm_rows_added_to_storage_total` counts rows that reached storage. It stops growing when ingestion stops for any reason, including read-only mode at the free-space floor (Decision 12). VictoriaMetrics' self-scrape is itself stored, so when storage stops, even this counter's own samples stop arriving and the term goes empty. The owner's example, `vm_rows_inserted_total`, counts rows at ingestion, before storage. It would work as well if the pinned version stops it in read-only mode, but the storage-side counter measures the property the spec cares about directly. Task 4.1 confirms the metric names and their read-only behavior against the pinned version, and the VM test in task 4.5 exercises read-only mode.
- **Second term: data from outside monitoring is still arriving.** Self-scrape alone can keep the first term true even when every other scrape fails, for example after a NetworkPolicy or scrape-config mistake. The second term requires the newest sample from any of the four core sources (kubelet, cAdvisor, kube-state-metrics, host node_exporter) to be under 180 seconds old. Each metric chosen is always present and written only by a successful scrape, unlike `up`, which is also written when a scrape fails.
- **Bounds.** 180 seconds is six 30-second scrape intervals: long enough to ride through a slow scrape or a pod restart, short enough to keep the total well inside the spec's 30 minutes. The 3-minute `increase` window holds about six self-scrape samples. Worst case: ingestion stops at T; the Watchdog stops firing by about T + 3.5 minutes; the last ping was sent then or earlier; healthchecks.io declares the check down 15 minutes after the last ping (5-minute period plus 10-minute grace). The owner is notified about T + 19 minutes, inside the 30-minute bound.
- **A stale query path also stops the heartbeat.** If vmalert cannot query VictoriaMetrics, the rule returns nothing and the Watchdog stops.

**One stale core source does not stop the heartbeat.** The heartbeat answers one question: can monitoring still tell the owner about faults? With one core source stale and the rest of the chain working, it can, and it does: `TelemetrySourceDown` is critical for every core source and names the source (Decision 5). Stopping the heartbeat as well would add a second, vaguer notice ("heartbeat down") for the same cause. The owner also could not silence it during known maintenance, because the absence of a heartbeat cannot be silenced in Alertmanager. The heartbeat stops when **all** core sources are stale, because then the scraper itself, or the network path it depends on, is broken.

**How the Watchdog differs from `TelemetrySourceDown`:**

| | `TelemetrySourceDown` | Watchdog heartbeat |
| --- | --- | --- |
| Detects | One declared source failing or vanishing | Monitoring as a whole unable to ingest, evaluate or route |
| Evaluated by | vmalert, inside the fleet | healthchecks.io, outside the fleet, on the absence of pings |
| Needs working | collection of the other sources, vmalert, Alertmanager, a delivery channel | nothing in the fleet |
| Tells the owner | which source, on which host | only that monitoring went quiet |
| Bound | 15 minutes | 30 minutes |

The check uses a 5-minute period and a 10-minute grace. If no ping arrives within 15 minutes, healthchecks.io notifies through its own Pushover and Telegram integrations. It also reports recovery when pings resume.

**Why Pushover alone cannot be the watchdog:**

- Pushover only delivers messages it receives. It has no notion of an expected message and nothing that fires when messages stop arriving.
- If the guest, host, power or uplink is down, no message is sent, so Pushover stays silent. Silence is exactly the failure to detect.
- A dead man's switch inverts this: it alerts on absence.

**Notes on the external service:**

- **Decided by the owner:** hosted healthchecks.io on the free tier, which covers this one check and its Pushover and Telegram integrations.
- The owner creates the check by hand (task 9.3), and the runbook records its settings. Declaring the check configuration, for example through the healthchecks.io management API, may come later; this change does not do it.
- Recorded alternatives outside the fleet: self-hosted Healthchecks on a VPS, Cronitor, or Better Stack heartbeats. Switching changes only the heartbeat URL secret and the runbook.
- An internet outage at home also triggers the watchdog. That is correct: the fleet cannot alert while it is offline.

### 9. Grafana, sign-in and provisioning from Git

- **Chart.** The Grafana chart moved to `grafana-community/helm-charts` (OCI on ghcr) in January 2026. Pin it with `downloadHelmChart` (version and hash) rather than the frozen nixhelm `grafana/grafana` 10.5.15. Pin the image as `tag@digest`.
- **Route.** `routes.grafana`: namespace `monitoring`, service `grafana`, `auth = "admin"`, `exposure = "public"`, `displayName = "Grafana"`, `pathPrefix = "/"`. This is the same shape as `routes.argocd` in `modules/den/clusters/home.nix`.
  - **Why public:** the owner decided to reach Grafana from anywhere, not only from the LAN and tailnet.
  - The public edges publish it like Argo CD. `public-edge.nix` serves a public `admin` route only in identity phase `normal`.
  - The Gateway's HTTPRoute for an `admin` route exists only in that phase too. It ships in the `identity-gateway` Application together with its SecurityPolicy, and the policy syncs first (in-Application wave -1, route at 0; `gateway.nix:180`, `identity.nix:339`). Grafana is therefore never served without entrance sign-in.
  - Alerting does not need the route.
- **Two layers of sign-in, both required.** Being public does not weaken access: Grafana stays admin-only, through central sign-in, at both layers.
  1. **Entrance.** Identity gives every `admin` route a Gateway SecurityPolicy (`grafana-admin` in namespace `gateway`) with Kanidm OIDC, as for `argocd-admin`. The Gateway requires Kanidm sign-in by a member of the admin group before it forwards any request to Grafana. Unauthenticated requests from the internet get a redirect to Kanidm and never reach the Grafana pod. Non-admins cannot complete that sign-in, because provisioning grants the client's scopes to the admin group only.
  2. **Grafana itself.** Grafana signs the user in again through its own generic OAuth, using the same Kanidm client as the route (the shared client below). Role mapping is strict, so only the admin group gets a role. The login form, basic auth and anonymous access are off, so there is no local or anonymous way in.
  - Passing the entrance alone does not grant Grafana access. This follows the `access-control` rule already applied to Argo CD.
  - Grafana service accounts and API keys are not created. Even if one existed, the entrance would still demand browser sign-in first, so token-only access from outside is not possible.
  - Through its data sources, a signed-in admin can query VictoriaMetrics and view or silence alerts in Alertmanager. That is the only path to monitoring data from outside the cluster. The route forwards only to Grafana; VictoriaMetrics, vmalert, Alertmanager and the exporters are never published (Decision 10).
- **Shared client: the smallest change.** Identity already creates a Kanidm client named after every `admin` route, for the Gateway's SecurityPolicy. Argo CD extends its route's client through a hard-coded case in `identity.nix` (`identity.nix:105-139`), with a matching Kanidm NetworkPolicy allow for `argocd-server` (`identity.nix:648-664`). Grafana needs the same four things on the `grafana` client:
  - its callback, `/login/generic_oauth`, added to the redirects;
  - its landing page, Grafana's sign-in;
  - scopes `openid profile email groups_name`;
  - one more Secret target, `monitoring/grafana-oidc:client-secret`;
  - and a Kanidm NetworkPolicy allow for Grafana's pods.
- **Default: a Grafana case beside the Argo CD case.** Add a sibling of the Argo CD block for Grafana, with the same shape and its own assertion that the route exists and is served at `/`. This touches nothing Argo CD generates.
- **Generalize only if it stays small.** A shared per-route helper, `{ callbackPaths, landingPath, scopes, secrets }`, is acceptable in this change only if two conditions hold. First, Argo CD's generated Kanidm client, Secret targets and NetworkPolicy must be byte-for-byte unchanged. Second, `modules/tests/identity-contracts.nix` must pass without any edit to its Argo CD assertions. If either fails, keep the sibling case and leave the generalization to the deferred cleanup ("Deferred follow-ups").
- Either way, Kanidm lists Grafana once, although both the entrance and Grafana sign in through it. That satisfies the existing access-control requirement that each administrator application is offered once.
- **Grafana settings.**
  - Sign-in: `auth.generic_oauth` with `client_id = grafana`, the client secret read from file, the Kanidm authorize, token and userinfo URLs on the canonical identity hostname, and `use_pkce = true`.
  - Roles: `role_attribute_path = contains(groups[*], '<adminGroup>') && 'Admin' || ''` with `role_attribute_strict = true`, so non-admins get no access.
  - Other sign-in paths: `auth.disable_login_form = true`, `auth.basic.enabled = false`, `auth.anonymous.enabled = false`, `oauth_auto_login = true`. Because the entrance sign-in already holds a Kanidm session, Grafana's own sign-in usually completes without a second prompt.
  - Cluster DNS already rewrites the identity hostname to the Kanidm Service, so token exchange stays in the cluster.
- **Local credentials.**
  - The chart's default admin password would be a `randAlphaNum` rendered into Git by nixidy. Instead, `admin.existingSecret` points at a runtime Secret with `generator = "alnum-no-newline"`, like Argo CD's `server.secretkey`.
  - `security.secret_key` is handled the same way.
  - The admin account cannot sign in through the entrance, because the login form and basic auth are disabled.
  - Break-glass is `kubectl` on the host, as for Argo CD. Grafana is not on any recovery path.
- **Data sources.** Provisioned from a ConfigMap and not editable:
  - VictoriaMetrics as type `prometheus` (no plugin download);
  - Alertmanager as type `alertmanager` (implementation `prometheus`), so admins can view and silence alerts.
- **Dashboards.**
  - JSON files live under `assets/monitoring/dashboards/`. Each records its upstream source, revision and SHA-256.
  - Nix renders them into ConfigMaps and loads them through a file provider with `allowUiUpdates: false` and `disableDeletion: true`.
  - **Minimal first set:** Node Exporter Full (grafana.com 1860) for the host; a Kubernetes workloads view from kubernetes-mixin (namespace and pod CPU, memory, restarts and OOM events); and "Homelab overview", written in this repository.
  - **Deferred:** the Argo CD, cert-manager, SMART, blackbox and VictoriaMetrics dashboards ("Deferred follow-ups"). No alert depends on any dashboard, so deferring them removes no detection.
  - "Homelab overview" shows firing alerts, endpoint probe status, pool, SMART and mount state, free space, and the pods using the most memory relative to their limit. That covers the deferred dashboards' most important panels at a glance.
  - Grafana's database lives on an `emptyDir` and is disposable.

### 10. Network policy and exposure

- **`monitoring` namespace.** Default-deny ingress, then narrow allows:
  - Gateway data plane → Grafana 3000;
  - Grafana → VictoriaMetrics 8428 and Alertmanager 9093;
  - vmalert → VictoriaMetrics and Alertmanager;
  - VictoriaMetrics → its scrape targets: kube-state-metrics, blackbox, and self-scrape of monitoring components.
- **Allows in other namespaces.** Where a target namespace has an ingress policy that selects the target pods, the monitoring Application owns a narrow `allow-from-monitoring` policy on the metrics port only. NetworkPolicies are additive, so removing monitoring removes only these allows. Today no target needs one: the Argo CD controller already allows all namespaces, and cert-manager has no policies.
- **No other routes.** No HTTPRoute exists for VictoriaMetrics, vmalert, Alertmanager or the exporters, so neither the Gateway nor the public edges, which serve only declared routes, can publish them. An evaluation check fails if any route targets a monitoring Service other than Grafana, or if the Grafana route is not `auth = "admin"`.
- **Egress.** Alertmanager needs outbound 443 to `api.pushover.net`, `api.telegram.org` and `hc-ping.com`. No egress policies exist in the cluster today, and this change adds none.

### 11. Failure domain

- **Applications.**
  - `monitoring-retained`: namespace, PV and PVC, with `Prune=false,Delete=false`, at **wave 5**.
  - `monitoring`: everything else, at **wave 6**.
  - Both are later than every other Application. An evaluation check fails if any non-monitoring Application declares a wave ≥ 5, so a degraded monitoring child never blocks a later wave (PR #43 semantics).
  - The retained Application deliberately does not use the usual -2 wave for retained state. A retained Application at -2 would put monitoring in front of everything.
- **No CRDs** (Decision 2). No other Application can depend on a monitoring API type.
- **Bootstrap and recovery are unaffected.**
  - `household-bootstrap` does not wait on root Application health (`pkgs/by-name/compute-runtime/internal/bootstrap/run.go`).
  - The replacement test syncs only its fixture child Applications (`modules/tests/prod-home-replacement.py:597`).
  - A Degraded monitoring child makes the root Application show Degraded. That is visible, not gating.
- **Retained path side effect.** Adding the retained path changes the `retained-directories` ConfigMap, so `retained-storage` reruns its Job once (PR #48). This is the same path every new retained application takes.
- **Metrics storage does not gate anything.** Monitoring adds no device, mount or boot dependency. Only the VictoriaMetrics pod depends on its retained path, and that pod fails closed (Decision 12).
- **Host exporters and timers** are plain units outside any activation dependency, with restart-on-failure.
- **Alerting does not depend on identity, the Gateway or cert-manager.** Only Grafana and endpoint probes involve them, and probes are meant to notice their failure.

### 12. Retention and persistence

**Decided by the owner:** keep 90 days of history on a retained path under the existing state root, bounded by retention and a free-space floor. Per-workload quota-limited datasets are deferred to a future storage change (see "Deferred follow-ups").

- **Why retained:** guest replacement is the routine recovery action (ADR-0008). Disposable history would erase exactly the trends needed after an incident: memory growth before an OOM, disk fill, error counters.

**Layout**

- Retained path `monitoring-metrics` under the state root `/var/lib/homelab/compute-1/state` on `rpool/safe/persist`. It is owned by the VictoriaMetrics UID and GID as mapped into the guest, with mode `0700`.
- A static `local` PV and PVC, like `identity-kanidm`, pinned to the compute instance, in the `monitoring-retained` Application with `Prune=false,Delete=false`.
- `-retentionPeriod=90d`.

**What is bounded, and what is not**

- **The PVC size is advisory.** Kubernetes does not enforce the capacity of a `local` or local-path volume. The claim's size is a label, not a limit, and the design does not present it as one.
- **The free-space floor is measured on shared storage.** `rpool/safe/persist` has no quota. Inside the guest, `df` on the state root reports that dataset, and its "available" is the pool's free space. `-storage.minFreeDiskSpaceBytes` therefore compares against free space on the whole pool, shared with every other retained path and host dataset.
- **So the floor bounds monitoring only in one direction.** Monitoring stops writing before it takes the pool's last 50 GiB. Before that point, its own growth is bounded only by retention. And if another workload fills the pool, monitoring stops ingesting, which protects the others, not monitoring. The spec says this plainly.

**Sizing**

- **Estimate.** About 30k active series at 30 s is about 1,000 samples/s, or 86 M samples/day. At about 0.4–0.8 bytes per sample that is 35–70 MB/day.
- **Retention on disk.** VictoriaMetrics stores data in monthly partitions and deletes a partition only once all of it is older than `-retentionPeriod`. The disk therefore holds up to retention plus one month, about 120 days: 4–8.4 GiB.
- **Floor.** `-storage.minFreeDiskSpaceBytes=50GiB`. rpool has about 760 GiB in total and 341 GiB free today, so 50 GiB is about 6.5% of the pool. That keeps room for ZFS itself and for other workloads to keep writing.

**Alerts, in the order they fire**

1. **`MonitoringStorageGrowth` (warning):** VictoriaMetrics' own data size (`vm_data_size_bytes`, summed) exceeds 20 GiB, about 2.4 times the upper estimate. This is the only bound on monitoring's *own* growth before the floor; it catches series-cardinality explosions while the pool still has room.
2. **`MonitoringStorageLow` (warning):** `vm_free_disk_space_bytes` below 100 GiB. The pool is filling, from monitoring or anything else.
3. **`MonitoringStorageLow` (critical):** below 70 GiB. Ingestion will stop at 50 GiB.
4. **Read-only at 50 GiB.** VictoriaMetrics refuses new writes, and existing history stays queryable. No new alert can fire from fresh data, because VictoriaMetrics' own metrics can no longer be stored. The fresh-data heartbeat therefore stops (Decision 8), and healthchecks.io notifies the owner about 19 minutes later.

`HostFilesystemLowSpace` (10% and 5%) still applies to the host filesystems, including `/persist`. It reports the pool from the host's point of view. `MonitoringStorageLow` reports how close monitoring is to stopping.

**Fail closed on the existing retained path**

- The `retained-directories` Job creates `monitoring-metrics` only after checking the state-root marker `.homelab-state-root`, which exists only on the persistent side of the state root. This is existing behavior for every retained path.
- The PV is a static `local` volume. Kubelet does not mount a `local` PV whose path is missing, which has the same effect as hostPath `type: Directory`. Monitoring never uses `DirectoryOrCreate` or a dynamically provisioned volume.
- The VictoriaMetrics pod also mounts the marker file read-only, with hostPath `type: File`. Kubelet refuses to start the pod if the state root it sees is not the persistent one.
- Result: if the retained storage is missing, VictoriaMetrics does not start, nothing is written to substitute storage, the heartbeat stops, and healthchecks.io reports it.
- **Nothing else is gated.** The state root device is already required by the guest for all retained state; monitoring adds no new device, mount or boot dependency. A missing `monitoring-metrics` directory affects only the VictoriaMetrics pod.

**Storage contract check**

- **`storage-foundations` (current): met, no change needed.** The path is under the existing encrypted, persistent state root; nothing is provisioned destructively; the host owns the storage; and history survives guest replacement.
- **`storage-placement-contract` (active, not yet current).** The retained path follows its fail-closed, does-not-gate, declared-ownership and no-rewrite rules. Per-workload capacity isolation is not part of it today; it is deferred (see "Deferred follow-ups").

**Other state**

- **Disposable state:**
  - Grafana's database (emptyDir). Dashboards and data sources come from Git.
  - Alertmanager's notification log and silences (emptyDir). After a replacement, active alerts re-notify once and silences must be re-created. That is accepted.
  - vmalert holds no state.
- **Not a backup.** This is not a backup. Backup and recovery monitoring is the deferred future change.

### 13. Secrets

All of these go in `.secrets/hosts/compute-1/` as runtime secrets in namespace `monitoring`, staged by `compute-stage-secrets`.

| Runtime secret | Supplied by | Consumer |
| --- | --- | --- |
| `monitoring--alertmanager-delivery--pushover-token` | operator (`agenix edit`) | Alertmanager |
| `monitoring--alertmanager-delivery--pushover-user-key` | operator | Alertmanager |
| `monitoring--alertmanager-delivery--telegram-bot-token` | operator (dedicated bot) | Alertmanager |
| `monitoring--alertmanager-delivery--telegram-chat-id` | operator | Alertmanager |
| `monitoring--alertmanager-delivery--heartbeat-url` | operator (healthchecks.io ping URL) | Alertmanager |
| `monitoring--grafana-admin--admin-password` | generator `alnum-no-newline` | Grafana |
| `monitoring--grafana-admin--secret-key` | generator `alnum-no-newline` | Grafana |

- **Grafana OIDC secret.** The OIDC client secret is not an agenix secret. Kanidm provisioning publishes it into `monitoring/grafana-oidc`, as it does for Argo CD. Identity's publication RBAC gains that one name-scoped target.
- **Treating identifiers as secrets.** The heartbeat URL is a credential: anyone holding it can send pings and hide an outage. The chat ID and the Pushover user key are low-risk identifiers, but they stay out of the public repository.
- **Payloads.** Alert templates use labels and annotations from rules only. kube-state-metrics does not export Secret resources (Decision 3). A check greps generated manifests and rendered configs for the secret names' values (task 4.4).

### 14. Resource budget

| Component | Requests (CPU / mem) | Limits (CPU / mem) |
| --- | --- | --- |
| VictoriaMetrics single | 100m / 384Mi | 1 / 1.5Gi |
| vmalert | 25m / 64Mi | 250m / 256Mi |
| Alertmanager | 25m / 48Mi | 250m / 128Mi |
| Grafana | 50m / 192Mi | 1 / 1Gi |
| kube-state-metrics | 25m / 64Mi | 250m / 256Mi |
| blackbox exporter | 10m / 32Mi | 100m / 128Mi |
| **Guest total** | **≈ 235m / ≈ 0.8Gi** | **≈ 2.9 CPU / ≈ 3.3Gi** |
| Host: node_exporter, `zpool-status` and `smart-status` timers | — | 64M `MemoryMax` each |

- Against the PR #52 guest (12 CPU / 32 GiB): about 2.5% of memory requested, about 10% at limits.
- Against today's guest (4 CPU / 12 GiB): about 7% requested, about 27% at limits. It fits, but PR #52 should land first.
- For comparison, kube-prometheus-stack typically requests 1.5–2.5 GiB at this scale, before Prometheus's WAL replay spikes.

### 15. Charts, images and pinning

- **Charts:**
  - from nixhelm: `prometheus-community/prometheus-blackbox-exporter` 11.18.0;
  - via `downloadHelmChart` (version and hash): VictoriaMetrics `victoria-metrics-single` and `victoria-metrics-alert` (the latter also renders Alertmanager), `prometheus-community/kube-state-metrics`, and `grafana-community/grafana`.
- **Hooks and tests.** Helm hooks are ignored by Argo, and they render as plain objects. Chart test pods and hook Jobs are disabled, following the cert-manager `startupapicheck` precedent.
- **Images.** Every image is pinned as `tag@digest`.
- **Alternative.** Render plain Nix objects for VictoriaMetrics, vmalert and Alertmanager. Each is one Deployment, Service and ConfigMap, like the Kanidm and Jellyfin aspects. Choose per component at implementation; the choice does not affect the specs.

### Cleanup note (not part of this change)

The following dead code was found while planning. It is recorded for a follow-up and is not touched here:

- `den.quirks.prometheus-targets` currently has no producer or consumer. This change gives it both (Decision 4).
- The host schema's `exporters` option (`modules/den/schema/host.nix:78-91,272-279`) is unused and overlaps the quirk. A follow-up should remove it, so the quirk is the only path.
- The `collect-host-addrs` and `collect-ollama-endpoints` policies (`modules/den/policies/pipes.nix:11-17,27-33,46-48`) collect quirks that are never declared (`host-addrs`, `ollama-endpoints`).
- `compute-runtime` bootstrap still has readiness handling for `Prometheus` and `Alertmanager` objects (`internal/bootstrap/manifests.go:174`, `run.go:286-288`, `modules/den/aspects/kubernetes/bootstrap.nix:68`). The static bootstrap bundle now contains only Argo CD.

## Deferred follow-ups

These are recorded so they are not lost. None is part of this change.

### Per-workload quota-limited retained datasets (a future storage change)

- **What.** Give each retained workload its own ZFS dataset with an enforced capacity limit, instead of a directory under the shared state root on `rpool/safe/persist`. Candidates: Kanidm, Jellyfin config, the Arr databases, Immich, and metrics history.
- **Why.** Today a runaway workload can fill the pool for all of them, and a free-space floor is not isolation (Decision 12). Once the change lands, metrics moves to its own dataset, and `fleet-monitoring`'s storage requirement can tighten from "bounded" to "isolated".
- **Relationship to other contracts.** It must keep consumer-visible paths stable, so that a workload sees the same guest path before and after its move (`storage-placement-contract`, "Consumer-visible storage paths are stable and semantic"). It must also keep the fail-closed, does-not-gate, declared-ownership and no-rewrite rules of that change, and the encryption, provisioning and ownership rules of `storage-foundations`.
- **Open questions for that change:**
  - **Granularity.** One dataset per workload, per retained path, or per class of data?
  - **Quota versus reservation.** `quota` or `refquota` caps a workload. A `reservation` protects it from others, but sets space aside up front. Each workload needs one, both, or neither.
  - **Guest attachment.** Nested mounts do not show through: the state root reaches the guest as one non-recursive Incus disk device, so a dataset mounted inside it is invisible, and the guest would see, and write to, the empty directory underneath. The options are one Incus device per dataset, each with its own `required` and propagation semantics, or a recursive `rslave` state device with per-dataset fail-closed markers.
  - **ID mapping.** How ownership is set through the guest idmap at provisioning, and how it stays stable across guest replacement.
  - **Migration of existing retained paths.** Copy or rename, the downtime per workload, changes to static PV paths, and rollback.
  - **Snapshots and backups.** The snapshot policy per dataset, how snapshots count against `quota` versus `refquota`, and how this fits the backup ownership that `storage-placement-contract` leaves to Preserve.
  - **Provisioning.** Disko creates datasets only at install time, so live hosts need an explicit, two-phase provisioning step, like `disk.luks-storage`.

### Active channel checks

- **Gap.** Delivery failures are detected only on send attempts (spec, delivery requirement). A channel that breaks while idle is found at its next notification.
- **Options considered:**

  | Option | How | For | Against |
  | --- | --- | --- | --- |
  | **Silent daily probe through Alertmanager (recommended)** | An always-firing `AlertChannelProbe` rule routes, ahead of the severity routes, to a `probe` receiver with `repeat_interval: 24h` and `send_resolved: false`. The receiver holds a Pushover config at priority −2, which Pushover delivers without any notification, and a Telegram config with `disable_notification: true`. A failed send raises `AlertDeliveryFailing` through the other channel. | Exercises the real path: Alertmanager's own integration configs, credential files, egress and the provider. No new component, image or secret handling. A broken channel is found within about 24 hours and 15 minutes. | One silent message per channel per day. The interval trades clutter against detection time. |
  | Validation CronJob | A CronJob calls Pushover's `users/validate.json` and Telegram's `getMe` and `getChat`, and pushes `homelab_alert_channel_check_success{channel}` into VictoriaMetrics. | No messages in either channel. | A new image, script, NetworkPolicy and write path into the store. It checks credentials, not Alertmanager's configuration. The Telegram token is in the request URL, so nothing may log URLs. |

- **Recommendation.** Add the silent daily probe as the first follow-up. It is a few lines of routing and one rule. It needs no spec change, because the spec's send-attempt wording already covers it.

### Further dashboards

Argo CD (Application health and sync history), cert-manager, SMART, blackbox (probe latency and certificate expiry) and VictoriaMetrics self-monitoring. Each is vendored with its source, revision and hash, as in Decision 9.

### Generalized per-route native sign-in

If Grafana's client is added as a sibling of the Argo CD case (Decision 9), turn both into one declared per-route setting later, with Argo CD's generated objects and identity tests unchanged.

### Already recorded elsewhere

External probing of the public routes, backups and recovery monitoring, and declarative healthchecks.io configuration (Non-Goals; proposal.md, Non-goals).

## Risks / Trade-offs

- [Monitoring dies with the guest, so a guest outage arrives as "heartbeat down" with no detail.] → Accepted. The watchdog guarantees notice. Retained metrics history lets the cause be read after recovery. Revisit placement when the fleet gains a second host.
- [Probes start inside the guest, so they miss failures in the host DNAT, LAN DNS, router or public edges.] → Accepted for this change and documented. External probing of the public routes (`idm`, `argocd`, `grafana`) is a follow-up change, as the owner decided.
- [Grafana is published on the internet, so its sign-in and its software are exposed to attackers.] → Two layers, both admin-only through Kanidm (Decision 9). The Gateway SecurityPolicy stops every unauthenticated request before it reaches Grafana, so Grafana's own attack surface is visible only to signed-in admins. The image is pinned and updated through Git. No other monitoring endpoint is published. Argo CD already runs this way.
- [Pushover receives warnings too, so noisy warnings cost attention on the primary channel.] → Warnings use normal priority and respect quiet hours, and repeat at most every 24 hours. Tune or retire noisy warning rules in the first two weeks.
- [Binding to the bridge address fails if the bridge does not exist yet. If a unit failure at switch time counts as activation failure, deploy-rs could roll back.] → Order after Incus network creation, restart on failure, and keep the units outside activation dependencies. Task 2.6 proves activation succeeds with the bridge absent.
- [Wave 5–6 placement must stay last as Applications are added (PR #25).] → An evaluation check fails on any non-monitoring wave ≥ 5.
- [Upstream dashboards may assume Prometheus Operator labels.] → Pin them, and adjust the label selectors once in the vendored JSON. The overview dashboard is ours.
- [Noise from routine restarts or syncs.] → `for` windows, inhibition and grouping. Tune severities during the first two weeks without changing the spec bounds.
- [SMART collection needs raw device access on the host.] → It runs in the `smart-status` oneshot, not a listening service. The unit gets only the device access it needs for the declared by-id paths, and it writes only `smart.prom`.
- [The fresh-data heartbeat depends on chosen metric names (`vm_rows_added_to_storage_total`, `kubelet_running_pods`, `machine_cpu_cores`, `kube_node_info`, `node_time_seconds`). If one is renamed in an upgrade, its term goes empty.] → For the storage counter, that stops the heartbeat: a false alarm that is loud and safe. For a single core-source metric, the other three keep the heartbeat alive, and `TelemetrySourceDown` does not depend on the metric name. Rule unit tests (task 4.1) pin the names, so an upgrade that changes one fails the check before deployment.
- [Metrics storage is not isolated. Monitoring can grow into shared pool space up to the floor, and another workload filling the pool stops monitoring.] → Accepted for now and stated in the spec. Retention bounds normal growth to about 8.4 GiB; `MonitoringStorageGrowth` catches abnormal growth at 20 GiB; the 50 GiB floor keeps monitoring from taking the pool's last space. Real isolation is the deferred per-workload dataset change.
- [Missing retained storage silently stops metrics history.] → It does not stay silent: VictoriaMetrics fails closed, the heartbeat stops, and healthchecks.io notifies the owner. The runbook explains how to tell this from other heartbeat losses: the VictoriaMetrics pod is waiting on its volume or its marker file.
- [The account configuration of healthchecks.io, Pushover and Telegram is outside the declaration.] → The runbook documents the exact check period and grace, the integrations, and how to rotate each credential.

## Migration Plan

1. **Host.** Add the host telemetry aspect, the status timers and the quirk consumer, with the disk IDs from task 2.1. The operator deploys `hvn-hyp1`. Confirm the exporter answers from the guest and not from the LAN (task 10.1).
2. **External accounts and secrets (owner, one time, tasks section 9).** Create the Pushover application, the dedicated Telegram bot and its chat, and the healthchecks.io check (5 min period, 10 min grace, Pushover and Telegram integrations). Run `agenix edit` for the five delivery secrets.
3. **Alerting core.** Merge `monitoring-retained` and `monitoring` without the Grafana route. Confirm the heartbeat reaches healthchecks.io, that a test critical alert reaches both channels and bypasses Pushover quiet hours, and that a test warning reaches both channels at normal priority.
4. **Dashboards.** Merge Grafana's per-route Kanidm client (Decision 9), the public Grafana route and Grafana's sign-in. From outside the household network, confirm that an unauthenticated request is redirected to Kanidm and never reaches Grafana, that an admin gets in, and that a non-admin is denied.
5. **Acceptance drills.** Run the drills in tasks section 10.

**Rollback.** Remove the monitoring aspects from `prod-home`. Argo prunes `monitoring`, while the retained namespace and PV stay protected. Revert the host aspect to close the exporter port. The retained path and its history stay on the host; rollback never deletes them. Nothing else depends on monitoring.

## Resolved Questions

The owner answered every open question in the first draft. Each answer is folded into the decision named.

1. **Second channel:** Telegram, with a dedicated bot. Discord stays the recorded alternative. (Decision 7)
2. **Warnings on Pushover:** yes, for now. Warnings go to Pushover at normal priority, respecting quiet hours, and to Telegram. Critical alerts go to Pushover at priority 1, bypassing quiet hours, and to Telegram. Cross-channel failure reporting stays. This assignment is Nix configuration; the `fleet-monitoring` delivery requirement states only the durable behavior, so changing the assignment later needs no spec change. (Decision 6)
3. **Severity of a single OOM kill:** critical. The `fleet-monitoring` workload requirement now says so. (Decision 5)
4. **Time bounds:** confirmed as proposed. (Decision 5)
5. **Grafana exposure:** `public`, behind Kanidm, like Argo CD. The Gateway requires admin sign-in before any request reaches Grafana, and Grafana signs in through the same client with strict role mapping and no local or anonymous sign-in. `access-control` gains a requirement for the entrance layer. (Decision 9)
6. **Retention:** 90 days on a retained path, with a 50 GiB free-space floor. Per-workload quota-limited datasets are deferred to their own storage change. The spec states plainly that metrics storage is bounded but not isolated. (Decision 12)
7. **Watchdog provider:** hosted healthchecks.io, free tier. Declarative check configuration may come later. (Decision 8)
8. **Disk scope:** SMART on all physical disks, including the unused `sdc`, `sdf` and `sdg`, except USB and virtual devices. After review, the disks are declared in host data by stable by-id path, and each must keep reporting. (Decision 4)
9. **Legacy gocryptfs mounts (media1–3):** not required mounts. Only media4's LUKS2 and XFS mount and the MergerFS pool `/srv/media/data` are. Others can be added through one declared list. (Decision 4)
10. **Free-space thresholds:** 10% warning and 5% critical. (Decision 5)
11. **External probing of the public routes:** a follow-up change. (Non-Goals, Risks)
12. **Backups and recovery monitoring:** a future change. (proposal.md, Non-goals)

The owner's review of PR #54 then asked for four more changes, folded in as follows:

- **Watchdog correctness:** the heartbeat now requires fresh data end to end. (spec: loss of monitoring; Decision 8)
- **Storage:** an honest bound instead of a claimed isolation: retention, a free-space floor with alerts before it, a growth alert, and fail-closed behavior on the existing retained path. Dedicated datasets are deferred. (spec: metrics history storage; Decision 12)
- **Evicted and finished pods:** `KubePodNotReady` excludes `Failed` and `Succeeded` pods, and evictions alert once as a warning. (spec: workload failures; Decision 5)
- **Scope cuts:** a minimal dashboard set, active channel checks deferred, and the smallest Grafana sign-in change. (Decisions 6 and 9; Deferred follow-ups)
- **Missing telemetry:** freshness of the textfile producers, and declared pools and disks that must keep reporting. (spec: missing telemetry; Decisions 4 and 5)
- **Alert semantics:** terminal Job failure only; delivery failures detected on send attempts. (spec: workload failures, delivery; Decisions 5 and 6)

## Open Questions

None block this change.

- **SMART collection by a timer instead of `smartctl_exporter`.** Accepted in principle by the owner (Decision 4). Nothing found since argues against it.
- Implementation detail to settle in task 4.2: whether the pinned Alertmanager reads the Telegram `chat_id` from a file, or needs the init-container fallback in Decision 6.

Later work, with no decision needed now, is listed under "Deferred follow-ups".
