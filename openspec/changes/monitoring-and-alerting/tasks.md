## 1. Contract checks and scaffolding

- [ ] 1.1 Add `modules/tests/monitoring-contracts.nix` with evaluation-only checks. It must fail when:
  - a non-monitoring Application declares sync wave ≥ 5;
  - any monitoring Application is below wave 5;
  - a route targets a monitoring Service other than Grafana, or the Grafana route is not `auth = "admin"`;
  - a declared route has no endpoint probe;
  - an image is not `tag@digest` or a chart has no version and hash.

  Verify with `nix build path:$PWD#checks.x86_64-linux.monitoring-contracts`, plus one deliberately failing fixture per rule.
- [ ] 1.2 Add the `kubernetes.services.monitoring` aspect group with two empty Applications: `monitoring-retained` (wave 5, `retained = true`) and `monitoring` (wave 6). Include it in `den.aspects.prod-home`. Verify that the `prod-home-gitops-source` check accepts the `monitoring` namespace in the AppProject destinations, and that 1.1 passes.

## 2. Host telemetry (hvn-hyp1)

- [ ] 2.1 Add the host telemetry aspect: node_exporter (systemd, filesystem, zfs and textfile collectors) and smartctl_exporter (15-minute interval, covering every physical disk including the unused `sdc`, `sdf` and `sdg`, and excluding USB and virtual devices). Bind both to the compute bridge's host address taken from host data, with `MemoryMax` and restart-on-failure. Verify by evaluation that `hvn-hyp1`'s listen addresses equal the bridge address and that no wildcard bind exists.
- [ ] 2.2 Add the `zpool-status` oneshot and its 2-minute timer, writing `zpool.prom` atomically from `zpool status -j -p`. Verify with a unit test of the converter against recorded JSON for an ONLINE pool, a DEGRADED pool, device errors, and a scrub with errors.
- [ ] 2.3 Make the aspect emit `prometheus-targets` entries. Add the host consumer aspect, which (a) renders one nftables input rule admitting only the guest address on the compute interface to the exporter ports, and (b) exposes the resolved target list and the required-mount list as read-only options. The mount list is the mergerfs pool mountpoints, plus provisioned `disk.luks-storage` mountpoints, plus an `extraRequiredMounts` list that is empty today. Verify by evaluation that the targets and rule text are what `hvn-hyp1`'s data implies, that the rule names no other source or interface, and that the mount list is exactly `/srv/media/data` and `/mnt/storage-clear/media4`, with no legacy gocryptfs mount (media1–3).
- [ ] 2.4 Extend an existing host VM test, or add a small one, to show that (a) activation succeeds while the bridge does not exist yet and the exporters start once it does, and (b) a client on another interface cannot connect to the exporter ports while the guest address can.

## 3. Cluster collection core

- [ ] 3.1 Pin and render VictoriaMetrics single-node: retained path `monitoring-metrics`, a static PV and PVC pinned to the compute instance, `-retentionPeriod=90d`, `-storage.minFreeDiskSpaceBytes=50GiB`, and the resource limits from design.md. Verify the generated manifests show the retained `guestPath`, the flags, the limits, and no chart test or hook objects.
- [ ] 3.2 Render the scrape config from (a) the host's `scrapeTargets` option read from `nixosConfigurations.${cluster.hostName}`, (b) kubelet and cAdvisor through the node, (c) the Argo CD controller metrics Service, (d) cert-manager, (e) kube-state-metrics, (f) blackbox probe targets derived from `cluster.routes`, and (g) monitoring self-scrape. Verify with an evaluation check that compares the rendered jobs to the expected set for `prod-home`.
- [ ] 3.3 Pin and render kube-state-metrics, with resources excluding `secrets` and `configmaps` and no label or annotation allowlists. Verify the generated Deployment arguments, and that its RBAC is read-only.
- [ ] 3.4 Pin and render the blackbox exporter with two modules: `native` (2xx on a health path) and `admin` (302 to the identity hostname). Probes go to the gateway NodePort, with SNI and `Host` set per route. Verify the generated probe list covers every route in `cluster.routes`.
- [ ] 3.5 Set `controller.metrics.enabled = true` and the `ComparisonError` application-condition metric in `argocd.nix`. Verify the generated metrics Service exists and that the existing NetworkPolicy still admits it.

