# Monitoring operations

Monitoring runs in the `monitoring` namespace on the compute guest. It alerts
the owner through Pushover and Telegram, and an external dead man's switch
(healthchecks.io) alerts when monitoring itself goes quiet. The contract is
the `fleet-monitoring` capability; this runbook covers operating it.

| Component | Where | Role |
| --- | --- | --- |
| VictoriaMetrics | `monitoring/victoriametrics` | Collects every 30 s and stores 90 days on the retained path `monitoring-metrics`. |
| vmalert | `monitoring/vmalert` | Evaluates the alert rules every 30 s. |
| Alertmanager | `monitoring/alertmanager` | Routes alerts to Pushover and Telegram; sends the heartbeat. |
| Grafana | `https://grafana.<domain>` | Dashboards, administrators only. |
| kube-state-metrics, blackbox exporter | `monitoring` | Kubernetes object state; endpoint probes and served certificates. |
| node_exporter, `zpool-status`, `smart-status` | host `hvn-hyp1` | Host metrics, ZFS pool status (every 2 min), SMART health (every 15 min). |

Metrics, alert rules and alert routing never depend on Kanidm, the Gateway
or cert-manager. Only Grafana does.

## What lives in Nix and what doesn't

Declared in Nix and rendered to `generated/manifests/prod-home/`:

- every Deployment, chart and image, pinned by version and digest;
- the alert rules (`modules/den/aspects/kubernetes/services/monitoring/alerting.nix`),
  unit-tested by the `monitoring-rules` check;
- the scrape targets: host exporters through the `prometheus-targets`
  quirk, cluster sources from the cluster declaration;
- Alertmanager routing, inhibition and templates (also `alerting.nix`),
  checked by `monitoring-alertmanager`; credentials appear only as file
  paths;
- Grafana's data sources and dashboards (`assets/monitoring/dashboards/`,
  each with its source, revision and SHA-256 in `sources.json`);
- the host exporter, the status timers, the declared disks and pools, and
  the firewall rule;
- the Kanidm client for Grafana, the retained path, the retention period,
  the free-space floor and every resource limit.

Encrypted in Git: the six runtime Secrets below.

Outside Nix: the Pushover application, the Telegram bot and chat, the
healthchecks.io check, and runtime state (metrics data, silences, Grafana's
database, Grafana's random administrator password, and the Grafana client
secret that Kanidm generates).

## One-time setup

Do these once, in order. Never paste a credential value into a commit, PR,
issue or chat.

1. **Pushover.** Create an application named "Homelab alerts". Note its API
   token and your user key. Set your quiet hours in the Pushover app:
   warnings respect them, critical alerts bypass them.
2. **Telegram.** Create a dedicated bot with BotFather; do not reuse Hermes's
   bot. Create the alert chat (a direct chat with the bot, or a private
   group with it), send one message, and read the chat ID from
   `https://api.telegram.org/bot<token>/getUpdates`. Do not mute this chat:
   muting would also silence critical alerts there.
3. **healthchecks.io.** On the free tier, create one check named "Homelab
   monitoring heartbeat" with a **period of 5 minutes** and a **grace of 10
   minutes**. Add its Pushover and Telegram integrations with the same user
   and chat. Note the check's ping URL. Anyone holding it can send pings and
   hide an outage, so treat it as a credential.
4. **Secrets.** Store the five delivery values and rekey, as below, then
   commit the encrypted files.
5. **Deploy** `hvn-hyp1` (operator-gated), then let Argo CD sync.

## Runtime Secrets

| Source (`.secrets/hosts/compute-1/<source>.age`) | Kubernetes Secret → key | Supplied by |
| --- | --- | --- |
| `monitoring--alertmanager-delivery--pushover-token` | `alertmanager-delivery` → `pushover-token` | Pushover application token |
| `monitoring--alertmanager-delivery--pushover-user-key` | `alertmanager-delivery` → `pushover-user-key` | Pushover user key |
| `monitoring--alertmanager-delivery--telegram-bot-token` | `alertmanager-delivery` → `telegram-bot-token` | dedicated bot token |
| `monitoring--alertmanager-delivery--telegram-chat-id` | `alertmanager-delivery` → `telegram-chat-id` | alert chat ID |
| `monitoring--alertmanager-delivery--heartbeat-url` | `alertmanager-delivery` → `heartbeat-url` | healthchecks.io ping URL |
| `monitoring--grafana-admin--secret-key` | `grafana-admin` → `secret-key` | agenix-rekey `alnum-no-newline` generator, committed |

