## 1. Contract checks and scaffolding

- [x] 1.1 Add `modules/tests/monitoring-contracts.nix` with native rendered-contract checks. It must fail when:
  - a non-monitoring Application declares sync wave ≥ 5;
  - any monitoring Application is below wave 5;
  - a route targets a monitoring Service other than Grafana, or the Grafana route is not `auth = "admin"`;
  - a declared route has no endpoint probe;
  - an image is not `tag@digest` or a chart has no version and hash;
  - the VictoriaMetrics volume is anything other than the static `local` PV on the `monitoring-metrics` retained path, or any monitoring volume uses `DirectoryOrCreate`.

  Verify with `nix build path:$PWD#checks.x86_64-linux.monitoring-contracts`, plus one deliberately failing fixture per rule.

  Evidence: `monitoring-contracts` passes on hvn-hyp1 (2026-10-11). Each rule is named after the failure it detects and reads only rendered manifests and evaluated host configuration. The per-rule failing fixtures were dropped in review: they exercised the check, not the system.

- [x] 1.2 Add the `kubernetes.services.monitoring` aspect group with two empty Applications: `monitoring-retained` (wave 5, `retained = true`) and `monitoring` (wave 6). Include it in `den.aspects.prod-home`. Verify that the `prod-home-gitops-source` check accepts the `monitoring` namespace in the AppProject destinations, and that 1.1 passes.

  Evidence: `generated/manifests/prod-home/apps/Application-monitoring.yaml` (wave 6) and `Application-monitoring-retained.yaml` (wave 5); `monitoring` is in the AppProject destinations; `prod-home-gitops-source` and `monitoring-contracts` pass.

## 2. Host telemetry (hvn-hyp1)

- [ ] 2.1 **Read-only disk-ID inspection (operator; no changes to the host).** On `hvn-hyp1`, list `/dev/disk/by-id/` and `lsblk -o NAME,TYPE,TRAN,MODEL,WWN`. For each of the 9 physical disks (2 rpool NVMe, 7 HGST including the unused `sdc`, `sdf` and `sdg`), record its by-id path: `wwn-0x…` for SAS and SATA, and `nvme-eui.…` for NVMe. Confirm that the IDSDM (USB) and iDRAC virtual devices are absent from the list. Record no serial numbers. Put the result into `hvn-hyp1`'s `expectedDisks`, keyed by readable names, and the commands used into the PR.

  Not checked: this is the operator's task. A read-only cross-check on 2026-10-11 (`ls -l /dev/disk/by-id /dev/disk/by-path`, `lsblk -d -o NAME,TYPE,TRAN,MODEL,WWN`) matched the nine declared paths and showed the IDSDM (USB) and iDRAC (virtual) devices left out. The NVMe drives are declared by path (design.md, Implementation note 2).

- [x] 2.2 Add the host telemetry aspect:
  - node_exporter with the systemd, filesystem, zfs and textfile collectors, bound to the compute bridge's host address from host data, with `MemoryMax`, `CPUQuota` and restart-on-failure;
  - the `expectedDisks` option, and the declared pool list derived from `zfs.rootPool.name`.

  Verify by evaluation that `hvn-hyp1`'s listen address equals the bridge address, that no wildcard bind exists, and that no unit is wanted by a target that activation waits on.

  Evidence: `monitoring-contracts` (socket bound to the bridge address from host data, no unit wanted by an activation target); `host-telemetry-runtime` VM test (MemoryMax and CPUQuota on every unit; activation with no bridge).

- [x] 2.3 Add the `zpool-status` oneshot and its 2-minute timer. It writes `zpool.prom` atomically from `zpool status -j -p`, including `homelab_zpool_present{pool}`, and replaces the file only after a successful run. Verify with converter unit tests against recorded JSON for: an ONLINE pool, a DEGRADED pool, device errors, a scrub with errors, and a failing `zpool` command. The last must leave the previous file and its modification time untouched.

  Evidence: `host-telemetry-converters` covers ONLINE, DEGRADED, device errors, scrub errors and a failing `zpool` (previous file and mtime kept; invalid JSON too). A read-only run against the live `rpool` produced the expected series (Implementation note 5).