## 4. Alert rules, routing and secrets

- [ ] 4.1 Write the rule files from design.md Decision 5 as Nix-rendered Prometheus YAML. Add `vmalert-tool unittest` (or `promtool test rules`) cases that prove each `fleet-monitoring` time bound:
  - a single OOM kill fires as critical within 5 minutes, even though Argo CD reports Healthy;
  - a crash loop fires at 15 minutes and not before;
  - out-of-sync for 25 minutes does not fire;
  - an absent required mount fires;
  - free space below 10% fires a warning, and below 5% a critical;
  - a missing host source fires `TelemetrySourceDown` and does not resolve the storage alerts.

  Verify the flake check passes.
- [ ] 4.2 Render vmalert and the Alertmanager config: severity routes, the Watchdog heartbeat route, cross-channel `AlertDeliveryFailing` routes, inhibition rules, grouping, `send_resolved`, and file-based credential fields. Verify with `amtool check-config` and `amtool config routes test` in a flake check, covering:
  - critical → Pushover at priority 1 and Telegram;
  - warning → Pushover at priority 0 and Telegram;
  - Watchdog → heartbeat only;
  - Pushover failure → Telegram only, and Telegram failure → Pushover only (priority 1).

  Also settle whether the pinned Alertmanager reads Telegram `chat_id` from a file, or needs the init-container fallback in design.md Decision 6.
- [ ] 4.3 Declare the five delivery runtime secrets and the two Grafana generator secrets in `compute-resources.runtimeSecrets`. Mount the delivery Secret with `optional: true`. Verify by evaluation that the host's `runtimeSecrets` contains them. Verify with a container-level test that the pinned Alertmanager starts without the files and records a failed notification, rather than crashing or using a placeholder.
- [ ] 4.4 Add a check that the generated manifests, `docs/operations.md` and the rendered Alertmanager and Grafana configs contain only secret paths and references. They must contain no credential field with an inline value and no `hc-ping.com/<uuid>` pattern. Verify the check fails on a planted inline value.

## 5. Dashboards and sign-in

- [ ] 5.1 Generalize the Argo CD special case in `identity.nix` into a declared per-route native sign-in (callback paths, landing, scopes, secret targets, and the Kanidm NetworkPolicy allow). Move Argo CD onto it. Verify that `modules/tests/identity-contracts.nix` still passes, and that Argo CD's generated Kanidm client, Secret targets and NetworkPolicy are byte-for-byte unchanged.
- [ ] 5.2 Add `routes.grafana` (`auth = "admin"`, `exposure = "public"`, `displayName = "Grafana"`, like `routes.argocd`) with Grafana's native sign-in declaration. Verify by evaluation that:
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
- [ ] 5.4 Vendor the dashboards under `assets/monitoring/dashboards/`, each with its upstream source, revision and SHA-256. Write the Homelab overview dashboard. Provision data sources and dashboards from ConfigMaps with UI updates disabled. Verify with a check that every vendored file's hash matches its record and that each dashboard parses as JSON.

## 6. Network policy and exposure

- [ ] 6.1 Add default-deny ingress for the `monitoring` namespace and the narrow allows from design.md Decision 10. Add a Kanidm allow for Grafana's backend pods through 5.1. Verify by evaluation that every monitoring Service is selected by a policy and that only the Gateway may reach Grafana.

## 7. Failure domain and resource bounds

- [ ] 7.1 Set requests and limits on every monitoring container, as in design.md Decision 14. Verify with an evaluation check that no monitoring container lacks CPU and memory limits, and that the guest totals are at most 3 CPU and 3.5Gi.
- [ ] 7.2 Run the existing identity, gateway and `prod-home` replacement checks with the monitoring Applications present. Verify they pass without waiting on monitoring health.

## 8. Documentation and generated output