Grafana's secret key is generated and committed; it needs only a rekey.
Each delivery secret is declared only once its encrypted file exists:
agenix-rekey refuses to evaluate a request whose file is missing, and the
staging unit copies every declared secret. Until then Alertmanager keeps
running and every send through that channel fails.

Alertmanager reads the Pushover token and user key exactly as stored, so no
value may end in a newline. From a Git checkout of the repository, run this
sequence. `store` reads each value without echoing it and encrypts it to the
master public key; only `agenix rekey` needs your master identity:

```sh
nix develop            # provides age and agenix
umask 077
store() {
  read -rsp "$1: " value; echo
  printf '%s' "$value" | age -R .secrets/pub/master.pub \
    -o ".secrets/hosts/compute-1/monitoring--alertmanager-delivery--$1.age"
  unset value
}
store pushover-token
store pushover-user-key
store telegram-bot-token
store telegram-chat-id
store heartbeat-url
git add .secrets/hosts/compute-1/monitoring--alertmanager-delivery--*.age
agenix rekey -a
nix eval --json .#nixosConfigurations.hvn-hyp1.config.secretRequests \
  --apply 'r: builtins.filter (n: builtins.match "monitoring--.*" n != null) (builtins.attrNames r)'
nix run .#sync-prod-home-manifests && nix run .#write-files
```

The `nix eval` must list the six `monitoring--…` sources; it prints names,
never values. Commit the new `.age` files, the rekeyed copies under
`.secrets/hosts/hvn-hyp1/rekeyed/` and the regenerated output, then deploy
`hvn-hyp1`.

### Rotation

Revoke the old credential at the provider, store the new value with the same
source name (`store` above), rekey, commit and deploy `hvn-hyp1`.
`compute-stage-secrets` restages the Secret, and Alertmanager reads its files
at each send, so no restart is needed. To rotate the heartbeat URL,
regenerate it on the healthchecks.io check. To rotate Grafana's secret key,
delete its `.age` file, run `agenix generate -a` and `agenix rekey -a`, and
deploy; it signs Grafana's sessions, so everyone signs in again.

## Severity routing

| Severity | Pushover | Telegram | Repeats |
| --- | --- | --- | --- |
| critical | priority 1 (bypasses quiet hours) | yes | every 4 h |
| warning | priority 0 (respects quiet hours) | yes | every 24 h |

This is configuration in `alerting.nix`, not contract. You can change
it there without a spec change; the `monitoring-alertmanager` check fails if
a change drops a critical alert from either channel, lets quiet hours hold
one, leaves a warning with no channel, or stops resolution notices.

- Quiet hours are set in the Pushover app, never in Homelab.
- Telegram has no sender-side quiet hours: every message notifies.
- A failing channel is reported through the other one only
  (`AlertDeliveryFailing`). A channel that breaks while idle is found at its
  next send attempt; there is no daily probe yet.

## Grafana

Grafana is public, like Argo CD, and has two sign-in layers, both through
Kanidm and both limited to the administrator group:

1. The Gateway requires Kanidm sign-in before it forwards any request.
   Requests without a session are redirected to Kanidm and never reach the
   Grafana pod.
2. Grafana signs you in again through the same Kanidm client. Its login
   form, basic authentication and anonymous access are off, and only the
   administrator group receives a role.

From outside the household network, open `https://grafana.<domain>`. Grafana
serves one hostname: sign-in from the backup hostname returns you to the
canonical one. Grafana appears only in identity phase `normal`.

Dashboards come from Git and cannot be saved from the UI. To change one, edit
or replace the JSON under `assets/monitoring/dashboards/`, update its entry in
`sources.json` (source, revision, SHA-256), and regenerate the manifests.