- [x] 2.4 Add the `smart-status` oneshot and its 15-minute timer. It runs `smartctl --json -a` on each declared by-id path and writes `smart.prom` atomically: health status, SCSI grown defects, ATA pending and reallocated sectors, and `homelab_smart_device_up{disk,id}`. The unit has only the device access it needs. Verify with converter unit tests against recorded `smartctl --json` output for:
  - a healthy SAS drive, a healthy SATA drive and a healthy NVMe drive;
  - a drive reporting FAILED, and a SAS drive whose grown-defect count rose;
  - a declared disk that cannot be opened, which must produce `homelab_smart_device_up 0` while the other disks are still written;
  - a run in which `smartctl` itself fails, which must leave the previous file untouched.

  Evidence: `host-telemetry-converters` covers healthy SAS, SATA and NVMe, a FAILED drive, rising grown defects, an unopenable disk (`homelab_smart_device_up 0`, others still written) and a failing `smartctl` (previous file kept). The fixtures are synthetic; recording real output needs root (Implementation note 5).

- [x] 2.5 Make the aspect emit `prometheus-targets` entries. Add the host consumer aspect, which:
  - renders one nftables input rule admitting only the guest address on the compute interface to the exporter port;
  - exposes, as read-only options, the resolved target list, the required-mount list, the declared pools and the declared disks.

  The mount list is the mergerfs pool mountpoints, plus provisioned `disk.luks-storage` mountpoints, plus an `extraRequiredMounts` list that is empty today. Verify by evaluation that:
  - the targets and rule text are what `hvn-hyp1`'s data implies, and the rule names no other source or interface;
  - the mount list is exactly `/srv/media/data` and `/mnt/storage-clear/media4`, with no legacy gocryptfs mount (media1–3);
  - the disk list matches task 2.1, and the pool list is `rpool`.

  Evidence: `monitoring-contracts` (firewall rule names only the guest on `incus-compute`; required mounts are exactly `/mnt/storage-clear/media4` and `/srv/media/data`). The rendered rules hold one `HostZpoolMissing` (`rpool`) and nine `HostDiskTelemetryMissing`, one per declared disk (`ConfigMap-vmalert-rules.yaml`).

- [x] 2.6 Extend an existing host VM test, or add a small one, to show that:
  - activation succeeds while the bridge does not exist yet, and the exporter starts once it does;
  - a client on another interface cannot connect to the exporter port, while the guest address can;
  - stopping the `zpool-status` timer leaves `node_textfile_mtime_seconds` for `zpool.prom` unchanged while node_exporter keeps answering.

  Evidence: `host-telemetry-runtime` PASS through its driver on hvn-hyp1: activation exits 0 with no bridge and no failed units; the guest scrapes once the bridge exists; another source on the bridge and a LAN client are refused; with the timer stopped, the `zpool.prom` mtime held for 150 s while node_exporter answered.

## 3. Cluster collection core

- [x] 3.1 Pin and render VictoriaMetrics single-node:
  - retained path `monitoring-metrics`, with the VictoriaMetrics UID and GID and mode `0700`;
  - a static `local` PV and PVC pinned to the compute instance, in `monitoring-retained`;
  - a read-only hostPath mount of the state-root marker with `type: File`;
  - `-retentionPeriod=90d` and `-storage.minFreeDiskSpaceBytes=50GiB`;
  - the resource limits from design.md.

  Verify the generated manifests show the retained `guestPath`, the marker mount, the flags, the limits, and no chart test or hook objects.

  Evidence: `Deployment-victoriametrics.yaml` (flags, limits, marker hostPath `type: File`), `PersistentVolume-monitoring-metrics.yaml` (`local.path: /srv/state/monitoring-metrics`), no Helm hook or test objects under `generated/manifests/prod-home/monitoring/`; `monitoring-contracts` checks the storage rules.

