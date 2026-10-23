<!-- provenance: generated from evaluated Den/Nix declarations by modules/flake/docs/monitoring.nix; edit that source, not this copy. -->
# Monitoring operations

Monitoring runs in `monitoring` on `compute-1`, hosted by
`hvn-hyp1`. VictoriaMetrics collects and retains metrics,
vmalert evaluates rules, and Alertmanager sends notifications and the
external healthchecks.io heartbeat. Grafana is the dashboard and silence
interface, not the alert evaluator.

## Access

Open [Grafana](https://grafana.plus2.danielvicory.dev) or its Kanidm tile.
Normal access is central-administrator-only at both the Gateway and
Grafana. Grafana refuses its local login form, basic authentication and
anonymous access. The secondary hostname returns sign-in to the canonical
hostname. See the generated [route inventory](../operations.md#declared-routes)
for hostnames and backends.

Core collection and delivery do not require Kanidm, the Gateway or
cert-manager. Grafana does; endpoint probes and certificate monitoring
also lose coverage when their respective dependencies fail.

Endpoint checks follow the Gateway's published routes. Administrator
entrances are not probed during identity bootstrap, and Requests is not
probed before its ready phase; intentionally unpublished routes are not
endpoint outages.

For direct diagnosis, use authenticated cluster access. On the host, in
Bash, define this helper for the commands below:

```sh
k() { incus --project compute exec compute-1 -- k3s kubectl "$@"; }
k -n monitoring get pods
```

Prefer VictoriaMetrics' `/vmui` and Alertmanager's UI when identity is
unavailable; they do not need Grafana's emergency login. On the host:

```sh
k -n monitoring port-forward --address 127.0.0.1 svc/victoriametrics 8428:8428
# Or, in a separate session:
k -n monitoring port-forward --address 127.0.0.1 svc/alertmanager 9093:9093
```

These commands bind the **guest's** loopback, because `k` executes there.
Use the SSH tunnel described under [private emergency access](#private-emergency-grafana-access),
substituting the desired local and remote port. These UIs have no login;
port-forwarding bypasses NetworkPolicy. Never bind them to all interfaces.

## Notifications and silences

Critical alerts go to Pushover and Telegram; Pushover critical delivery
bypasses quiet hours. Ordinary warnings use both channels and respect
Pushover quiet hours. Keep the Telegram alert chat unmuted: muting it also
hides critical messages. Quiet hours belong in the Pushover application.

`HostDiskSmartErrorsIncreasing` is a **new-error event warning**, with a
separate identity for each disk and counter signal. Its notification says
that new errors were observed; it does not open an uncleared physical
incident. The event window ending sends **no recovery notification** and
does not prove the disk healthy. Inspect the affected disk and surrounding
history. Actual `HostDiskSmartFailing`, missing/stale telemetry and other
condition alerts remain separate, with explicit healthy recovery evidence.
Ordinary condition alerts still send resolutions.

`AlertDeliveryFailing` reports a failing notification channel through the
other channel only. A channel that breaks while idle is detected at its
next send, not by an independent daily test. `Watchdog` goes only to the
external heartbeat check.

Create a bounded silence in Grafana: **Alerting → Silences → Alertmanager**.
Match the intended alert and affected labels; record the maintenance reason
and expiry. When Grafana is unavailable, use the private Alertmanager UI.
Silences live in disposable Alertmanager storage and are lost with its Pod
or the guest; inspect and recreate necessary silences after replacement.
Do not silence `Watchdog`: that stops pings and triggers the external outage
notice. Pause the healthchecks.io check for planned monitoring outages, and
unpause it and confirm fresh pings afterwards.

## Heartbeat down or notifications missing

The external healthchecks.io check requires a **5-minute period** and
**10-minute grace**. Enable its Pushover and Telegram integrations for the
same Pushover user and Telegram chat used by Alertmanager. Inspect these
settings and the last successful ping when diagnosing missing notifications.
A new or replaced check provides no coverage until
the first successful ping. A heartbeat requires fresh stored core-source
data and working evaluation and routing; an exporter merely serving an old
value is not sufficient.

1. Check `hvn-hyp1`, the guest, power and uplink. On the host:
   `incus --project compute info compute-1`.
2. Check Pods and then the failing component's logs:

   ```sh
   k -n monitoring get pods
   k -n monitoring logs deployment/victoriametrics
   k -n monitoring logs deployment/vmalert
   k -n monitoring logs deployment/alertmanager
   ```

3. For `ContainerCreating`, describe the affected Pod. The default native
   runtime refuses every retained init/app start, including cached
   restarts, if the root or entry is missing, replaced or on the wrong
   backing. Follow [the unavailable-source recovery procedure](../operations.md#restore-an-unavailable-source);
   never create a substitute directory or marker to force the Pod through.
4. Check VictoriaMetrics' `vm_storage_is_read_only` metric and free space.
   Read-only storage stops ingestion and therefore stops the heartbeat.
   Use [metrics storage](#metrics-storage) below rather than restarting
   into a new empty history.
5. Inspect source-down alerts and recent source samples. A running scrape
   process alone does not prove that fresh core data is stored.
6. For delivery failure, inspect Alertmanager's notification-failure
   counters and logs, staged credential availability and outbound access.
   Check provider state and healthchecks.io integrations, pause state and
   active Alertmanager silences. Do not paste credentials or the heartbeat
   URL into reports. If both notification channels fail, neither can
   report the other's failure.

## Metrics storage

Metrics use retained key `monitoring-metrics` at `/srv/retained/state/monitoring-metrics`
in the guest. The generated [retained-state inventory](../operations.md#retained-state)
gives the host path, writer UID/GID and mode. Retained history is not a
backup. The metrics directory shares its backing pool; the PVC's requested
size is not an enforced quota or space reservation.

| Symptom | Diagnosis and action |
| --- | --- |
| `MonitoringStorageGrowth` | Inspect cardinality and series growth with VictoriaMetrics' `/api/v1/status/tsdb`; repair the source of unexpected growth. |
| `MonitoringStorageLow` | Inspect actual pool free space and other retained writers; use the alert's severity and current threshold. Recover space before the store's read-only boundary. |
| `HostFilesystemLowSpace` | Inspect the named host filesystem and backing pool, not only the metrics directory. |
| `vm_storage_is_read_only = 1` | Recover real free space. Ingestion resumes when the store can write; verify fresh samples and heartbeat pings afterwards. |
| Missing or wrong retained mount/identity | Follow [restore an unavailable source](../operations.md#restore-an-unavailable-source). Do not point VictoriaMetrics at guest-root storage. |

Read current thresholds and durations in the firing alert and effective
VictoriaMetrics configuration rather than treating a runbook table as a
second configuration. Do not delete history, format storage or restore a
database merely to clear an alert. Investigate the writer and backing
filesystem first.

Incus mount propagation is one-way. Keep an unavailable source absent
while retiring affected Pods and their old publications, before
reattachment. Follow [restore an unavailable source](../operations.md#restore-an-unavailable-source)
for the authoritative host-root validation, publication and recovery
order. Argo health and directory existence do not prove retained identity.

## Credentials and rotation

Use the generated [runtime-secret inventory and procedure](../operations.md#runtime-secret-references)
for source names, encryption, rekeying and staging. Never put plaintext in
Git, manifests, command arguments, logs or reports. Keep single-line
delivery values free of trailing newlines: Alertmanager reads Pushover's
token and user key verbatim. Missing credential files do not stop
Alertmanager, but sends through that integration fail.

- **Pushover:** rotate the application token or user key with the provider,
  then update the matching encrypted source.
- **Telegram:** use the dedicated monitoring bot and alert chat, not a
  shared service bot; rotate its token or update its chat ID as needed.
- **healthchecks.io:** the ping URL is a credential: its holder can forge
  pings and hide an outage. Regenerate an exposed URL, update its source,
  and confirm the check's Pushover/Telegram integrations and new pings.
- **Delivery staging:** deploy the updated host secret declarations and
  let `compute-stage-secrets` restage them. Alertmanager reads credential
  files at each send, so delivery rotation does not need a restart. Confirm
  each affected channel works without exposing its value.
- **Grafana:** both `monitoring--grafana-admin--admin-password` and
  `monitoring--grafana-admin--secret-key` are generated managed secrets,
  staged into `monitoring/grafana-admin`. Rotate through the existing
  generated-secret flow, not a hand-entered replacement password. The
  admin password seeds a **new database**; changing its mounted file does
  not reset the existing database's password. After staging either
  rotation, replace the Grafana Pod so its disposable database is newly
  created. A container restart in the same Pod is insufficient. This
  discards disposable Grafana sessions/local edits, not VictoriaMetrics
  history. The secret key protects secrets stored in that database.

Normal Grafana access remains central-admin-only even though the managed
local administrator credential exists. You do not need to retrieve this
password for routine sign-in.

## Private emergency Grafana access

Prefer the private VictoriaMetrics and Alertmanager UIs first. If Grafana
itself is necessary without Kanidm, use the following reversible local
override. Do not weaken Gateway authentication or NetworkPolicy, publish
a recovery route, or change identity phase.

**Safety gate:** enabling Grafana's form while its Gateway route remains
published is not private recovery. Hold reconciliation, withdraw the
entrance and prove that withdrawal has reached the data plane **before**
enabling any local-auth override. Route deletion alone is not proof of
propagation. This procedure assumes usable native Argo/cluster access and
already verified SSH identities; if either is unavailable, stop rather
than exposing an alternate login. It has no claim of live recovery proof.

1. In Bash on the host, use `k` from [Access](#access). Record the existing
   automated-sync policies. Hold the root, route owner and workload owner:

   ```sh
   for app in apps identity-gateway monitoring; do
     k -n argocd get application "$app" -o jsonpath='{.spec.syncPolicy.automated}'
     printf '\n'
     k -n argocd patch application "$app" --type merge \
       -p '{"spec":{"syncPolicy":{"automated":null}}}'
   done
   k -n argocd get applications apps identity-gateway monitoring
   ```

   Holds do not cancel an operation already running. Let it finish or
   terminate it through native Argo controls, then confirm all three are
   idle and their holds persist. Do not manually sync them during recovery.
   The root must remain held or it can restore child automation.

2. Withdraw Grafana's entrance, keeping its authentication policy intact:

   ```sh
   k -n gateway delete httproute grafana
   k -n gateway wait --for=delete httproute/grafana --timeout=60s
   ```

   Verify that no other live route forwards to Grafana, and that every
   declared hostname (`grafana.plus2.danielvicory.dev`, `grafana.backup.plus2.danielvicory.dev`) no longer reaches Grafana
   through each active entrance. Confirm the Gateway has applied the
   withdrawal; use an existing authenticated session as well as signed-out
   requests, because a Kanidm redirect alone does not prove isolation.
   If data-plane withdrawal cannot be established, **leave ordinary auth
   unchanged**. Keep the route absent throughout the remaining work.

3. Enable only the local form on the isolated Grafana. Basic and anonymous
   access stay disabled. The cookie override is only for loopback HTTP:

   ```sh
   k -n monitoring set env deployment/grafana \
     GF_AUTH_DISABLE_LOGIN_FORM=false GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=false \
     GF_SERVER_ROOT_URL=http://localhost:3000/ GF_SECURITY_COOKIE_SECURE=false
   k -n monitoring rollout status deployment/grafana
   ```

   The rollout creates a new disposable Grafana database. Retrieve the
   generated `admin-password` from `monitoring/grafana-admin` through
   private secret access into your password manager; do not print it in
   shared output or use a CLI password reset as routine rotation.

4. On the host, forward only on the guest's loopback:

   ```sh
   k -n monitoring port-forward --address 127.0.0.1 svc/grafana 3000:80
   ```

   In another terminal on the browser workstation, substitute the existing
   guest SSH account for `<guest-ssh-user>`:

   ```sh
   ssh -N -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=yes \
     -o 'ProxyCommand=ssh -o StrictHostKeyChecking=yes -W %h:%p hvn-hyp1' \
     -L 127.0.0.1:3000:127.0.0.1:3000 <guest-ssh-user>@10.210.0.10
   ```

   Both host and guest keys, including the guest's independently staged
   identity, must already be verified. Stop if trust is unavailable or
   changes; never bypass host-key checking. The host is only a jump: the
   tunnel ends on the guest's loopback, not the host's. Open
   `http://localhost:3000/login` and sign in as `admin` with the managed
   password. Stop both foreground commands when finished.

5. **Restore ordinary authentication before re-publication.** Keep the
   entrance absent and all holds in place. Remove the temporary overrides:

   ```sh
   k -n monitoring set env deployment/grafana \
     GF_AUTH_DISABLE_LOGIN_FORM- GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN- \
     GF_SERVER_ROOT_URL- GF_SECURITY_COOKIE_SECURE-
   k -n monitoring rollout status deployment/grafana
   ```

   Confirm effective configuration again disables the form, basic and
   anonymous auth; enables provider-local OAuth auto-login; restores the
   canonical HTTPS root URL and secure cookies; and keeps strict central
   administrator role matching. Confirm the temporary environment values
   are gone and the local form cannot authenticate. Do not republish if
   any check is uncertain.

6. Restore the recorded automated-sync policies on `monitoring` and then
   `identity-gateway`, using native Argo controls. Confirm Grafana is
   healthy with ordinary auth before the route owner republishes its
   entrance. Restore `apps` last. Verify the published entrance requires
   central administrator sign-in at both layers and that all intended
   automation is restored. If Kanidm is still down, Grafana remains
   unavailable through its ordinary entrance; do not leave local login
   enabled to compensate.

## Workload limits

In Homelab overview, **Container peaks against limits** shows CPU,
working-set and throttling peaks for the selected time range. Select a
range that includes the real load and follow the row's Kubernetes Pod
dashboard link for the time series.

`KubeContainerCPUThrottled` means the CPU limit is slowing work, not
killing the container. `KubeContainerMemoryNearLimit` means little memory
headroom remains; `KubeContainerOOMKilled` means a kill was observed.
Inspect workload peaks, actual configured limits and guest memory
pressure before raising a limit. Leave headroom within the guest's total
capacity rather than assigning every workload its isolated peak.

Restart and OOM event alerts require observed counter growth. A cumulative
restart count or retained termination reason first seen when collection
starts is not evidence of a new incident. Counter resets alone are not
restart events.

## Host telemetry and hardware changes

The exporter listens on `10.210.0.1:9100`;
only `10.210.0.10` on `incus-compute` is admitted.
The textfile directory is `/run/host-telemetry`. A failed ZFS or
SMART collection keeps the previous file and modification time. Inspect
the status service logs and source freshness, not just exporter uptime or
a successful systemd unit state.

Missing-mount and missing/stale-collector diagnoses require a reporting
exporter. An unavailable exporter is a telemetry outage, not proof that
its mounts or collectors stopped. `TelemetrySourceDown` reports a source
outage after five minutes. A missing file or parse error is distinct from
a file whose observed modification time is old.

Known hardware, free-space and filesystem-statistics faults stay open
when their inputs disappear. Restore
fresh matching observations before calling it recovered: a sibling disk's
success, a new shared file or a missing/negative/invalid value is not
healthy evidence. This condition behavior does not turn the new-error
event warning into a latched incident.

A completed scrub reports its actual completion and errors. A canceled
scrub or a scan replaced by a resilver is not a completed scrub. An
overdue or unknown-history notice calls for checking the pool's history
and completing a scrub, not assuming success from missing data.

SMART discovery includes newly attached OS-exposed non-USB physical disks
and spares automatically. USB, optical and virtual/synthetic devices are
excluded. Physical members hidden behind a controller are not claimed as
covered by whole-disk discovery. Scheduled reads can wake disks; consider
that effect when attaching hardware. Argo holds do not pause host timers.

Required aliases are independently declared in
`services.host-telemetry.expectedDisks` on `hvn-hyp1`:
`media1`, `media2`, `media3`, `media4`, `rpool-a`, `rpool-b`, `spare-a`, `spare-b`, `spare-c`.
This floor must not shrink to only the disks currently found. A missing
required alias still raises `HostDiskTelemetryMissing`; an unread
automatically discovered disk uses the same alert family. Failed discovery
or unavailable private identity keeps the prior telemetry file unchanged.

For a replacement, preserve the required alias and change its stable
serial-free WWN/by-path identity deliberately. Retire an alias only when
the disk is intentionally no longer required; confirm remaining absence
coverage. Labels must not expose serial numbers, including native NVMe
WWN/by-id values that embed them. For non-probing OS metadata:

```sh
lsblk --json --nodeps --paths --properties-by udev --output NAME,TYPE,TRAN,SUBSYSTEMS
```

Required pools: `rpool`.
Required mountpoints: `/mnt/storage-clear/media4`, `/srv/media/data`.
These are evaluated expectations, **not proof of activated host state**.
Mount expectations come from Den MergerFS pools, provisioned LUKS mounts
and `services.host-telemetry.extraRequiredMounts`. See the generated
[storage inventory](../storage.md) for declarations and backing layout.

- **Add a mount host-first:** activate the host change, verify the exact
  mount with `findmnt` and its `node_filesystem_device_error` series in
  VictoriaMetrics, then roll out monitoring's new required-mount rule.
  Missing-mount coverage starts only when the new rule is active.
- **Remove an expectation monitor-first:** roll out monitoring without
  that expectation, verify the old rule is absent, then retire the host
  mount. Coverage ends when the rule is removed; retiring the mount first
  correctly triggers its old missing-mount alert.

Host activation and Argo rule rollout are not atomic. Query the exact host
and mountpoint, not a count or path prefix; an unrelated mount cannot
satisfy an expectation. The device-error series exists even when statfs
is denied: either value proves mount observation, not correct backing
storage or pool health. A permission error does not mean the mount is
absent. Capacity alerts still use readable filesystems; inspect the
physical backing filesystems when the MergerFS view is unreadable.
Combine exporter observation with `findmnt` and filesystem/pool alerts.
Do not grant the exporter media access to obtain capacity statistics.
`HostFilesystemStatsUnavailable` reports statistics-read errors on
required non-FUSE filesystems: capacity is unknown, not necessarily full
or unmounted. It clears only after matching readable statistics return
through a successful scrape; old or incomplete samples are not recovery.
Scrape freshness and the rule's hold affect when absence becomes visible;
it is not timed directly from unmount.

## Coverage limits

Endpoint probes start inside the guest. They cannot prove the host's DNAT,
LAN DNS, router or public-edge path works. Backup freshness and recovery
are not monitored. Metrics history is not a backup, and a quiet delivery
channel has no independent periodic delivery test.
