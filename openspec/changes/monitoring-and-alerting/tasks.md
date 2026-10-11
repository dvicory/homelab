## 1. Contract checks and scaffolding

- [ ] 1.1 Add `modules/tests/monitoring-contracts.nix` with evaluation-only checks. It must fail when:
  - a non-monitoring Application declares sync wave ≥ 5;
  - any monitoring Application is below wave 5;
  - a route targets a monitoring Service other than Grafana, or the Grafana route is not `auth = "admin"`;
  - a declared route has no endpoint probe;
  - an image is not `tag@digest` or a chart has no version and hash;
  - the VictoriaMetrics volume is anything other than the static `local` PV on the `monitoring-metrics` retained path, or any monitoring volume uses `DirectoryOrCreate`.

  Verify with `nix build path:$PWD#checks.x86_64-linux.monitoring-contracts`, plus one deliberately failing fixture per rule.
- [ ] 1.2 Add the `kubernetes.services.monitoring` aspect group with two empty Applications: `monitoring-retained` (wave 5, `retained = true`) and `monitoring` (wave 6). Include it in `den.aspects.prod-home`. Verify that the `prod-home-gitops-source` check accepts the `monitoring` namespace in the AppProject destinations, and that 1.1 passes.

## 2. Host telemetry (hvn-hyp1)

- [ ] 2.1 **Read-only disk-ID inspection (operator; no changes to the host).** On `hvn-hyp1`, list `/dev/disk/by-id/` and `lsblk -o NAME,TYPE,TRAN,MODEL,WWN`. For each of the 9 physical disks (2 rpool NVMe, 7 HGST including the unused `sdc`, `sdf` and `sdg`), record its by-id path: `wwn-0x…` for SAS and SATA, and `nvme-eui.…` for NVMe. Confirm that the IDSDM (USB) and iDRAC virtual devices are absent from the list. Record no serial numbers. Put the result into `hvn-hyp1`'s `expectedDisks`, keyed by readable names, and the commands used into the PR.
- [ ] 2.2 Add the host telemetry aspect:
  - node_exporter with the systemd, filesystem, zfs and textfile collectors, bound to the compute bridge's host address from host data, with `MemoryMax`, `CPUQuota` and restart-on-failure;
  - the `expectedDisks` option, and the declared pool list derived from `zfs.rootPool.name`.

  Verify by evaluation that `hvn-hyp1`'s listen address equals the bridge address, that no wildcard bind exists, and that no unit is wanted by a target that activation waits on.
- [ ] 2.3 Add the `zpool-status` oneshot and its 2-minute timer. It writes `zpool.prom` atomically from `zpool status -j -p`, including `homelab_zpool_present{pool}`, and replaces the file only after a successful run. Verify with converter unit tests against recorded JSON for: an ONLINE pool, a DEGRADED pool, device errors, a scrub with errors, and a failing `zpool` command. The last must leave the previous file and its modification time untouched.
- [ ] 2.4 Add the `smart-status` oneshot and its 15-minute timer. It runs `smartctl --json -a` on each declared by-id path and writes `smart.prom` atomically: health status, SCSI grown defects, ATA pending and reallocated sectors, and `homelab_smart_device_up{disk,id}`. The unit has only the device access it needs. Verify with converter unit tests against recorded `smartctl --json` output for:
  - a healthy SAS drive, a healthy SATA drive and a healthy NVMe drive;
  - a drive reporting FAILED, and a SAS drive whose grown-defect count rose;
  - a declared disk that cannot be opened, which must produce `homelab_smart_device_up 0` while the other disks are still written;
  - a run in which `smartctl` itself fails, which must leave the previous file untouched.
- [ ] 2.5 Make the aspect emit `prometheus-targets` entries. Add the host consumer aspect, which:
  - renders one nftables input rule admitting only the guest address on the compute interface to the exporter port;
  - exposes, as read-only options, the resolved target list, the required-mount list, the declared pools and the declared disks.

  The mount list is the mergerfs pool mountpoints, plus provisioned `disk.luks-storage` mountpoints, plus an `extraRequiredMounts` list that is empty today. Verify by evaluation that:
  - the targets and rule text are what `hvn-hyp1`'s data implies, and the rule names no other source or interface;
  - the mount list is exactly `/srv/media/data` and `/mnt/storage-clear/media4`, with no legacy gocryptfs mount (media1–3);
  - the disk list matches task 2.1, and the pool list is `rpool`.