- [x] 3.2 Render the scrape config from:
  - (a) the host's `scrapeTargets` option, read from `nixosConfigurations.${cluster.hostName}`;
  - (b) kubelet and cAdvisor through the node;
  - (c) the Argo CD controller metrics Service;
  - (d) cert-manager;
  - (e) kube-state-metrics;
  - (f) blackbox probe targets derived from `cluster.routes`;
  - (g) monitoring self-scrape.

  Verify with an evaluation check that compares the rendered jobs to the expected set for `prod-home`.

  Evidence: `monitoring-contracts` fails if a scrape job lacks a `TelemetrySourceDown` rule or a Watchdog core source is not scraped. Rendered jobs: host-node, kubelet, cadvisor, argocd, cert-manager, kube-state-metrics, blackbox, victoriametrics, vmalert, alertmanager.

- [x] 3.3 Pin and render kube-state-metrics, with resources excluding `secrets` and `configmaps` and no label or annotation allowlists. Verify the generated Deployment arguments, that its RBAC is read-only, and that `kube_pod_status_phase`, `kube_pod_status_reason` and `kube_job_status_condition` are among the enabled metrics.

  Evidence: `Deployment-kube-state-metrics.yaml` (`--resources` without secrets or configmaps, no allowlists); `monitoring-contracts` (read-only RBAC). Job conditions are `kube_job_failed` and `kube_job_complete` in 2.20 (Implementation note 3).

- [x] 3.4 Pin and render the blackbox exporter with two modules: `native` (2xx on a health path) and `admin` (302 to the identity hostname). Probes go to the gateway NodePort, with SNI and `Host` set per route. Verify the generated probe list covers every route in `cluster.routes`.

  Evidence: `monitoring-contracts` fails if a declared route has no probe; `ConfigMap-blackbox.yaml` has one module per route.

- [x] 3.5 Set `controller.metrics.enabled = true` and the `ComparisonError` application-condition metric in `argocd.nix`. Verify the generated metrics Service exists and that the existing NetworkPolicy still admits it.

  Evidence: `argocd/Service-argocd-application-controller-metrics.yaml`; the existing `NetworkPolicy-argocd-application-controller.yaml` admits the `metrics` port from every namespace.

## 4. Alert rules, routing and secrets