### Break-glass: Grafana without Kanidm

Grafana's built-in `admin` gets a random password at every Pod start: an
init container writes it to a memory-backed volume, and Grafana reads it
with `$__file{}`. Nobody knows it and it is never stored. Grafana applies it
only when it creates its database. The database is an `emptyDir`, so each
new Pod gets a new database and a new password; a container restart in the
same Pod keeps both.

When Kanidm is down you rarely need Grafana. `kubectl -n monitoring
port-forward svc/victoriametrics 8428` serves VictoriaMetrics' query UI at
`/vmui`, and `svc/alertmanager 9093` serves Alertmanager's UI, including
silences. Port-forwarding is not subject to NetworkPolicy, and these UIs
have no login, so treat that access like the cluster access it comes from.

To use Grafana itself, run these on the host. The login form must be turned
on, because a password alone gives no way in; basic authentication stays
off.

1. Hold automated sync on `apps` and `monitoring`, or self-heal reverts
   step 2:

   ```sh
   k() { incus --project compute exec compute-1 -- k3s kubectl "$@"; }
   for app in apps monitoring; do
     k -n argocd patch application "$app" \
       --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
   done
   ```

2. Turn on the login form. This replaces the Pod, so wait for the rollout:

   ```sh
   k -n monitoring set env deployment/grafana GF_AUTH_DISABLE_LOGIN_FORM=false \
     GF_AUTH_OAUTH_AUTO_LOGIN=false GF_SERVER_ROOT_URL=http://localhost:3000/
   k -n monitoring rollout status deployment/grafana
   ```

3. Set a password of your choice. It is read from standard input, so it
   does not appear in a process list:

   ```sh
   read -rsp 'Grafana admin password: ' pw; echo
   printf '%s' "$pw" | k -n monitoring exec -i deployment/grafana -c grafana -- \
     grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
     admin reset-admin-password --password-from-stdin
   unset pw
   ```

4. Port-forward `svc/grafana 3000:80` from the host's cluster access, as
   for the media apps, open `http://localhost:3000/login` and sign in as
   `admin`.
5. Restore automated sync on `apps`. Its sync restores `monitoring`, which
   reverts the Deployment; the new Pod has a new random password:

   ```sh
   k -n argocd patch application apps \
     --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```

The `monitoring-grafana-runtime` check runs steps 2 to 4 against the pinned
Grafana image.

## Silences

Silence through Grafana (Alerting → Silences, data source "Alertmanager").
Grafana keeps this external Alertmanager UI enabled; its own alert-rule
execution is disabled because vmalert evaluates the declared rules.
Silences live in Alertmanager's `emptyDir` and are lost when the pod or the
guest is replaced; re-create them afterwards. The heartbeat cannot be
silenced in Alertmanager: pause the check in healthchecks.io for planned
outages instead.

## A "heartbeat down" notice

healthchecks.io alerts when no ping has arrived for 15 minutes. The
heartbeat is sent only while fresh data is stored and alerts are evaluated
and routed. In order of likelihood:

1. **The guest, host, power or uplink is down.** Check that `hvn-hyp1`
   answers and that the guest is running.
2. **Ingestion stopped.** In the guest, check
   `kubectl -n monitoring get pods`, then VictoriaMetrics' logs. Look for
   `vm_storage_is_read_only 1` on `victoriametrics:8428/metrics`: the store
   refuses writes once the pool has less than 50 GiB free.
3. **VictoriaMetrics is waiting on its storage.** If the pod is
   `ContainerCreating`, `kubectl -n monitoring describe pod` names the cause:
   the retained path `/srv/state/monitoring-metrics` or the state-root marker
   is missing. This is intentional: it never writes to substitute storage.
   Restore the retained state root before anything else.
4. **vmalert or Alertmanager stopped.** Check their pods and logs.

### Testing the heartbeat

To prove that the heartbeat stops when ingestion stops while every
monitoring service keeps running, pause Argo CD auto-sync for the
`monitoring` Application and apply an egress-deny NetworkPolicy that
selects only the VictoriaMetrics pod:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: drill-stop-ingestion
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: victoriametrics
  policyTypes: [Egress]