- [ ] 2.6 Extend an existing host VM test, or add a small one, to show that:
  - activation succeeds while the bridge does not exist yet, and the exporter starts once it does;
  - a client on another interface cannot connect to the exporter port, while the guest address can;
  - stopping the `zpool-status` timer leaves `node_textfile_mtime_seconds` for `zpool.prom` unchanged while node_exporter keeps answering.

## 3. Cluster collection core

- [ ] 3.1 Pin and render VictoriaMetrics single-node:
  - retained path `monitoring-metrics`, with the VictoriaMetrics UID and GID and mode `0700`;
  - a static `local` PV and PVC pinned to the compute instance, in `monitoring-retained`;
  - a read-only hostPath mount of the state-root marker with `type: File`;
  - `-retentionPeriod=90d` and `-storage.minFreeDiskSpaceBytes=50GiB`;
  - the resource limits from design.md.

  Verify the generated manifests show the retained `guestPath`, the marker mount, the flags, the limits, and no chart test or hook objects.
- [ ] 3.2 Render the scrape config from:
  - (a) the host's `scrapeTargets` option, read from `nixosConfigurations.${cluster.hostName}`;
  - (b) kubelet and cAdvisor through the node;
  - (c) the Argo CD controller metrics Service;
  - (d) cert-manager;
  - (e) kube-state-metrics;
  - (f) blackbox probe targets derived from `cluster.routes`;
  - (g) monitoring self-scrape.

  Verify with an evaluation check that compares the rendered jobs to the expected set for `prod-home`.
- [ ] 3.3 Pin and render kube-state-metrics, with resources excluding `secrets` and `configmaps` and no label or annotation allowlists. Verify the generated Deployment arguments, that its RBAC is read-only, and that `kube_pod_status_phase`, `kube_pod_status_reason` and `kube_job_status_condition` are among the enabled metrics.
- [ ] 3.4 Pin and render the blackbox exporter with two modules: `native` (2xx on a health path) and `admin` (302 to the identity hostname). Probes go to the gateway NodePort, with SNI and `Host` set per route. Verify the generated probe list covers every route in `cluster.routes`.
- [ ] 3.5 Set `controller.metrics.enabled = true` and the `ComparisonError` application-condition metric in `argocd.nix`. Verify the generated metrics Service exists and that the existing NetworkPolicy still admits it.

## 4. Alert rules, routing and secrets

- [ ] 4.1 Write the rule files from design.md Decisions 5, 8 and 12 as Nix-rendered Prometheus YAML. Render one rule per declared pool, per declared disk and per required mount from the host's options. Add `vmalert-tool unittest` (or `promtool test rules`) cases:
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
- [ ] 4.2 Render vmalert and the Alertmanager config: severity routes, the Watchdog heartbeat route, cross-channel `AlertDeliveryFailing` routes, inhibition rules, grouping, `send_resolved`, and file-based credential fields. Verify with `amtool check-config` and `amtool config routes test` in a flake check.
  - The tests pin the current routing from design.md Decision 6. They also assert the spec floor: every critical alert reaches both channels, at a Pushover priority of at least 1 so quiet hours do not hold it; every warning reaches at least one channel; resolutions are sent. A later routing change in Nix updates the first set and must still pass the second.
  - They cover:
    - critical → Pushover at priority 1 and Telegram;
    - warning → Pushover at priority 0 and Telegram;
    - Watchdog → heartbeat only, with `send_resolved: false` on the heartbeat receiver;
    - Pushover failure → Telegram only, and Telegram failure → Pushover only (priority 1);
    - the inhibitions in Decision 6, including a down host node_exporter suppressing the stale-file and missing-item alerts.
  - Also settle whether the pinned Alertmanager reads Telegram `chat_id` from a file, or needs the init-container fallback in design.md Decision 6.