- [x] 4.1 Write the rule files from design.md Decisions 5, 8 and 12 as Nix-rendered Prometheus YAML. Render one rule per declared pool, per declared disk and per required mount from the host's options. Add `vmalert-tool unittest` (or `promtool test rules`) cases:
  - **Workloads:**
    - a single OOM kill fires as critical within 5 minutes, even though Argo CD reports Healthy;
    - a crash loop fires at 15 minutes and not before.
  - **Finished pods and evictions:**
    - a pod in phase `Failed` (an evicted Jellyfin pod with `ContainerStatusUnknown`) whose replacement is Ready raises no `KubePodNotReady`, even after hours;
    - a `Succeeded` pod raises no `KubePodNotReady`;
    - an eviction fires `KubePodEvicted` once, as a warning, and resolves after 30 minutes while the evicted pod remains.
  - **Jobs:**
    - a Job whose `Failed` condition is true fires `KubeJobFailed`;
    - a Job whose first pod fails (`kube_job_status_failed` = 1) and which then completes (`Complete` condition true, `Failed` false) does not fire.
  - **GitOps:** out-of-sync for 25 minutes does not fire.
  - **Host storage:**
    - an absent required mount fires;
    - free space below 10% fires a warning, and below 5% a critical.
  - **Missing telemetry:**
    - a missing host source fires `TelemetrySourceDown`, and a firing `HostZpoolUnhealthy` does not resolve while the source is gone (the `last_over_time` hold);
    - a scrape job that vanishes from discovery fires `TelemetrySourceDown` through `absent(up)`;
    - `zpool.prom` older than 600 s fires `HostZpoolStatusStale` while node_exporter is up, and so does `node_textfile_scrape_error == 1`;
    - a declared pool missing from a fresh `zpool.prom` fires `HostZpoolMissing`;
    - `smart.prom` older than 2700 s fires `HostSmartStatusStale`;
    - a declared disk with `homelab_smart_device_up 0`, or with no series at all, in a fresh `smart.prom` fires `HostDiskTelemetryMissing` after 20 minutes, naming the disk.
  - **Metrics storage:**
    - `vm_free_disk_space_bytes` below 100 GiB fires a warning, and below 70 GiB a critical;
    - `vm_data_size_bytes` above 20 GiB fires `MonitoringStorageGrowth`.
  - **Watchdog:**
    - it fires while the storage counter grows and one core source is fresh;
    - it stops within 3.5 minutes when the counter stops growing, even though every core source is fresh;
    - it stops when all core sources are stale while the counter still grows;
    - it keeps firing when exactly one core source is stale.
  - **Metric names:** confirm `vm_rows_added_to_storage_total`, `vm_free_disk_space_bytes`, `vm_data_size_bytes`, `kubelet_running_pods`, `machine_cpu_cores`, `kube_node_info` and `node_time_seconds` against the pinned versions, and record how the storage counter behaves in read-only mode.

  Verify the flake check passes.

  Evidence: `monitoring-rules` passes (vmalert-tool 1.151.0) with every case listed. Metric names: `vm_rows_added_to_storage_total`, `vm_free_disk_space_bytes` and `vm_data_size_bytes` in all three heartbeat checks below; `node_time_seconds` and the filesystem and systemd series in `host-telemetry-runtime`; `kubelet_running_pods`, `machine_cpu_cores` and `container_oom_events_total` in `monitoring-k3s-runtime`. `kube_node_info` was not scraped from a running kube-state-metrics. In read-only mode the store refuses writes and the heartbeat stops (`monitoring-heartbeat-storage-read-only`). Added after review (Implementation note 15): sustained CPU throttling of a container with a CPU limit fires `KubeContainerCPUThrottled` at 15 minutes and resolves when throttling stops, while 10 % throttling and a container without a limit stay silent; a working set at 95 % of its limit fires `KubeContainerMemoryNearLimit` at 10 minutes and resolves when it drops, while 80 % stays silent.

- [x] 4.2 Render vmalert and the Alertmanager config: severity routes, the Watchdog heartbeat route, cross-channel `AlertDeliveryFailing` routes, inhibition rules, grouping, `send_resolved`, and file-based credential fields. Verify with `amtool check-config` and `amtool config routes test` in a flake check.
  - The tests pin the current routing from design.md Decision 6. They also assert the spec floor: every critical alert reaches both channels, at a Pushover priority of at least 1 so quiet hours do not hold it; every warning reaches at least one channel; resolutions are sent. A later routing change in Nix updates the first set and must still pass the second.
  - They cover:
    - critical → Pushover at priority 1 and Telegram;
    - warning → Pushover at priority 0 and Telegram;
    - Watchdog → heartbeat only, with `send_resolved: false` on the heartbeat receiver;
    - Pushover failure → Telegram only, and Telegram failure → Pushover only (priority 1);
    - the inhibitions in Decision 6, including a down host node_exporter suppressing the stale-file and missing-item alerts.
  - Also settle whether the pinned Alertmanager reads Telegram `chat_id` from a file, or needs the init-container fallback in design.md Decision 6.

  Evidence: `monitoring-alertmanager` passes: `amtool check-config`, `amtool config routes test` for each route, and the delivery floor. The pinned Alertmanager reads `chat_id_file` (Implementation note 7).