```

Its scrapes fail, but its query API still answers vmalert and Grafana.
healthchecks.io should report the check down within 30 minutes. Delete the
policy, resume auto-sync, and wait for the recovery notice. The guest's
NetworkPolicy enforcer, kube-network-policies, applies egress rules; the
`monitoring-k3s-runtime` check shows it with compute-1's K3s flags.

## Metrics storage

History lives on the retained path `monitoring-metrics` under the state root
on `rpool/safe/persist`. It is **bounded but not isolated**: the dataset has
no quota, so it shares the pool with every other retained path and the host.
The claim's 20Gi size is a label; Kubernetes does not enforce it.

| Alert | Meaning | Action |
| --- | --- | --- |
| `MonitoringStorageGrowth` (warning) | History exceeds 20 GiB, expected under 9 GiB. | Look for a cardinality explosion (`/api/v1/status/tsdb`); fix its source. |
| `MonitoringStorageLow` (warning) | Pool free space under 100 GiB. | Find what is filling `rpool`. |
| `MonitoringStorageLow` (critical) | Under 70 GiB. Ingestion stops at 50 GiB. | Free space now. |
| heartbeat down | Under 50 GiB: VictoriaMetrics is read-only. | Free space; ingestion resumes by itself. |

`HostFilesystemLowSpace` (10 % warning, 5 % critical) also covers the host's
filesystems, including `/persist`.

## Is a workload hitting its limits?

Check this before you change a CPU or memory limit.

- **Where to look.** Homelab overview → "Container peaks against limits"
  lists, for the selected time range, each container's highest CPU use and
  working set as a share of its limit, and its highest share of throttled
  CPU periods. Set the range to cover the load you care about, for example
  several simultaneous Jellyfin transcodes, and read that container's row.
  The panel links to the Kubernetes pod dashboard, which plots the same
  values over time.
- **`KubeContainerCPUThrottled`** (warning): the container was throttled in
  more than 25 % of its 100 ms CPU periods for 15 minutes. It keeps running
  into its CPU limit, so its work slows; nothing is killed.
- **`KubeContainerMemoryNearLimit`** (warning): its working set stayed above
  90 % of its memory limit for 10 minutes. An OOM kill is close.
- **`KubeContainerOOMKilled`** (critical): the kernel killed it at its memory
  limit.

A CPU peak near 100 % of the limit together with throttling means the limit
sets the pace. A memory peak well below the limit means memory has room.
Size a new limit from the observed peak plus a margin, and keep the guest's
total capacity in mind.

## Host telemetry

The host exporter listens on the compute bridge address (`10.210.0.1:9100`)
and the firewall admits only the guest (`10.210.0.10`) on `incus-compute`.
A failed status run keeps the previous file; the stale-file alerts then
report it, rather than a failed unit.

Declared disks are `services.host-telemetry.expectedDisks` in
`modules/den/hosts/hvn-hyp1/default.nix`. When a disk is added, replaced or
retired, edit that set in the same change:

- name SAS and SATA disks by `/dev/disk/by-id/wwn-…`;
- name a disk whose by-id names embed its serial number (these NVMe drives
  have no EUI) by `/dev/disk/by-path/…`;
- never record a serial number; leave out USB and virtual devices.

List candidates with `lsblk -d -o NAME,TYPE,TRAN,MODEL,WWN` and
`ls -l /dev/disk/by-id /dev/disk/by-path`. A disk that stays declared but is
gone raises `HostDiskTelemetryMissing`. SMART reads every 15 minutes, so the
unused spares cannot spin down.

Required mounts are derived: each MergerFS pool and each provisioned
`disk.luks-storage` mount. Add any other mount to
`services.host-telemetry.extraRequiredMounts`.

## Known gaps

- Probes start inside the guest. They miss failures in the host's DNAT, LAN
  DNS, the router and the public edges. External probing is a follow-up
  change.
- No backups or recovery monitoring; that is a future change. Metrics
  history is not a backup.
- No active channel checks: a channel that breaks while idle is found at its
  next send.
- No log aggregation and no application-specific alerts.