- [ ] 8.1 Write `docs/operations/monitoring.md`. It covers:
  - the one-time external account setup in section 9, with exact settings (the Pushover app; the dedicated Telegram bot and chat; the healthchecks.io check period, grace and integrations);
  - what lives in Nix and what doesn't, as in design.md;
  - `agenix edit` for each secret, and credential rotation;
  - severity routing: what reaches Pushover at which priority, and why warnings respect quiet hours;
  - reaching Grafana from outside the household network, and the two sign-in layers;
  - silences, and why they are lost on guest replacement;
  - reading a heartbeat-down notice;
  - the gaps: no off-LAN probing (a follow-up change), no backups (a future change).

  Add the operations entry it needs. Verify that `nix run path:$PWD#sync-prod-home-manifests` and the docs generator leave a clean tree, and that the freshness checks pass.
- [ ] 8.2 Update `docs/operations/identity.md:122-124` to say that the OAuth counters remain unscraped by design. Kanidm application metrics are out of scope.

## 9. Owner one-time setup (manual, outside Nix; not authorized by this plan)

These steps create external accounts and supply credential values. Nothing here is declared in Nix. Never paste a value into a commit, PR, issue or chat; enter each one only through `agenix edit`, then rekey under `.secrets/hosts/` as `docs/operations.md` describes.

- [ ] 9.1 **Pushover.** Create a Pushover application for Homelab alerts. Store its API token as `monitoring--alertmanager-delivery--pushover-token` and the owner's user key as `monitoring--alertmanager-delivery--pushover-user-key`. Check that the owner's Pushover quiet hours are set as wanted, since warnings respect them and critical alerts bypass them.
- [ ] 9.2 **Telegram.** Create a dedicated bot with BotFather, separate from Hermes's bot. Create the chat that receives alerts (a direct chat with the bot, or a private group), send it one message, and read its chat ID. Store the bot token as `monitoring--alertmanager-delivery--telegram-bot-token` and the chat ID as `monitoring--alertmanager-delivery--telegram-chat-id`.
- [ ] 9.3 **healthchecks.io.** On the hosted free tier, create one check with a 5-minute period and a 10-minute grace. Add its Pushover and Telegram integrations, using the same Pushover user and Telegram chat. Store the check's ping URL as `monitoring--alertmanager-delivery--heartbeat-url`.
- [ ] 9.4 Confirm the five encrypted files exist under `.secrets/hosts/compute-1/` and that host evaluation sees all five in `runtimeSecrets`, without printing any value. Record the account settings (not the values) in `docs/operations/monitoring.md` (task 8.1).

## 10. Live acceptance (operator-gated; not authorized by this plan)

- [ ] 10.1 After the host deploy, from the guest: scrape both host exporters. From the LAN and the tailnet, confirm the ports are unreachable. Record the commands and results.
- [ ] 10.2 Reproduce the motivating incident in a scratch namespace: run a pod with a 64Mi limit that allocates past it once. Confirm a critical `KubeContainerOOMKilled` reaches Pushover at priority 1 and Telegram within 5 minutes while its Argo Application shows Healthy, and that the resolution notice follows.
- [ ] 10.3 Fire a test warning during the owner's Pushover quiet hours. Confirm it reaches Telegram, and reaches Pushover at normal priority without overriding quiet hours.
- [ ] 10.4 Stop VictoriaMetrics, or scale Alertmanager to zero. Confirm healthchecks.io notifies through both channels within 30 minutes, and reports recovery after restoring.
- [ ] 10.5 Revoke or blank the Pushover token. Confirm `AlertDeliveryFailing` arrives through Telegram only. Restore it. Repeat for the Telegram token, confirming the alert arrives through Pushover only.
- [ ] 10.6 Stop host node_exporter. Confirm `TelemetrySourceDown` fires and the storage and mount alerts are inhibited rather than falsely firing or resolving.
- [ ] 10.7 From outside the household network (for example a phone on mobile data):
  - request `grafana.<domain>` without a session, and confirm the Gateway redirects to Kanidm and the Grafana pod logs no request;
  - sign in as an administrator, and confirm Grafana grants access;
  - sign in as a non-administrator Kanidm identity, and confirm it is refused before reaching Grafana;
  - confirm Grafana offers no login form and no anonymous access;
  - confirm no route on any entrance serves VictoriaMetrics, vmalert, Alertmanager or the exporters.
- [ ] 10.8 Replace the compute guest through the documented procedure. Confirm metrics from before the replacement remain queryable, and that dashboards and rules return without manual steps.