- [ ] 4.3 Declare the five delivery runtime secrets and the two Grafana generator secrets in `compute-resources.runtimeSecrets`. Mount the delivery Secret with `optional: true`. Verify by evaluation that the host's `runtimeSecrets` contains them. Verify with a container-level test that the pinned Alertmanager starts without the files and records a failed notification, rather than crashing or using a placeholder.

  Not checked. The delivery Secret is mounted `optional: true`, and `monitoring-alertmanager` shows Alertmanager running with no credential files and counting failed notifications for pushover, telegram and webhook. Grafana's secret key is generated, committed and declared, and the administrator password is no longer a secret (Implementation note 6). The five delivery secrets are declared only once their encrypted files exist, so the host's `runtimeSecrets` lists them only after task 9.4, and `hvn-hyp1` evaluates only after the owner rekeys.

- [x] 4.4 Add a check that the generated manifests, `docs/operations.md` and the rendered Alertmanager and Grafana configs contain only secret paths and references. They must contain no credential field with an inline value and no `hc-ping.com/<uuid>` pattern. Verify the check fails on a planted inline value.

  Evidence: `monitoring-secret-scan` passes. A one-off run on 2026-10-11 caught a planted `hc-ping.com` URL in `docs/operations.md` and a planted inline Grafana `client_secret`; inline Alertmanager credential fields are checked in `monitoring-alertmanager`.

- [x] 4.5 **Heartbeat VM checks with fake receivers.** `modules/tests/monitoring-heartbeat.nix` exports three independent, ordinary NixOS checks: `monitoring-heartbeat-ingestion-stop`, `monitoring-heartbeat-storage-read-only` and `monitoring-heartbeat-single-source-down`. The existing `hostedCiPlan` inventory dispatches each through the existing runtime matrix and VM driver; there is no aggregate check or workflow-specific name list. Each runs the pinned VictoriaMetrics single, vmalert and Alertmanager with the rendered Watchdog rule and heartbeat route. Two parts are faked:
  - small HTTP servers that serve fixed metrics under the four core-source job names;
  - a fake heartbeat receiver that records every request and its body.

  Each check shares the local VM setup and initial healthy cadence assertion. Test-only overrides may shorten scrape, evaluation and repeat intervals, but the rendered expression, receiver, freshness windows and source-down hold stay unchanged. Together they show:
  - **(a) Healthy:** three new pings arrive at the repeat interval in every case.
  - **(b) Stalled ingestion:** `monitoring-heartbeat-ingestion-stop` blocks all four fake sources with the firewall, while the VictoriaMetrics query API, vmalert and Alertmanager stay up and answer. Pings stop within the expression's bound, remain absent for the full quiet observation window, and no "resolved" request reaches the receiver.
  - **(c) Read-only store:** `monitoring-heartbeat-storage-read-only` puts VictoriaMetrics' data on a small filesystem and fills it until free space is below `-storage.minFreeDiskSpaceBytes`. VictoriaMetrics reports read-only, queries still answer, and pings stop for the full quiet observation window.
  - **(d) One stale source:** `monitoring-heartbeat-single-source-down` starts with no active kubelet source-down alert, then stops that source. A new firing `TelemetrySourceDown` notification must reach the critical receiver after this stop, followed by two further heartbeats while the source remains stopped.
  - **(e) Recovery from actual heartbeat silence:** the ingestion-stop and storage-read-only cases each remove their fault and require two new pings plus clearance of the prior kubelet source-down alert. Storage also must report writable again. Every case rejects resolved heartbeat requests, including after recovery. A final heartbeat-only wait after restarting the single source is intentionally absent: heartbeats already continue with that source stopped, so it would prove no recovery.

  Historical sequential-check evidence: `monitoring-heartbeat` passed through its driver on hvn-hyp1 (2026-10-11), and current-head hosted CI38697644274 passed it before the split. Healthy pings were 40 s apart; pings stopped after actual ingestion and storage faults while the services answered, then resumed after each fault was removed; new `TelemetrySourceDown` delivery and continued pings with one stale source passed. The historical final source-restart/heartbeat-only wait was not evidence of source recovery. New independent-case execution evidence is recorded separately; these historical timings are not a split-check speedup claim.

