## Evidence scope

Receipts below are historical and remain scoped to their named source and parent.
They do not establish readiness of the approved SMART event/password simplification.
Unaffected checked source items retain that historical status; affected items are
reopened until exact-source proof exists. All live acceptance remains separate.

- Published source `8ae433e305ae69367053d4d487ecb5fb25846428` had normal CI
  [39240104596](https://github.com/dvicory/homelab/actions/runs/39240104596).
- Engineering source `573ba88300d9d8eba102bbd4a9051cb8b0eb9206` passed normal full
  CI [40760820350](https://github.com/dvicory/homelab/actions/runs/40760820350):
  53 successful jobs and the expected main-helper publisher skip. Its strict
  consumer accepted three inventories, 49 execution receipts and independent
  artifact declarations; the native API consumer accepted all 28 scenarios.
  The earlier failed `972cee0b` run remains evidence, not a waiver.
- Native rules at `0cfa756d7f52d27dd802302f97e4a067d0f85ced` passed 30 primary
  cases and three staged pairs, including the then-selected retained-growth
  policy. That result does not prove the replacement new-error semantics.
- The operator supplied the five encrypted delivery sources and matching host
  rekeys on 2026-10-28 (original change `ccbc811bc9ba127c5c406c5b00a119f36639a38c`).
  No agent decrypted or tested their values. Ciphertext presence does not prove
  provider settings, actual delivery, or readiness of the new Grafana password.

Current integration uses accepted main `46279610a1b1522461cf245966f35e22b3a3fc8f`.
The operator has confirmed automatic non-USB physical-disk coverage, SMART
new-error warnings without resolved notices, and a generated agenix-managed
Grafana password. Fresh generation/rekey inventory, canonical output, native
consumers, full exact-source CI and candidate qualification remain integration
gates. Production staging/activation, merge, real device/controller access,
provider delivery and every live drill are separately gated. Disposable
runtime/browser proof is not production access or persistence proof.

After K3s restarts, the inherited NetworkPolicy fixture waits for the existing
Gateway and stranger clients to execute `true` through the live kubelet/CRI path.
Cached Node Ready alone does not establish that path. This test-readiness barrier
does not send or retry network probes, restart watchers, change observation
windows or weaken refusal assertions; it is not a policy-controller repair.

## 1. Contract checks and integration

- [ ] 1.1 Retain meaningful native rendered-contract checks in `modules/tests/monitoring-contracts.nix`: fail-closed retained storage, required telemetry coverage, bounded resources, dashboard parsing and declared sign-in restrictions. Reuse native GitOps policies for route/wave publication instead of duplicate monitoring predicates. Remove derivation-name/hash-shape, exact current mount/dashboard inventories and editorial wording pins; keep actual source/hash enforcement and manifest freshness.

  Verify the integrated `monitoring-contracts` check and its native policy owners once source is stable. Historical `monitoring-contracts` proof covered the former representation; it does not establish the simplified check's coverage.

- [x] 1.2 Add the `kubernetes.services.monitoring` aspect group with retained storage at wave 5 and workloads at wave 6. Include it in `den.aspects.prod-home`. The protected Namespace is contributed to `identity-retained` at wave -2. Current verification uses the native GitOps Kyverno policies, including AppProject destinations, plus `monitoring-contracts`.

  Evidence: `generated/manifests/prod-home/apps/Application-monitoring.yaml` (wave 6) and `Application-monitoring-retained.yaml` (wave 5); `monitoring` is in the AppProject destinations; `prod-home-gitops-source` and `monitoring-contracts` pass.

## 2. Host telemetry (hvn-hyp1)

- [x] 2.1 **Disk policy confirmed by the operator.** Automatically monitor OS-exposed non-USB physical disks, including newly attached disks and spares, without per-disk configuration. Keep the nine existing named aliases as independent required-presence expectations. Exclude USB, virtual and synthetic discovery, and expose no raw serial numbers.

  The owner selected non-USB physical coverage on 2026-10-31. Passive OS/sysfs metadata confirms the existing aliases and distinguishes USB IDSDM and optical/iDRAC media; no SMART read was used. This policy decision is not activation, device-probe or provider-delivery permission.

- [x] 2.2 Add the host telemetry aspect:
  - node_exporter with the systemd, filesystem, zfs and textfile collectors, bound to the compute bridge's host address from host data, with `MemoryMax`, `CPUQuota` and restart-on-failure;
  - automatic non-USB physical-disk discovery, the `expectedDisks` required-alias floor, and the declared pool list derived from `zfs.rootPool.name`.

  Verify by evaluation that `hvn-hyp1`'s listen address equals the bridge address, that no wildcard bind exists, and that no unit is wanted by a target that activation waits on.

  Evidence: `monitoring-contracts` (socket bound to the bridge address from host data, no unit wanted by an activation target); `host-telemetry-runtime` VM test (MemoryMax and CPUQuota on every unit; activation with no bridge).

- [x] 2.3 Add the `zpool-status` oneshot and its 2-minute timer. It writes `zpool.prom` atomically from `zpool status -j -p`, including `homelab_zpool_present{pool}`, and replaces the file only after a successful run. Verify with converter unit tests against recorded JSON for: an ONLINE pool, a DEGRADED pool, device errors, a scrub with errors, and a failing `zpool` command. The last must leave the previous file and its modification time untouched.

  Evidence: `host-telemetry-converters` covers ONLINE, DEGRADED, device errors, scrub errors and a failing `zpool` (previous file and mtime kept; invalid JSON too). A read-only run against the live `rpool` produced the expected series (Implementation note 5).

- [ ] 2.4 Add the `smart-status` oneshot and its 15-minute timer. Native OS metadata discovers non-USB physical disks; the existing pinned smartctl reads the deduplicated required/discovered set and writes `smart.prom` atomically. Keep current/future block-device access read-only and preserve health/counter/device-up metrics. Converter fixtures must exercise:
  - a healthy SAS drive, a healthy SATA drive and a healthy NVMe drive;
  - a drive reporting FAILED, and a SAS drive whose grown-defect count rose;
  - a declared disk that cannot be opened, which must produce `homelab_smart_device_up 0` while the other disks are still written;
  - a run in which `smartctl` itself fails, which must leave the previous file untouched;
  - a new unconfigured disk, USB and synthetic exclusions, deduplication against a required alias, and private NVMe topology labels;
  - a required disk missing from discovery, an unread extra disk without hiding siblings, and discovery/identity failure preserving the previous file and mtime;
  - overall passed:true with SMART statuses 16, 32 and 48, distinguishing current prefailure from historical-only threshold crossings;
  - otherwise accepted NVMe JSON with omitted warning/media-error fields versus explicit zero fields: omission emits no healthy zero sample, while actual zero remains available.

  Evidence: `host-telemetry-converters` covers healthy SAS, SATA and NVMe, a FAILED drive, rising grown defects, an unopenable disk (`homelab_smart_device_up 0`, others still written) and a failing `smartctl` (previous file kept). The fixtures are synthetic; recording real output needs root (Implementation note 5).

  Reopened for the omitted-NVMe-field regression. The owner must exercise that regression and the integrated converter check; the historical synthetic fixtures are not proof of the corrected behavior.

- [x] 2.5 Make the aspect emit `prometheus-targets` entries. Add the host consumer aspect, which:
  - renders one nftables input rule admitting only the guest address on the compute interface to the exporter port;
  - exposes, as read-only options, the resolved target list, the required-mount list, the declared pools and the declared disks.

  The mount list is the mergerfs pool mountpoints, plus provisioned `disk.luks-storage` mountpoints, plus an `extraRequiredMounts` list that is empty today. Verify by evaluation that:
  - the targets and rule text are what `hvn-hyp1`'s data implies, and the rule names no other source or interface;
  - required mounts follow the declared mergerfs and provisioned encrypted-disk mountpoints, excluding undeclared legacy gocryptfs mounts rather than pinning today's exact path inventory;
  - the required-alias floor matches task 2.1 independently of discovery, and the pool list is `rpool`.

  Evidence: existing native checks cover the guest-only firewall and required mounts. The nine required aliases retain independent absence rules; the same `HostDiskTelemetryMissing` family also covers unread discovered extras without duplicate required identities. The rule-engine fixture exercises the extra disk before/after the 20-minute bound and recovery.

- [x] 2.6 Extend an existing host VM test, or add a small one, to show that:
  - activation succeeds while the bridge does not exist yet, and the exporter starts once it does;
  - a client on another interface cannot connect to the exporter port, while the guest address can;
  - stopping the `zpool-status` timer leaves `node_textfile_mtime_seconds` for `zpool.prom` unchanged while node_exporter keeps answering.

  Evidence: `host-telemetry-runtime` PASS through its driver on hvn-hyp1: activation exits 0 with no bridge and no failed units; the guest scrapes once the bridge exists; another source on the bridge and a LAN client are refused; with the timer stopped, the `zpool.prom` mtime held for 150 s while node_exporter answered.

## 3. Cluster collection core

- [ ] 3.1 Pin and render VictoriaMetrics single-node through the already-used app-template 5.1.0, replacing the local workload renderer while preserving:
  - retained path `monitoring-metrics`, with the VictoriaMetrics UID and GID and mode `0700`;
  - a static `local` PV and PVC pinned to the compute instance, in `monitoring-retained`;
  - a read-only hostPath mount of the state-root marker with `type: File`;
  - `-retentionPeriod=90d` and `-storage.minFreeDiskSpaceBytes=50GiB`;
  - the resource limits from design.md;
  - names and policy peer labels, Recreate strategy, UID/GID, probes, service-account token/RBAC restrictions and rollout on configuration changes.

  Verify the generated manifests show the retained `guestPath`, the marker mount, the flags, the limits, and no chart test or hook objects.

  Evidence: `Deployment-victoriametrics.yaml` (flags, limits, marker hostPath `type: File`), `PersistentVolume-monitoring-metrics.yaml` (`local.path: /srv/state/monitoring-metrics`), no Helm hook or test objects under `generated/manifests/prod-home/monitoring/`; `monitoring-contracts` checks the storage rules.

  Reopened for app-template cutover. Historical plain-object manifests are not proof of the replacement workload's behavior; require canonical output and the existing storage/runtime-boundary checks at the integrated source.

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

- [x] 3.3 Pin and render kube-state-metrics, with resources excluding `secrets` and `configmaps` and no label or annotation allowlists. Verify the generated Deployment arguments, that its RBAC is read-only, and that `kube_pod_status_phase`, `kube_pod_status_reason`, `kube_job_failed` and `kube_job_complete` are among the enabled metrics.

  Evidence: `Deployment-kube-state-metrics.yaml` (`--resources` without secrets or configmaps, no allowlists); `monitoring-contracts` (read-only RBAC). Job conditions are `kube_job_failed` and `kube_job_complete` in 2.20 (Implementation note 3).

- [x] 3.4 Pin and render the blackbox exporter with two modules: `native` (2xx on a health path) and `admin` (302 to the identity hostname). Probes go to the gateway NodePort, with SNI and `Host` set per route. Verify the generated probe list covers every route in `cluster.routes`.

  Evidence: `monitoring-contracts` fails if a declared route has no probe; `ConfigMap-blackbox.yaml` has one module per route.

- [x] 3.5 Set `controller.metrics.enabled = true` and the `ComparisonError` application-condition metric in `argocd.nix`. Verify the generated metrics Service exists and that the existing NetworkPolicy still admits it.

  Evidence: `argocd/Service-argocd-application-controller-metrics.yaml`; the existing `NetworkPolicy-argocd-application-controller.yaml` admits the `metrics` port from every namespace.

## 4. Alert rules, routing and secrets

- [ ] 4.1 Write the rule files from design.md Decisions 5, 8 and 12 as Nix-rendered Prometheus YAML. Keep independent rules for declared pools, required disk aliases and required mounts; generic SMART faults and unread discovered disks do not require another inventory entry. Add `vmalert-tool unittest` (or `promtool test rules`) cases:
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
    - free space below 10% fires a warning, and below 5% a critical;
    - each supported SMART counter-growth signal fires `HostDiskSmartErrorsIncreasing` at warning severity after an observed increase, then ends as an event when growth leaves the window, without a retained growth incident or two-physical-run recovery requirement;
    - negative/sentinel, missing and invalid observations do not manufacture a new-error baseline or healthy condition recovery.
  - **Missing telemetry:**
    - a missing host source fires `TelemetrySourceDown`, while the native engine's own firing storage `ALERTS` renew through more than two hours of missing input; only explicit matching recovery clears each object/severity/signal, and later absence cannot resurrect it;
    - ongoing `HostDiskSmartFailing` health/NVMe-critical-warning conditions retain matching signal-specific recovery: stale replay, a fresh sibling disk, an unread device, an absent NVMe field and negative/sentinel values cannot clear them; only fresh successful matching healthy evidence can;
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

  Historical rule evidence: `monitoring-rules` at `0cfa756d` passed 30 primary cases and three staged production rule/test pairs with vmalert-tool 1.151.0, including extended outage, sparse-sibling, coherent-ratio, three-day scrub and no-resurrection cases. Its retained counter-growth/sentinel assertions belong to the superseded incident policy. Reopened acceptance requires the new event cases and preserved actual-condition recovery cases, judged by engine state rather than exact summary text. Exact-source full CI remains separate.

  Metric-name evidence: historical heartbeat checks confirm `vm_rows_added_to_storage_total`, `vm_free_disk_space_bytes` and `vm_data_size_bytes`; `host-telemetry-runtime` confirms `node_time_seconds` and filesystem/systemd series; `monitoring-k3s-runtime` confirms `kubelet_running_pods`, `machine_cpu_cores` and `container_oom_events_total`. These runtime results retain their historical source scope, not final-head CI acceptance. For the remaining name, the rendered kube-state-metrics Deployment pins chart 8.6.0 and image `v2.20.0@sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b`, enables `nodes`, and sets no metric allow/deny filter. Its upstream release commit `4ffeda2ef866b0fef372849825a803296483b336` registers `createNodeInfoFamilyGenerator` in the node family and defines `kube_node_info` as a stable gauge with value 1 ([registration](https://github.com/kubernetes/kube-state-metrics/blob/4ffeda2ef866b0fef372849825a803296483b336/internal/store/node.go#L45-L60), [definition](https://github.com/kubernetes/kube-state-metrics/blob/4ffeda2ef866b0fef372849825a803296483b336/internal/store/node.go#L133-L181), [metric documentation](https://github.com/kubernetes/kube-state-metrics/blob/4ffeda2ef866b0fef372849825a803296483b336/docs/metrics/cluster/node-metrics.md#L6)). This confirms the pinned metric name, not a new live scrape or deployment.

  Read-only counter behavior: pinned VictoriaMetrics 1.151.0 [rejects `WriteRows` before `Storage.AddRows` when read-only](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.151.0/app/vmstorage/vmstorage.go#L125-L139); [the added-row counter increases only by rows actually added](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/v1.151.0/lib/storage/storage.go#L1670-L1693). Rejected writes therefore do not advance `vm_rows_added_to_storage_total`; already admitted work may finish during the transition. Historical read-only-store proof observes write refusal, stopped heartbeat, responsive queries and recovery after restoring space; the full final-head runtime checks still run through ordinary CI.

- [ ] 4.2 Render vmalert and Alertmanager through the existing app-template, preserving names, labels, Recreate strategy, identities, resources, probes, token restrictions and configuration rollouts. Render severity routes, the SMART event route, Watchdog heartbeat route, cross-channel failure routes, inhibitions, grouping, resolved flags and native file credentials. Verify with `amtool check-config` and `amtool config routes test`.
  - Ordinary critical alerts reach both channels at Pushover priority 1; ordinary warnings reach at least one channel. Condition receivers send resolutions. `HostDiskSmartErrorsIncreasing` uses `warning-events` with ordinary warning channels/priority but `send_resolved: false` on both integrations. No other condition inherits that event exception.
  - They cover:
    - critical → Pushover at priority 1 and Telegram;
    - warning → Pushover at priority 0 and Telegram;
    - `HostDiskSmartErrorsIncreasing` → `warning-events`, Pushover priority 0 and Telegram, without resolved/recovered delivery;
    - Watchdog → heartbeat only, with `send_resolved: false` on the heartbeat receiver;
    - Pushover failure → Telegram only, and Telegram failure → Pushover only (priority 1);
    - the inhibitions in Decision 6, including a down host node_exporter suppressing the stale-file and missing-item alerts.
  - Use pinned Alertmanager's native Telegram `chat_id_file`; no chat-ID init-container fallback remains.

  Historical `monitoring-alertmanager` proof passed native config/routes and the then-current delivery floor, including `chat_id_file`. Reopened acceptance must exercise the event route and resolved-flag distinction while retaining ordinary condition, heartbeat and failed-channel behavior.

- [ ] 4.3 Declare the five delivery runtime secrets plus Grafana's generated secret key and administrator password in `compute-resources.runtimeSecrets`. Generate `monitoring--grafana-admin--admin-password` with the existing `alnum-no-newline` flow; target `monitoring/grafana-admin`, key `admin-password`. Establish the generated encrypted source, matching host rekey readiness and evaluated runtime inventory without exposing any value. Remove Pod-memory-only password generation. Keep delivery Secret mounts optional and native file credentials.

  Verify integrated runtime inventory and generated documentation; prove Grafana initializes from the managed Secret/file path with normal authentication refusals and deliberate private emergency access (5.3). Preserve the container-level missing-delivery-file check: Alertmanager runs and records notification failure, never a placeholder. Five provider sources/rekeys historically exist, but that does not establish the new password's readiness, running Grafana initialization, provider settings or delivery.

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
  - **(e) Recovery from actual heartbeat silence:** the ingestion-stop case observes a real firing critical kubelet `TelemetrySourceDown` before removing its source-blocking fault, then requires two new pings and clearance of that observed alert. The storage-read-only case removes its storage fault and requires writable storage, two new pings and a newly ingested core-source sample timestamped after restoration; its sources stay healthy, so it makes no source-alert clearance claim. Every case rejects resolved heartbeat requests, including after recovery. A final heartbeat-only wait after restarting the single source is intentionally absent: heartbeats already continue with that source stopped, so it would prove no recovery.

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

Historical evidence: one Grafana client, both callbacks, Secret publication and ordered route/policy. Current normal-phase publication is owned by the native `administrator-publication-atomic` policy over the actual `identity-gateway` population; exact Grafana route/backend/path/timeout and nonempty intended backend ingress are covered by native Kyverno positives and semantic negatives, not duplicate monitoring predicates.

- [ ] 5.3 Pin and render Grafana from `grafana-community`:
  - generic OAuth with PKCE, using the route's `grafana` client;
  - provider-local `auth.generic_oauth.auto_login`, including the matching override for private emergency use, with deprecated global auto-login removed;
  - strict role mapping to the admin group;
  - no service accounts or API keys provisioned;
  - login form, basic auth and anonymous access disabled;
  - `admin.existingSecret` and native file reads for the generated managed administrator password and secret key from `monitoring/grafana-admin`, without a password-generation init container;
  - an emptyDir database.

  Verify generated manifests contain references, never an `admin-password` value, and that the sign-in settings appear in `grafana.ini`. Exercise the pinned Grafana image with a synthetic managed Secret: password-backed database initialization, normal login-form/basic/anonymous refusal, strict OAuth role configuration and the private emergency procedure must all remain meaningful checks.

  Historical `monitoring-grafana-runtime` passed normal refusal and break-glass with the former Pod-generated password on 2026-10-11. That result is not acceptance of managed-password initialization or provider-local auto-login; the task is reopened until the updated runtime check and integrated contracts/secret scan are exercised. Actual OIDC/UI and outside-household access stay in live acceptance.

- [ ] 5.4 Provision the minimal dashboard set from ConfigMaps, with UI updates disabled:
  - Node Exporter Full and a kubernetes-mixin workloads view, vendored under `assets/monitoring/dashboards/` with upstream source, revision and SHA-256;
  - "Homelab overview", written in this repository.

  Verify source hashes for vendored assets, parse every provisioned dashboard as JSON and retain actual file provisioning/read-only behavior. Do not pin the exact current dashboard inventory or chart representation.

  Historical evaluation enforced vendored hashes through `assets/monitoring/dashboards/sources.json`. Reopened acceptance preserves that source enforcement and provisioning checks while removing the exact-set representation pin.

## 6. Network policy and exposure

- [ ] 6.1 Keep monitoring default-deny ingress and the intended allows from design.md Decision 10. Keep the Kanidm allow from 5.1. Remove only Grafana's duplicate handwritten ingress policy; canonical Gateway backend policy remains. Verify the effective union of every policy selecting Grafana permits the intended Gateway peer and refuses unrelated namespace/pod peers; do not equate one policy's ports with the union.

  Historical checks observed both redundant allows and the Kanidm rule. They do not establish the simplified policy union. Require the updated native policy positives/semantic negatives and existing real ingress-refusal coverage; no blanket removal of the separate K3s egress VM check without exercised equivalent proof.

## 7. Failure domain and resource bounds

- [x] 7.1 Set requests and limits on every monitoring container, as in design.md Decision 14. Verify with an evaluation check that no monitoring container lacks CPU and memory limits, and that the guest totals are at most 3 CPU and 3.5Gi.

  Evidence: `monitoring-contracts`: every container has CPU and memory limits; totals are 2.85 CPU and 3.25Gi.

- [x] 7.2 Run the existing identity and `prod-home` replacement checks with monitoring present. Current Gateway verification is the complete `verify-kubernetes-api` suite, not the retired `gateway-runtime`. Preserve all 28 native scenarios and the replacement check's retained metrics path identity/writability checks without waiting on monitoring health.

  Evidence: with the monitoring Applications rendered, `gateway-runtime`, `identity-provision-runtime` and `prod-home-replacement` PASS through their drivers on hvn-hyp1 (2026-10-11). None waits on monitoring health; the replacement test's retained-directory checks create `monitoring-metrics` with its mapped identity and mode and confirm it is writable.

## 8. Documentation and generated output

- [ ] 8.1 Maintain `docs/operations/monitoring.md` as ongoing operator guidance, deriving concrete configuration facts through the existing generated-doc pattern rather than parsing Nix or committed YAML. It covers:
  - the one-time external account setup in section 9, with exact settings (the Pushover app; the dedicated Telegram bot and chat; the healthchecks.io check period, grace and integrations);
  - what lives in Nix and what doesn't, as in design.md;
  - external credential editing and rotation, generated Grafana password/key generation and rekey, and the distinction between ciphertext, running database initialization and private emergency access;
  - severity routing and the narrow SMART new-error/no-resolved exception, ordinary condition recovery, quiet hours and why the Telegram chat should not be muted;
  - reaching Grafana from outside the household network, and the two sign-in layers;
  - silences, and why they are lost on guest replacement;
  - reading a heartbeat-down notice: the guest or host is down, ingestion stopped (including the read-only store at the 50 GiB floor), or the VictoriaMetrics pod is waiting on its retained path or marker;
  - metrics storage: bounded but not isolated, what each storage alert means, and what to do at each;
  - automatic non-USB physical-disk discovery, and maintaining `expectedDisks` only when changing the independently required alias floor;
  - the gaps: no off-LAN probing (a follow-up change), no backups (a future change), no active channel checks (a follow-up);
  - private emergency access and cleanup with normal central-admin authentication restored, plus meaningful host-first/monitor-first mount rollout ordering.

  Add the operations entry it needs. Verify that `nix run path:$PWD#sync-prod-home-manifests` and the docs generator leave a clean tree, and that the freshness checks pass.

  Historical generated manifests/docs passed freshness checks. Reopened acceptance requires the simplified runbook and final generation through the canonical owners once integrated source is stable; remove CI commands, active-branch status and agent authorization narration from ongoing operator guidance.

- [x] 8.2 Update `docs/operations/identity.md:122-124` to say that the OAuth counters remain unscraped by design. Kanidm application metrics are out of scope.

  Evidence: `docs/operations/identity.md`.

## 9. Owner one-time setup (manual, outside Nix; not authorized by this plan)

These steps create external accounts and supply credential values. Nothing here is declared in Nix. Never paste a value into a commit, PR, issue or chat. Enter each one only through `agenix edit`, then rekey under `.secrets/hosts/` as `docs/operations.md` describes.

- [ ] 9.1 **Pushover.** Create a Pushover application for Homelab alerts. Store its API token as `monitoring--alertmanager-delivery--pushover-token` and the owner's user key as `monitoring--alertmanager-delivery--pushover-user-key`. Check that the owner's Pushover quiet hours are set as wanted, since warnings respect them and critical alerts bypass them.
- [ ] 9.2 **Telegram.** Create a dedicated bot with BotFather, separate from Hermes's bot. Create the chat that receives alerts (a direct chat with the bot, or a private group), send it one message, and read its chat ID. Store the bot token as `monitoring--alertmanager-delivery--telegram-bot-token` and the chat ID as `monitoring--alertmanager-delivery--telegram-chat-id`.
- [ ] 9.3 **healthchecks.io.** On the hosted free tier, create one check with a 5-minute period and a 10-minute grace. Add its Pushover and Telegram integrations, using the same Pushover user and Telegram chat. Store the check's ping URL as `monitoring--alertmanager-delivery--heartbeat-url`.
- [x] 9.4 Confirm the five encrypted files exist under `.secrets/hosts/compute-1/` and that host evaluation sees all five in `runtimeSecrets`, without printing any value. Record the intended account settings (not the values) in `docs/operations/monitoring.md` (task 8.1).

  Completed 2026-10-28: operator-authored sources and matching host rekeys are tracked as their own logical change. Integrated offline, no-build, no-IFD metadata evaluation lists exactly the five keys targeting `monitoring/alertmanager-delivery`; generated operations documentation includes them. The runbook records intended account settings. Provider-side settings and live delivery are not inferred from ciphertext presence, so 9.1–9.3 and live acceptance remain open.

## 10. Live acceptance (operator-gated; not authorized by this plan)

- [ ] 10.1 After the host deploy, scrape the host exporter from the guest. From the LAN and the tailnet, confirm the port is unreachable. Confirm `smart.prom` lists every disk from task 2.1, and `zpool.prom` lists `rpool`. Record the commands and results.
- [ ] 10.2 Reproduce the motivating incident in a scratch namespace: run a pod with a 64Mi limit that allocates past it once. Confirm a critical `KubeContainerOOMKilled` reaches Pushover at priority 1 and Telegram within 5 minutes while its Argo Application shows Healthy, and that the resolution notice follows.
- [ ] 10.3 Fire a test warning during the owner's Pushover quiet hours. Confirm it reaches Telegram, and reaches Pushover at normal priority without overriding quiet hours. Separately inject a synthetic SMART new-error event through the authorized alert test path (no real disk mutation), let its window end and confirm no resolved/recovered message follows; confirm an ordinary warning still sends its matching recovery.
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