- [ ] 4.3 Declare the five delivery runtime secrets and the two Grafana generator secrets in `compute-resources.runtimeSecrets`. Mount the delivery Secret with `optional: true`. Verify by evaluation that the host's `runtimeSecrets` contains them. Verify with a container-level test that the pinned Alertmanager starts without the files and records a failed notification, rather than crashing or using a placeholder.
- [ ] 4.4 Add a check that the generated manifests, `docs/operations.md` and the rendered Alertmanager and Grafana configs contain only secret paths and references. They must contain no credential field with an inline value and no `hc-ping.com/<uuid>` pattern. Verify the check fails on a planted inline value.
- [ ] 4.5 **Heartbeat VM test with a fake receiver.** Add a NixOS VM test (`modules/tests/monitoring-heartbeat.nix`) that runs the pinned VictoriaMetrics single, vmalert and Alertmanager with the rendered Watchdog rule and heartbeat route. Two parts are faked:
  - small HTTP servers that serve fixed metrics under the four core-source job names;
  - a fake heartbeat receiver that records every request and its body.

  The test may shorten scrape, evaluation and repeat intervals through test-only overrides, but must use the rendered expression and receiver unchanged. It shows:
  - **(a) Healthy:** pings arrive at the repeat interval.
  - **(b) Stalled ingestion:** block all four fake sources with the firewall, while the VictoriaMetrics query API, vmalert and Alertmanager stay up and answer. Pings stop within the expression's bound, and no "resolved" request reaches the receiver.
  - **(c) Read-only store:** put VictoriaMetrics' data on a small filesystem and fill it until free space is below `-storage.minFreeDiskSpaceBytes`. VictoriaMetrics reports read-only, queries still answer, and pings stop.
  - **(d) One stale source:** stop one fake source. Pings continue, and a second fake receiver on the critical route gets `TelemetrySourceDown`.
  - **(e) Recovery:** restore the sources, and pings resume.

## 5. Dashboards and sign-in

- [ ] 5.1 Give the `grafana` route's Kanidm client Grafana's native sign-in: the callback `/login/generic_oauth`, Grafana's landing page, the scopes, the Secret target `monitoring/grafana-oidc`, and a Kanidm NetworkPolicy allow for Grafana's pods.
  - Start with a Grafana case beside Argo CD's existing case in `identity.nix`.
  - Replace both with a shared per-route helper only if Argo CD's generated Kanidm client, Secret targets and NetworkPolicy stay byte-for-byte unchanged, and `modules/tests/identity-contracts.nix` passes with no edit to its Argo CD assertions. Otherwise keep the sibling case; the generalization is a deferred cleanup (design.md, Deferred follow-ups).

  Verify that identity contracts pass and that Argo CD's generated identity objects are unchanged.
- [ ] 5.2 Add `routes.grafana` (`auth = "admin"`, `exposure = "public"`, `displayName = "Grafana"`, like `routes.argocd`). Verify by evaluation that:
  - Kanidm gets one `grafana` client, whose landing is Grafana's sign-in and whose redirects include both the Gateway callback and `/login/generic_oauth`;
  - the provisioning Job publishes `monitoring/grafana-oidc`;
  - the `identity-gateway` Application contains a `grafana-admin` SecurityPolicy that targets the `grafana` HTTPRoute with client ID `grafana`, and that the policy syncs before the route;
  - the HTTPRoute and the public-edge entries for Grafana exist only in identity phase `normal`;
  - the public edges publish no monitoring hostname other than Grafana's.
- [ ] 5.3 Pin and render Grafana from `grafana-community`:
  - generic OAuth with PKCE, using the route's `grafana` client;
  - strict role mapping to the admin group;
  - no service accounts or API keys provisioned;
  - login form, basic auth and anonymous access disabled;
  - `admin.existingSecret` and the secret key from runtime Secrets;
  - an emptyDir database.

  Verify the generated manifests contain no `admin-password` value and that every setting above appears in `grafana.ini`.
- [ ] 5.4 Provision the minimal dashboard set from ConfigMaps, with UI updates disabled:
  - Node Exporter Full and a kubernetes-mixin workloads view, vendored under `assets/monitoring/dashboards/` with upstream source, revision and SHA-256;
  - "Homelab overview", written in this repository.

  Verify with a check that every vendored file's hash matches its record, that each dashboard parses as JSON, and that no other dashboard is provisioned.

## 6. Network policy and exposure

- [ ] 6.1 Add default-deny ingress for the `monitoring` namespace and the narrow allows from design.md Decision 10. Add a Kanidm allow for Grafana's backend pods through 5.1. Verify by evaluation that every monitoring Service is selected by a policy and that only the Gateway may reach Grafana.

## 7. Failure domain and resource bounds

- [ ] 7.1 Set requests and limits on every monitoring container, as in design.md Decision 14. Verify with an evaluation check that no monitoring container lacks CPU and memory limits, and that the guest totals are at most 3 CPU and 3.5Gi.
- [ ] 7.2 Run the existing identity, gateway and `prod-home` replacement checks with the monitoring Applications present. Verify that they pass without waiting on monitoring health, and that the replacement test's retained-path checks include `monitoring-metrics`.

## 8. Documentation and generated output

- [ ] 8.1 Write `docs/operations/monitoring.md`. It covers:
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
- [ ] 8.2 Update `docs/operations/identity.md:122-124` to say that the OAuth counters remain unscraped by design. Kanidm application metrics are out of scope.

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