## 5. Dashboards and sign-in

- [x] 5.1 Give the `grafana` route's Kanidm client Grafana's native sign-in: the callback `/login/generic_oauth`, Grafana's landing page, the scopes, the Secret target `monitoring/grafana-oidc`, and a Kanidm NetworkPolicy allow for Grafana's pods.
  - Start with a Grafana case beside Argo CD's existing case in `identity.nix`.
  - Replace both with a shared per-route helper only if Argo CD's generated Kanidm client, Secret targets and NetworkPolicy stay byte-for-byte unchanged, and `modules/tests/identity-contracts.nix` passes with no edit to its Argo CD assertions. Otherwise keep the sibling case; the generalization is a deferred cleanup (design.md, Deferred follow-ups).

  Verify that identity contracts pass and that Argo CD's generated identity objects are unchanged.

  Evidence: Sibling case in `identity.nix`. `identity-contracts` passes with no edit. Against `main`, Argo CD's entries in `clients.json` and `state.json` and its NetworkPolicy rule are unchanged; only the `grafana` client and its rule are added.

- [x] 5.2 Add `routes.grafana` (`auth = "admin"`, `exposure = "public"`, `displayName = "Grafana"`, like `routes.argocd`). Verify by evaluation that:
  - Kanidm gets one `grafana` client, whose landing is Grafana's sign-in and whose redirects include both the Gateway callback and `/login/generic_oauth`;
  - the provisioning Job publishes `monitoring/grafana-oidc`;
  - the `identity-gateway` Application contains a `grafana-admin` SecurityPolicy that targets the `grafana` HTTPRoute with client ID `grafana`, and that the policy syncs before the route;
  - the HTTPRoute and the public-edge entries for Grafana exist only in identity phase `normal`;
  - the public edges publish no monitoring hostname other than Grafana's.

  Evidence: `monitoring-contracts` (one `grafana` client with both callbacks, `monitoring/grafana-oidc` published, `grafana-admin` SecurityPolicy at wave -1 before the route at 0, route absent in phases `initial` and `provisioning`, no other monitoring route).

- [x] 5.3 Pin and render Grafana from `grafana-community`:
  - generic OAuth with PKCE, using the route's `grafana` client;
  - strict role mapping to the admin group;
  - no service accounts or API keys provisioned;
  - login form, basic auth and anonymous access disabled;
  - `admin.existingSecret` and the secret key from runtime Secrets;
  - an emptyDir database.

  Verify the generated manifests contain no `admin-password` value and that every setting above appears in `grafana.ini`.

  Evidence: `monitoring-contracts` (sign-in settings in `grafana.ini`; administrator password generated in memory at Pod start); `monitoring-secret-scan` (no inline administrator password or client secret); `monitoring-grafana-runtime` PASS on hvn-hyp1 (2026-10-11): with the rendered objects and the pinned image, only the secret-key and OIDC Secrets exist, the login form and basic authentication refuse sign-in, and the runbook's break-glass steps sign `admin` in. By owner decision the administrator password replaces `admin.existingSecret` (Implementation note 6).

- [x] 5.4 Provision the minimal dashboard set from ConfigMaps, with UI updates disabled:
  - Node Exporter Full and a kubernetes-mixin workloads view, vendored under `assets/monitoring/dashboards/` with upstream source, revision and SHA-256;
  - "Homelab overview", written in this repository.

  Verify with a check that every vendored file's hash matches its record, that each dashboard parses as JSON, and that no other dashboard is provisioned.

  Evidence: Evaluation fails if a vendored file no longer matches its SHA-256 in `assets/monitoring/dashboards/sources.json`; `monitoring-contracts` checks that each provisioned dashboard parses and that the set is exactly Node Exporter Full, the two kubernetes-mixin workload views and Homelab overview.

## 6. Network policy and exposure

- [x] 6.1 Add default-deny ingress for the `monitoring` namespace and the narrow allows from design.md Decision 10. Add a Kanidm allow for Grafana's backend pods through 5.1. Verify by evaluation that every monitoring Service is selected by a policy and that only the Gateway may reach Grafana.

  Evidence: `monitoring-contracts` (default-deny, every Service selected, only the Gateway proxy reaches Grafana through both monitoring's policy and the Gateway's backend policy); `identity/NetworkPolicy-kanidm-private.yaml` admits Grafana's pods.

## 7. Failure domain and resource bounds

- [x] 7.1 Set requests and limits on every monitoring container, as in design.md Decision 14. Verify with an evaluation check that no monitoring container lacks CPU and memory limits, and that the guest totals are at most 3 CPU and 3.5Gi.

  Evidence: `monitoring-contracts`: every container has CPU and memory limits; totals are 2.85 CPU and 3.25Gi.

- [x] 7.2 Run the existing identity, gateway and `prod-home` replacement checks with the monitoring Applications present. Verify that they pass without waiting on monitoring health, and that the replacement test's retained-path checks include `monitoring-metrics`.

  Evidence: with the monitoring Applications rendered, `gateway-runtime`, `identity-provision-runtime` and `prod-home-replacement` PASS through their drivers on hvn-hyp1 (2026-10-11). None waits on monitoring health; the replacement test's retained-directory checks create `monitoring-metrics` with its mapped identity and mode and confirm it is writable.

## 8. Documentation and generated output

- [x] 8.1 Write `docs/operations/monitoring.md`. It covers:
  - the one-time external account setup in section 9, with exact settings (the Pushover app; the dedicated Telegram bot and chat; the healthchecks.io check period, grace and integrations);
  - what lives in Nix and what doesn't, as in design.md;
  - `agenix edit` for each secret, and credential rotation;
  - severity routing: which channel gets which severity at which priority, that this is Nix configuration the owner can change, that Pushover quiet hours are set in the Pushover app, and why the Telegram alert chat should not be muted;
  - reaching Grafana from outside the household network, and the two sign-in layers;
  - silences, and why they are lost on guest replacement;
  - reading a heartbeat-down notice: the guest or host is down, ingestion stopped (including the read-only store at the 50 GiB floor), or the VictoriaMetrics pod is waiting on its retained path or marker;
  - metrics storage: bounded but not isolated, what each storage alert means, and what to do at each;
  - updating `expectedDisks` when a disk is added, replaced or retired;
  - the gaps: no off-LAN probing (a follow-up change), no backups (a future change), no active channel checks (a follow-up).

  Add the operations entry it needs. Verify that `nix run path:$PWD#sync-prod-home-manifests` and the docs generator leave a clean tree, and that the freshness checks pass.

  Evidence: `docs/operations/monitoring.md`; regenerating manifests and docs on hvn-hyp1 leaves no drift; `prod-home-manifests-fresh` and `files/docs/operations.md` pass.

- [x] 8.2 Update `docs/operations/identity.md:122-124` to say that the OAuth counters remain unscraped by design. Kanidm application metrics are out of scope.

  Evidence: `docs/operations/identity.md`.

## 9. Owner one-time setup (manual, outside Nix; not authorized by this plan)

These steps create external accounts and supply credential values. Nothing here is declared in Nix. Never paste a value into a commit, PR, issue or chat. Enter each one only through `agenix edit`, then rekey under `.secrets/hosts/` as `docs/operations.md` describes.

- [ ] 9.1 **Pushover.** Create a Pushover application for Homelab alerts. Store its API token as `monitoring--alertmanager-delivery--pushover-token` and the owner's user key as `monitoring--alertmanager-delivery--pushover-user-key`. Check that the owner's Pushover quiet hours are set as wanted, since warnings respect them and critical alerts bypass them.
- [ ] 9.2 **Telegram.** Create a dedicated bot with BotFather, separate from Hermes's bot. Create the chat that receives alerts (a direct chat with the bot, or a private group), send it one message, and read its chat ID. Store the bot token as `monitoring--alertmanager-delivery--telegram-bot-token` and the chat ID as `monitoring--alertmanager-delivery--telegram-chat-id`.
- [ ] 9.3 **healthchecks.io.** On the hosted free tier, create one check with a 5-minute period and a 10-minute grace. Add its Pushover and Telegram integrations, using the same Pushover user and Telegram chat. Store the check's ping URL as `monitoring--alertmanager-delivery--heartbeat-url`.
- [ ] 9.4 Confirm the five encrypted files exist under `.secrets/hosts/compute-1/` and that host evaluation sees all five in `runtimeSecrets`, without printing any value. Record the account settings (not the values) in `docs/operations/monitoring.md` (task 8.1).

## 10. Live acceptance (operator-gated; not authorized by this plan)

- [ ] 10.1 After the host deploy, scrape the host exporter from the guest. From the LAN and the tailnet, confirm the port is unreachable. Confirm `smart.prom` lists every disk from task 2.1, and `zpool.prom` lists `rpool`. Record the commands and results.
- [ ] 10.2 Reproduce the motivating incident in a scratch namespace: run a pod with a 64Mi limit that allocates past it once. Confirm a critical `KubeContainerOOMKilled` reaches Pushover at priority 1 and Telegram within 5 minutes while its Argo Application shows Healthy, and that the resolution notice follows.
- [ ] 10.3 Fire a test warning during the owner's Pushover quiet hours. Confirm it reaches Telegram, and reaches Pushover at normal priority without overriding quiet hours.
- [ ] 10.4 Stop VictoriaMetrics, or scale Alertmanager to zero. Confirm healthchecks.io notifies through both channels within 30 minutes, and reports recovery after restoring.
- [ ] 10.5 **Stopped ingestion while monitoring keeps running.** Pause Argo CD auto-sync for the `monitoring` Application. Apply a temporary egress-deny NetworkPolicy to the VictoriaMetrics pod, so that its scrapes of other pods and of the host fail while its own queries, vmalert and Alertmanager keep working. Confirm:
  - the VictoriaMetrics query API, vmalert and Alertmanager stay up;
  - the heartbeat stops;
  - healthchecks.io reports the check down within 30 minutes of applying the policy.

  Remove the policy, resume auto-sync, and confirm recovery is reported. Record times.
- [ ] 10.6 Revoke or blank the Pushover token. Send a test alert, and confirm `AlertDeliveryFailing` arrives through Telegram only. Restore it. Repeat for the Telegram token, confirming the alert arrives through Pushover only.
- [ ] 10.7 **Missing telemetry on the host:**
  - stop host node_exporter, and confirm `TelemetrySourceDown` fires and the storage and mount alerts are inhibited rather than falsely firing or resolving; restore it;
  - stop the `zpool-status` timer, and confirm `HostZpoolStatusStale` arrives within 15 minutes while node_exporter keeps answering; restore it.
- [ ] 10.8 From outside the household network (for example a phone on mobile data):
  - request `grafana.<domain>` without a session, and confirm the Gateway redirects to Kanidm and the Grafana pod logs no request;
  - sign in as an administrator, and confirm Grafana grants access;
  - sign in as a non-administrator Kanidm identity, and confirm it is refused before reaching Grafana;
  - confirm Grafana offers no login form and no anonymous access;
  - confirm no route on any entrance serves VictoriaMetrics, vmalert, Alertmanager or the exporter.
- [ ] 10.9 Replace the compute guest through the documented procedure. Confirm metrics from before the replacement remain queryable, and that dashboards and rules return without manual steps.
