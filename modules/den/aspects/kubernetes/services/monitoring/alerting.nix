# Alert evaluation and delivery for prod-home monitoring.
#
# vmalert evaluates the rules below every 30 s against VictoriaMetrics, and
# Alertmanager sends what fires to Pushover and Telegram and pings the
# external dead man's switch. modules/tests/monitoring-rules.nix pins each
# rule's time bound; modules/tests/monitoring-alertmanager.nix checks the
# routing against the fleet-monitoring delivery requirement.
{
  config,
  inputs,
  lib,
  ...
}:
let
  namespace = "monitoring";
  images = {
    vmalert = {
      repository = "docker.io/victoriametrics/vmalert";
      tag = "v1.155.0@sha256:3256cba5ddaca5974eae6141105cec4ce37871f1c213f0a5c267ec0111bc68e1";
    };
    alertmanager = {
      repository = "quay.io/prometheus/alertmanager";
      tag = "v0.33.1@sha256:9e082985f56f4c8c9f724e18f2288c6708f472e56a5286b8863d080434ea065d";
    };
  };
  # Scrape jobs that default.nix defines besides the host's own. A missing
  # job raises TelemetrySourceDown; the core ones are critical and feed the
  # Watchdog. monitoring-contracts fails if this list and the scrape
  # configuration disagree.
  clusterJobs = [
    "kubelet"
    "cadvisor"
    "argocd"
    "cert-manager"
    "kube-state-metrics"
    "blackbox"
    "victoriametrics"
    "vmalert"
    "alertmanager"
  ];
  coreJobs = [
    "kubelet"
    "cadvisor"
    "kube-state-metrics"
    "host-node"
  ];
  credentialDirectory = "/etc/alertmanager/delivery";
  # The owner supplies these with `agenix edit`. Each is declared only once
  # its encrypted file exists: agenix-rekey refuses to evaluate a request
  # whose file is missing, and compute-stage-secrets copies every declared
  # secret, so an absent declaration would stop all runtime Secrets. Until
  # then the channel it serves fails at send time.
  deliveryKeys = [
    "pushover-token"
    "pushover-user-key"
    "telegram-bot-token"
    "telegram-chat-id"
    "heartbeat-url"
  ];
  labelsFor = name: {
    "app.kubernetes.io/name" = name;
    "app.kubernetes.io/part-of" = "monitoring";
  };

  rulesFor =
    host:
    let
      gib = n: toString (n * 1024 * 1024 * 1024);
      days = n: toString (n * 86400);
      node = ''job="host-node"'';
      ksm = ''job="kube-state-metrics"'';
      quote = builtins.toJSON;
      alert =
        name: severity: forDuration: expr: summary: extraLabels:
        {
          alert = name;
          inherit expr;
          labels = {
            inherit severity;
          }
          // extraLabels;
          annotations.summary = summary;
        }
        // lib.optionalAttrs (forDuration != "0s") { "for" = forDuration; };
      # A short raw-input bridge is not durable fault state. Renew an existing
      # firing identity through vmalert's own remote-written ALERTS until that
      # same identity has explicit healthy evidence. default_rollup respects
      # resolution staleness markers, so later absence cannot resurrect it.
      held = selector: "last_over_time(${selector}[2h])";
      storageAlert =
        name: severity: forDuration: fault: recovered: summary: extraLabels:
        let
          matchers = lib.concatStringsSep "," (
            lib.mapAttrsToList (key: value: "${key}=${quote value}") (
              extraLabels
              // {
                alertgroup = "host-storage";
                alertname = name;
                alertstate = "firing";
                inherit severity;
              }
            )
          );
          engineLabels = [
            "__name__"
            "alertgroup"
            "alertname"
            "alertstate"
            "severity"
          ]
          ++ builtins.attrNames extraLabels;
          previous = ''
            label_del(default_rollup(ALERTS{${matchers}}[2m]),
              ${lib.concatMapStringsSep ", " quote engineLabels})
          '';
        in
        alert name severity forDuration ''
          (${fault})
          or (${previous} unless (${recovered}))
        '' summary extraLabels;
      smartFreshness = 2700;
      smartMtimeSelector = ''node_textfile_mtime_seconds{${node}, file=~"(.*/)?smart\\.prom"}'';
      smartMtime = "max by (job, host, instance) (${smartMtimeSelector})";
      # A new file alone cannot bless an unread disk or an omitted counter.
      # These vectors carry the successful physical run's publication epoch,
      # not the timestamp/count of node_exporter's repeated scrapes.
      smartCollected = selector: ''
        (
          (0 * (default_rollup(${selector}[5m]) >= 0))
          + on (job, host, instance) group_left() (${smartMtime})
        )
        and on (job, host, instance) (up{${node}} == 1)
        and on (job, host, instance) (time() - (${smartMtime}) <= ${toString smartFreshness})
        and on (job, host, instance, disk, id)
          (default_rollup(homelab_smart_device_up{${node}}[5m]) == 1)
        and (
          tlast_over_time(${selector}[5m])
          >= on (job, host, instance) group_left() (${smartMtime})
        )
        and on (job, host, instance, disk, id) (
          tlast_over_time(homelab_smart_device_up{${node}}[5m])
          >= on (job, host, instance) group_left() (${smartMtime})
        )
      '';
      smartGrowth =
        metric:
        let
          selector = "homelab_smart_${metric}{${node}}";
        in
        # Growth is an event, not a physical fault with a recovery state.
        # Exclude invalid readings before comparing; never invent a baseline.
        alert "HostDiskSmartErrorsIncreasing" "warning" "0s"
          ''
            (ascent_over_time((${selector} >= 0)[2h:30s]) > 0)
            and (${smartCollected selector})
          ''
          "Disk {{ $labels.disk }} ({{ $labels.id }}) on {{ $labels.host }} reported new SMART errors ({{ $labels.signal }})."
          { signal = lib.replaceStrings [ "_" ] [ "-" ] metric; };
      hostLabels.host = host.name;
      hostReporting = "up{${node}, host=${quote host.name}} == 1";
      bySeverity = f: [
        (f "warning")
        (f "critical")
      ];
      # Event counters need an observed baseline, not increase()'s guessed zero.

      workloads = [
        (alert "KubeContainerOOMKilled" "critical" "0s"
          ''
            (
              increase_prometheus(kube_pod_container_status_restarts_total{${ksm}}[10m]) > 0
              and on (namespace, pod, container)
              kube_pod_container_status_last_terminated_reason{${ksm}, reason="OOMKilled"} == 1
            )
            or on (namespace, pod, container)
            (
              sum by (namespace, pod, container) (
                increase_prometheus(container_oom_events_total{job="cadvisor", container!=""}[10m])
              ) > 0
            )
          ''
          "{{ $labels.namespace }}/{{ $labels.pod }} container {{ $labels.container }} was OOMKilled and restarted."
          { }
        )
        (alert "KubeContainerRestarted" "warning" "0s" ''
          increase_prometheus(kube_pod_container_status_restarts_total{${ksm}}[10m]) > 0
          unless on (namespace, pod, container)
          kube_pod_container_status_last_terminated_reason{${ksm}, reason="OOMKilled"} == 1
        '' "{{ $labels.namespace }}/{{ $labels.pod }} container {{ $labels.container }} restarted." { })
        (alert "KubePodCrashLooping" "critical" "15m"
          ''
            max by (namespace, pod, container) (
              max_over_time(kube_pod_container_status_waiting_reason{${ksm}, reason="CrashLoopBackOff"}[5m])
            ) >= 1
          ''
          "{{ $labels.namespace }}/{{ $labels.pod }} container {{ $labels.container }} is crash-looping."
          { }
        )
        # Finished pods (Succeeded, or Failed including evicted) never count.
        (alert "KubePodNotReady" "critical" "15m" ''
          max by (namespace, pod) (kube_pod_status_ready{${ksm}, condition="true"} == 0)
          and on (namespace, pod)
          max by (namespace, pod) (kube_pod_status_phase{${ksm}, phase=~"Pending|Running|Unknown"} == 1)
        '' "{{ $labels.namespace }}/{{ $labels.pod }} has not been ready for 15 minutes." { })
        # True only in the first 30 minutes after an eviction: one notice,
        # then a resolution, however long the evicted pod object remains.
        (alert "KubePodEvicted" "warning" "0s" ''
          kube_pod_status_reason{${ksm}, reason="Evicted"} == 1
          unless
          kube_pod_status_reason{${ksm}, reason="Evicted"} offset 30m == 1
        '' "{{ $labels.namespace }}/{{ $labels.pod }} was evicted." { })
        # The Job's terminal Failed condition: retries or the deadline are
        # exhausted. kube-state-metrics 2.20 exports it as kube_job_failed.
        (alert "KubeJobFailed" "warning" "0s" ''
          kube_job_failed{${ksm}, condition="true"} == 1
        '' "Job {{ $labels.namespace }}/{{ $labels.job_name }} failed." { })
        (alert "KubeNodeMemoryPressure" "warning" "15m" ''
          kube_node_status_condition{${ksm}, condition="MemoryPressure", status="true"} == 1
        '' "Node {{ $labels.node }} reports memory pressure." { })
        # Throttled in more than a quarter of its 100 ms CFS periods for
        # 15 minutes: the container keeps running out of its CPU limit, not
        # just bursting at start-up. kubernetes-mixin's CPUThrottlingHigh uses
        # the same bound. Only containers with a CPU limit have CFS quota.
        (alert "KubeContainerCPUThrottled" "warning" "15m"
          ''
            (
              sum by (namespace, pod, container) (
                rate(container_cpu_cfs_throttled_periods_total{job="cadvisor", container!=""}[5m])
              )
              /
              sum by (namespace, pod, container) (
                rate(container_cpu_cfs_periods_total{job="cadvisor", container!=""}[5m])
              )
            ) > 0.25
            and on (namespace, pod, container)
            kube_pod_container_resource_limits{${ksm}, resource="cpu"} > 0
          ''
          "{{ $labels.namespace }}/{{ $labels.pod }} container {{ $labels.container }} was CPU-throttled in {{ $value | humanizePercentage }} of its periods for 15 minutes."
          { }
        )
        # The working set is what the kernel counts against the memory
        # limit; above 90 % for 10 minutes, an OOM kill is close.
        (alert "KubeContainerMemoryNearLimit" "warning" "10m"
          ''
            max by (namespace, pod, container) (
              container_memory_working_set_bytes{job="cadvisor", container!="", image!=""}
            )
            / on (namespace, pod, container)
            max by (namespace, pod, container) (
              kube_pod_container_resource_limits{${ksm}, resource="memory"}
            )
            > 0.9
          ''
          "{{ $labels.namespace }}/{{ $labels.pod }} container {{ $labels.container }} has used {{ $value | humanizePercentage }} of its memory limit for 10 minutes."
          { }
        )
      ];

      # The root Application `apps` only mirrors its children's health, so
      # it is left out of the health branch: one cause, one alert.
      gitops = [
        (alert "ArgoApplicationDegraded" "critical" "15m" ''
          max by (name, namespace) (argocd_app_info{job="argocd", name!="apps", health_status=~"Degraded|Missing"})
          or
          max by (name, namespace) (argocd_app_condition{job="argocd", condition="ComparisonError"})
        '' "Argo CD Application {{ $labels.name }} is degraded or cannot compare its source." { })
        (alert "ArgoApplicationOutOfSync" "warning" "30m" ''
          max by (name, namespace) (argocd_app_info{job="argocd", sync_status="OutOfSync"})
        '' "Argo CD Application {{ $labels.name }} has been out of sync for 30 minutes." { })
      ];

      hostStorage = [
        (storageAlert "HostZpoolUnhealthy" "critical" "1m" "${held "homelab_zpool_healthy{${node}}"} == 0"
          "${held "homelab_zpool_healthy{${node}}"} == 1"
          "ZFS pool {{ $labels.pool }} on {{ $labels.host }} has an uncleared non-ONLINE observation."
          { }
        )
        (storageAlert "HostZpoolDeviceErrors" "critical" "1m"
          "${held "homelab_zpool_vdev_errors{${node}}"} > 0"
          "${held "homelab_zpool_vdev_errors{${node}}"} == 0"
          "ZFS pool {{ $labels.pool }} device {{ $labels.vdev }} on {{ $labels.host }} has an uncleared {{ $labels.type }} error observation."
          { }
        )
        (storageAlert "HostZpoolScrubErrors" "critical" "0s"
          "${held "homelab_zpool_scrub_errors{${node}}"} > 0"
          "${held "homelab_zpool_scrub_errors{${node}}"} == 0"
          "The latest observed completed scrub of {{ $labels.pool }} on {{ $labels.host }} reported errors; a clean completed scrub is required to clear this fault."
          { }
        )
        (storageAlert "HostZpoolScrubOverdue" "warning" "1h"
          "time() - max_over_time(homelab_zpool_scrub_end_time_seconds{${node}}[3d]) > ${days 35}"
          "time() - max_over_time(homelab_zpool_scrub_end_time_seconds{${node}}[3d]) <= ${days 35}"
          "No completed scrub within 35 days is on record for ZFS pool {{ $labels.pool }} on {{ $labels.host }}."
          { }
        )
        (storageAlert "HostDiskSmartFailing" "critical" "0s" "${held "homelab_smart_healthy{${node}}"} == 0"
          "(${held "homelab_smart_healthy{${node}}"} == 1) and (${smartCollected "homelab_smart_healthy{${node}}"})"
          "Disk {{ $labels.disk }} ({{ $labels.id }}) on {{ $labels.host }} has an uncleared failing SMART health observation."
          { signal = "health"; }
        )
        (storageAlert "HostDiskSmartFailing" "critical" "0s"
          "${held "homelab_smart_nvme_critical_warning{${node}}"} > 0"
          "(${held "homelab_smart_nvme_critical_warning{${node}}"} == 0) and (${smartCollected "homelab_smart_nvme_critical_warning{${node}}"})"
          "Disk {{ $labels.disk }} ({{ $labels.id }}) on {{ $labels.host }} has an uncleared NVMe critical-warning observation."
          { signal = "nvme-critical-warning"; }
        )
      ]
      ++ map smartGrowth [
        "scsi_grown_defects"
        "ata_pending_sectors"
        "ata_reallocated_sectors"
        "nvme_media_errors"
      ]
      ++ map (
        mountpoint:
        alert "HostRequiredMountMissing" "critical" "2m"
          ''
            absent(node_filesystem_device_error{${node}, host=${quote host.name}, mountpoint=${quote mountpoint}})
            and on (job, host) (${hostReporting})
          ''
          "Required mount ${mountpoint} on ${host.name} is not observed by the reporting exporter."
          (hostLabels // { inherit mountpoint; })
      ) host.requiredMounts
      ++ [
        (
          let
            filesystems = ''${node}, host=${quote host.name}, mountpoint=~${
              quote (lib.concatMapStringsSep "|" lib.escapeRegex host.requiredMounts)
            }, fstype!~"fuse.*|tmpfs|ramfs|squashfs|overlay"'';
            deviceError = "node_filesystem_device_error{${filesystems}}";
            # Error text changes must not change the incident's identity.
            # Recovery needs matching capacity from the same successful scrape.
          in
          storageAlert "HostFilesystemStatsUnavailable" "critical" "2m"
            ''
              max without (device_error) (${deviceError} > 0)
              and on (job, host) (${hostReporting})
            ''
            ''
              max without (device_error) (
                (${deviceError} == 0)
                and (node_filesystem_size_bytes{${filesystems}} > 0)
                and (node_filesystem_avail_bytes{${filesystems}} >= 0)
                and (
                  timestamp(node_filesystem_size_bytes{${filesystems}})
                  == timestamp(${deviceError})
                )
                and (
                  timestamp(node_filesystem_avail_bytes{${filesystems}})
                  == timestamp(${deviceError})
                )
                and (
                  timestamp(${deviceError})
                  == on (job, host, instance) group_left()
                  timestamp(up{${node}, host=${quote host.name}})
                )
              )
              and on (job, host) (${hostReporting})
            ''
            "Required filesystem {{ $labels.mountpoint }} on {{ $labels.host }} has an uncleared statistics-read error; capacity is unknown until readable statistics return."
            { }
        )
      ]
      ++ bySeverity (
        severity:
        let
          filesystems = ''${node}, fstype!~"tmpfs|ramfs|squashfs|overlay"'';
          available = held "node_filesystem_avail_bytes{${filesystems}}";
          size = held "node_filesystem_size_bytes{${filesystems}}";
          threshold = if severity == "warning" then "0.10" else "0.05";
          percent = if severity == "warning" then "10" else "5";
        in
        storageAlert "HostFilesystemLowSpace" severity "30m" "(${available} / ${size}) < ${threshold}"
          ''
            ((${available} / ${size}) >= ${threshold})
            and (${size} > 0)
            and (
              tlast_over_time(node_filesystem_avail_bytes{${filesystems}}[2h])
              == tlast_over_time(node_filesystem_size_bytes{${filesystems}}[2h])
            )
          ''
          "Filesystem {{ $labels.mountpoint }} on {{ $labels.host }} has an uncleared below-${percent}% free-space observation."
          { }
      );

      hostServices = [
        (alert "HostSystemdUnitFailed" "warning" "10m" ''
          node_systemd_unit_state{${node}, state="failed"} == 1
        '' "Unit {{ $labels.name }} on {{ $labels.host }} has failed." { })
      ];

      endpoints = [
        (alert "EndpointDown" "critical" "5m" ''
          probe_success{job="blackbox"} == 0
        '' "{{ $labels.instance }} has not answered for 5 minutes." { })
      ]
      ++ bySeverity (
        severity:
        let
          remaining = days (if severity == "warning" then 21 else 14);
        in
        alert "CertificateExpiringSoon" severity "1h" ''
          label_replace(
            probe_ssl_earliest_cert_expiry{job="blackbox"} - time() < ${remaining},
            "certificate", "$1", "instance", "(.*)"
          )
          or
          label_replace(
            certmanager_certificate_expiration_timestamp_seconds{job="cert-manager"} - time() < ${remaining},
            "certificate", "$1", "name", "(.*)"
          )
        '' "Certificate {{ $labels.certificate }} expires in {{ $value | humanizeDuration }}." { }
      )
      ++ [
        (alert "CertificateNotReady" "warning" "1h" ''
          certmanager_certificate_ready_status{job="cert-manager", condition="False"} == 1
        '' "Certificate {{ $labels.namespace }}/{{ $labels.name }} is not ready." { })
      ];

      # Missing telemetry, in three layers: a source down or gone, a producer
      # stale behind a live exporter, and a declared item missing from a
      # fresh source. absent() keeps only equality matchers as labels, so
      # these rules set the labels that name the item.
      # Compound absent(comparison) has no labels; its host-pinned gate uses on().
      sourceDown =
        map (
          job:
          alert "TelemetrySourceDown" (if builtins.elem job coreJobs then "critical" else "warning") "5m"
            ''
              up{job=${quote job}} == 0 or absent(up{job=${quote job}})
            ''
            "Telemetry source ${job}{{ with $labels.instance }} ({{ . }}){{ end }} is not reporting."
            { inherit job; }
        ) clusterJobs
        ++ map (
          target:
          alert "TelemetrySourceDown" (if builtins.elem target.job coreJobs then "critical" else "warning")
            "5m"
            ''
              up{job=${quote target.job}, host=${quote host.name}} == 0
              or absent(up{job=${quote target.job}, host=${quote host.name}})
            ''
            "Host telemetry ${target.job} on ${host.name} is not reporting."
            (hostLabels // { inherit (target) job; })
        ) host.scrapeTargets;

      stale =
        file: bound:
        ''time() - node_textfile_mtime_seconds{${node}, file=~"(.*/)?${file}\\.prom"} > ${toString bound}'';
      absentFile =
        file:
        ''absent(node_textfile_mtime_seconds{${node}, host=${quote host.name}, file=~"(.*/)?${file}\\.prom"})'';
      staleness = [
        # Five missed 2-minute runs.
        (alert "HostZpoolStatusStale" "critical" "0s"
          ''
            (
              ${stale "zpool" 600}
              or node_textfile_scrape_error{${node}} == 1
              or ${absentFile "zpool"}
            )
            and on (job, host) (${hostReporting})
          ''
          "zpool.prom on ${host.name} is missing or older than 10 minutes, or a host textfile has a parse error."
          hostLabels
        )
        # Three missed 15-minute runs.
        (alert "HostSmartStatusStale" "critical" "0s" ''
          (${stale "smart" smartFreshness} or ${absentFile "smart"})
          and on (job, host) (${hostReporting})
        '' "smart.prom on ${host.name} is missing or older than 45 minutes." hostLabels)
      ]
      ++ map (
        pool:
        alert "HostZpoolMissing" "critical" "2m" ''
          absent(homelab_zpool_present{${node}, host=${quote host.name}, pool=${quote pool}} == 1)
          and on() (${hostReporting})
        '' "ZFS pool ${pool} is missing from zpool.prom on ${host.name}." (hostLabels // { inherit pool; })
      ) host.pools
      ++ [
        (alert "HostDiskTelemetryMissing" "critical" "20m"
          ''
            homelab_smart_device_up{${node}, host=${quote host.name}, disk!~${quote (lib.concatStringsSep "|" (map lib.escapeRegex (builtins.attrNames host.disks)))}} == 0
            and on (job, host) (${hostReporting})
          ''
          "Disk {{ $labels.disk }} ({{ $labels.id }}) on {{ $labels.host }} was not read in the last two SMART runs."
          hostLabels
        )
      ]
      ++ lib.mapAttrsToList (
        disk: path:
        alert "HostDiskTelemetryMissing" "critical" "20m"
          ''
            absent(homelab_smart_device_up{${node}, host=${quote host.name}, disk=${quote disk}} == 1)
            and on() (${hostReporting})
          ''
          "Disk ${disk} (${baseNameOf path}) on ${host.name} was not read in the last two SMART runs."
          (
            hostLabels
            // {
              inherit disk;
              id = baseNameOf path;
            }
          )
      ) host.disks;

      storage =
        bySeverity (
          severity:
          alert "MonitoringStorageLow" severity "5m" ''
            vm_free_disk_space_bytes{job="victoriametrics"} < ${gib (if severity == "warning" then 100 else 70)}
          '' "Metrics storage has {{ $value | humanize1024 }}B free; ingestion stops at 50 GiB." { }
        )
        ++ [
          (alert "MonitoringStorageGrowth" "warning" "30m" ''
            sum(vm_data_size_bytes{job="victoriametrics"}) > ${gib 20}
          '' "Metrics history is {{ $value | humanize1024 }}B, expected under 9 GiB." { })
        ];

      delivery = [
        (alert "AlertDeliveryFailing" "critical" "0s" ''
          sum by (integration) (
            increase_prometheus(alertmanager_notifications_failed_total{job="alertmanager", integration=~"pushover|telegram"}[15m])
          ) > 0
        '' "{{ $labels.integration }} notifications are failing." { })
      ];

      # Fires only while fresh telemetry is stored end to end: the store is
      # still writing, and at least one core source outside monitoring was
      # scraped in the last 180 s. Each core metric is written only by a
      # successful scrape, unlike `up`.
      watchdog = {
        alert = "Watchdog";
        expr = ''
          vector(1)
            and on() (sum(increase_prometheus(vm_rows_added_to_storage_total{job="victoriametrics"}[3m])) > 0)
            and on() (
              time() - max(
                  timestamp(kubelet_running_pods{job="kubelet"})
                or timestamp(machine_cpu_cores{job="cadvisor"})
                or timestamp(kube_node_info{job="kube-state-metrics"})
                or timestamp(node_time_seconds{job="host-node"})
              ) < 180
            )
        '';
        labels.severity = "none";
        annotations.summary = "Homelab monitoring heartbeat.";
      };

      # Recording rules that the vendored kubernetes-mixin dashboards read.
      # Keep the collector's cluster label for their cluster selectors.
      record = name: expr: {
        record = name;
        inherit expr;
      };
      activePods = ''max by (namespace, pod) (kube_pod_status_phase{${ksm}, phase=~"Pending|Running"} == 1)'';
      resource =
        kind: resourceName:
        record "cluster:namespace:pod_${resourceName}:active:kube_pod_container_resource_${kind}" ''
          kube_pod_container_resource_${kind}{${ksm}, resource=${quote resourceName}}
          * on (namespace, pod) group_left () ${activePods}
        '';
      dashboards = [
        (record "node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m" ''
          sum by (cluster, namespace, pod, container, node) (
            rate(container_cpu_usage_seconds_total{job="cadvisor", image!=""}[5m])
          )
        '')
        (resource "requests" "cpu")
        (resource "requests" "memory")
        (resource "limits" "cpu")
        (resource "limits" "memory")
      ];
    in
    {
      groups = lib.mapAttrsToList (name: rules: { inherit name rules; }) {
        workloads = workloads;
        gitops = gitops;
        host-storage = hostStorage;
        host-services = hostServices;
        endpoints = endpoints;
        missing-telemetry = sourceDown ++ staleness;
        monitoring-storage = storage;
        delivery = delivery;
        watchdog = [ watchdog ];
        dashboards = dashboards;
      };
    };

  # Native condition alerts send resolutions; new-error events do not imply
  # physical recovery when their observation window ends. Credentials remain
  # file paths, and all critical delivery bypasses Pushover quiet hours.
  alertmanagerFor =
    grafanaUrl:
    let
      file = name: "${credentialDirectory}/${name}";
      matcher = name: value: "${name}=${builtins.toJSON value}";
      # Priority 1 bypasses the owner's Pushover quiet hours; 0 respects them.
      pushover =
        priority:
        {
          user_key_file = file "pushover-user-key";
          token_file = file "pushover-token";
          priority = toString priority;
          send_resolved = true;
          title = ''{{ template "homelab.title" . }}'';
          message = ''{{ template "homelab.message" . }}'';
        }
        // lib.optionalAttrs (grafanaUrl != null) {
          url = grafanaUrl;
          url_title = "Grafana";
        };
      telegram = {
        bot_token_file = file "telegram-bot-token";
        chat_id_file = file "telegram-chat-id";
        send_resolved = true;
        # Plain text: no markup for label values to break.
        parse_mode = "";
        message = ''{{ template "homelab.telegram" . }}'';
      };
      hostTelemetryDependents = [
        "HostRequiredMountMissing"
        "HostSystemdUnitFailed"
        "HostZpoolStatusStale"
        "HostSmartStatusStale"
        "HostZpoolMissing"
        "HostDiskTelemetryMissing"
      ];
    in
    {
      config = {
        route = {
          receiver = "warning";
          group_by = [
            "alertname"
            "namespace"
            "host"
            "instance"
          ];
          group_wait = "30s";
          group_interval = "2m";
          repeat_interval = "24h";
          routes = [
            # The heartbeat, re-sent every 5 minutes while the Watchdog fires.
            {
              matchers = [ (matcher "alertname" "Watchdog") ];
              receiver = "heartbeat";
              group_wait = "0s";
              group_interval = "1m";
              repeat_interval = "5m";
              continue = false;
            }
            # Each failing channel is reported only through the other one.
            {
              matchers = [
                (matcher "alertname" "AlertDeliveryFailing")
                (matcher "integration" "pushover")
              ];
              receiver = "telegram-only";
              repeat_interval = "4h";
            }
            {
              matchers = [
                (matcher "alertname" "AlertDeliveryFailing")
                (matcher "integration" "telegram")
              ];
              receiver = "pushover-only";
              repeat_interval = "4h";
            }
            {
              matchers = [
                (matcher "alertname" "HostDiskSmartErrorsIncreasing")
                (matcher "severity" "warning")
              ];
              receiver = "warning-events";
            }
            {
              matchers = [ (matcher "severity" "critical") ];
              receiver = "critical";
              repeat_interval = "4h";
            }
          ];
        };

        # One receiver with both integrations keeps an alert on one route, so
        # grouping, repeats and resolutions stay in step across channels,
        # while Alertmanager still counts failures per integration.
        receivers = [
          {
            name = "heartbeat";
            # A resolved message would reach the ping URL and count as a ping.
            webhook_configs = [
              {
                url_file = file "heartbeat-url";
                send_resolved = false;
                max_alerts = 1;
              }
            ];
          }
          {
            name = "critical";
            pushover_configs = [ (pushover 1) ];
            telegram_configs = [ telegram ];
          }
          {
            name = "warning";
            pushover_configs = [ (pushover 0) ];
            telegram_configs = [ telegram ];
          }
          {
            name = "warning-events";
            pushover_configs = [ ((pushover 0) // { send_resolved = false; }) ];
            telegram_configs = [ (telegram // { send_resolved = false; }) ];
          }
          {
            name = "telegram-only";
            telegram_configs = [ telegram ];
          }
          {
            name = "pushover-only";
            pushover_configs = [ (pushover 1) ];
          }
        ];

        inhibit_rules = [
          # A critical alert hides the warning for the same object, such as
          # free space at 5 % versus 10 %.
          {
            source_matchers = [ (matcher "severity" "critical") ];
            target_matchers = [ (matcher "severity" "warning") ];
            equal = [
              "alertname"
              "namespace"
              "pod"
              "container"
              "host"
              "instance"
              "job"
              "mountpoint"
              "pool"
              "vdev"
              "disk"
              "certificate"
              "name"
            ];
          }
          # One cause, one alert: a silent host exporter hides what depends
          # on it, and a stale file hides its own missing items.
          {
            source_matchers = [
              (matcher "alertname" "TelemetrySourceDown")
              (matcher "job" "host-node")
            ];
            target_matchers = [
              "alertname=~${builtins.toJSON (builtins.concatStringsSep "|" hostTelemetryDependents)}"
            ];
            equal = [ "host" ];
          }
          {
            source_matchers = [ (matcher "alertname" "HostZpoolStatusStale") ];
            target_matchers = [ (matcher "alertname" "HostZpoolMissing") ];
            equal = [ "host" ];
          }
          {
            source_matchers = [ (matcher "alertname" "HostSmartStatusStale") ];
            target_matchers = [ (matcher "alertname" "HostDiskTelemetryMissing") ];
            equal = [ "host" ];
          }
          {
            source_matchers = [ (matcher "alertname" "KubePodCrashLooping") ];
            target_matchers = [ ''alertname=~"KubePodNotReady|KubeContainerRestarted"'' ];
            equal = [
              "namespace"
              "pod"
            ];
          }
        ];

        templates = [ "/etc/alertmanager/templates/*.tmpl" ];
      };

      # Messages carry only rule labels and annotations: names, hosts,
      # namespaces, severities and measured values.
      templates."homelab.tmpl" = ''
        {{ define "homelab.title" }}[{{ .Status | toUpper }}{{ if eq .Status "firing" }} {{ .CommonLabels.severity }}{{ end }}] {{ .CommonLabels.alertname }}{{ end }}
        {{ define "homelab.message" }}{{ range .Alerts }}{{ .Annotations.summary }}
        {{ end }}{{ end }}
        {{ define "homelab.telegram" }}{{ template "homelab.title" . }}
        {{ range .Alerts }}{{ .Annotations.summary }}
        {{ end }}${if grafanaUrl == null then "" else grafanaUrl}{{ end }}
      '';
    };

  ingressFrom = name: port: peers: {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = { inherit name namespace; };
    spec = {
      podSelector.matchLabels = labelsFor name;
      policyTypes = [ "Ingress" ];
      ingress = [
        {
          from = map (selector: { podSelector.matchLabels = selector; }) peers;
          ports = [
            {
              protocol = "TCP";
              inherit port;
            }
          ];
        }
      ];
    };
  };
in
{
  den.aspects.kubernetes.services.monitoring.alerting = {
    compute-resources =
      { cluster, ... }:
      let
        inherit (config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute)
          instance
          ;
        source = key: "monitoring--alertmanager-delivery--${key}";
        present = key: builtins.pathExists (inputs.self + "/.secrets/hosts/${instance}/${source key}.age");
      in
      {
        runtimeSecrets = builtins.listToAttrs (
          map (
            key:
            lib.nameValuePair (source key) {
              inherit namespace key;
              name = "alertmanager-delivery";
            }
          ) (lib.filter present deliveryKeys)
        );
      };

    k8s-manifests =
      {
        cluster,
        computeResources,
        charts,
        ...
      }:
      let
        host = inputs.self.nixosConfigurations.${cluster.hostName}.config.homelab.monitoring // {
          name = cluster.hostName;
        };
        grafanaUrl =
          if cluster.routes ? grafana then
            "https://${builtins.head cluster.routes.grafana.hostnames}"
          else
            null;
        grafanaPods = lib.optional (cluster.routes ? grafana) cluster.routes.grafana.backendPodSelector;
        nodeSelector."kubernetes.io/hostname" = computeResources.instance;
        rulesConfig = builtins.toJSON (rulesFor host);
        alertmanager = alertmanagerFor grafanaUrl;
        alertmanagerConfig = builtins.toJSON alertmanager.config;
        victoriametrics = "http://victoriametrics.${namespace}.svc:8428";
      in
      {
        applications.monitoring.objects = [
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "vmalert-rules";
              inherit namespace;
            };
            data."rules.json" = rulesConfig;
          }
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata = {
              name = "alertmanager-config";
              inherit namespace;
            };
            data = {
              "alertmanager.yaml" = alertmanagerConfig;
            }
            // alertmanager.templates;
          }
        ]
        ++ [
          (ingressFrom "vmalert" 8880 [ (labelsFor "victoriametrics") ])
          (ingressFrom "alertmanager" 9093 (
            [
              (labelsFor "vmalert")
              (labelsFor "victoriametrics")
            ]
            ++ grafanaPods
          ))
        ];
        applications.monitoring.helm.releases = {
          vmalert = {
            chart = charts.bjw-s-labs.app-template;
            values = {
              fullnameOverride = "vmalert";
              global.createDefaultServiceAccount = false;
              global.labels = labelsFor "vmalert";
              defaultPodOptions = {
                inherit nodeSelector;
                labels = labelsFor "vmalert";
                annotations."homelab.danielvicory/config-sha256" = builtins.hashString "sha256" rulesConfig;
                automountServiceAccountToken = false;
                enableServiceLinks = false;
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  seccompProfile.type = "RuntimeDefault";
                };
              };
              controllers.main = {
                type = "deployment";
                strategy = "Recreate";
                replicas = 1;
                containers.vmalert = {
                  image = images.vmalert // {
                    pullPolicy = "IfNotPresent";
                  };
                  args = [
                    "-datasource.url=${victoriametrics}"
                    # Remote state preserves each alert's `for` progress.
                    "-remoteWrite.url=${victoriametrics}"
                    "-remoteRead.url=${victoriametrics}"
                    "-notifier.url=http://alertmanager.${namespace}.svc:9093"
                    "-rule=/etc/vmalert/rules.json"
                    "-evaluationInterval=30s"
                    "-httpListenAddr=:8880"
                  ]
                  ++ lib.optional (grafanaUrl != null) "-external.url=${grafanaUrl}";
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                  probes.readiness = {
                    enabled = true;
                    custom = true;
                    spec = {
                      httpGet = {
                        path = "/health";
                        port = 8880;
                      };
                      periodSeconds = 10;
                    };
                  };
                  resources = {
                    requests = {
                      cpu = "25m";
                      memory = "64Mi";
                    };
                    limits = {
                      cpu = "250m";
                      memory = "256Mi";
                    };
                  };
                };
              };
              service.main = {
                controller = "main";
                extraSelectorLabels = labelsFor "vmalert";
                ports.http.port = 8880;
              };
              persistence.rules = {
                type = "configMap";
                name = "vmalert-rules";
                defaultMode = 420;
                globalMounts = [
                  {
                    path = "/etc/vmalert";
                    readOnly = true;
                  }
                ];
              };
            };
          };
          alertmanager = {
            chart = charts.bjw-s-labs.app-template;
            values = {
              fullnameOverride = "alertmanager";
              global.createDefaultServiceAccount = false;
              global.labels = labelsFor "alertmanager";
              defaultPodOptions = {
                inherit nodeSelector;
                labels = labelsFor "alertmanager";
                annotations."homelab.danielvicory/config-sha256" = builtins.hashString "sha256" (
                  alertmanagerConfig + alertmanager.templates."homelab.tmpl"
                );
                automountServiceAccountToken = false;
                enableServiceLinks = false;
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  seccompProfile.type = "RuntimeDefault";
                };
              };
              controllers.main = {
                type = "deployment";
                strategy = "Recreate";
                replicas = 1;
                containers.alertmanager = {
                  image = images.alertmanager // {
                    pullPolicy = "IfNotPresent";
                  };
                  args = [
                    "--config.file=/etc/alertmanager/config/alertmanager.yaml"
                    "--storage.path=/alertmanager"
                    "--web.listen-address=:9093"
                    # One replica: no gossip listener.
                    "--cluster.listen-address="
                  ];
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                  probes.readiness = {
                    enabled = true;
                    custom = true;
                    spec = {
                      httpGet = {
                        path = "/-/ready";
                        port = 9093;
                      };
                      periodSeconds = 10;
                    };
                  };
                  resources = {
                    requests = {
                      cpu = "25m";
                      memory = "48Mi";
                    };
                    limits = {
                      cpu = "250m";
                      memory = "128Mi";
                    };
                  };
                };
              };
              service.main = {
                controller = "main";
                extraSelectorLabels = labelsFor "alertmanager";
                ports.http.port = 9093;
              };
              persistence = {
                config = {
                  type = "configMap";
                  name = "alertmanager-config";
                  defaultMode = 420;
                  items = [
                    {
                      key = "alertmanager.yaml";
                      path = "alertmanager.yaml";
                    }
                  ];
                  globalMounts = [
                    {
                      path = "/etc/alertmanager/config";
                      readOnly = true;
                    }
                  ];
                };
                templates = {
                  type = "configMap";
                  name = "alertmanager-config";
                  defaultMode = 420;
                  items = [
                    {
                      key = "homelab.tmpl";
                      path = "homelab.tmpl";
                    }
                  ];
                  globalMounts = [
                    {
                      path = "/etc/alertmanager/templates";
                      readOnly = true;
                    }
                  ];
                };
                delivery = {
                  # Native secret persistence omits `optional`; a missing
                  # credential must fail only its channel, not Pod startup.
                  type = "custom";
                  volumeSpec.secret = {
                    secretName = "alertmanager-delivery";
                    optional = true;
                    defaultMode = 292;
                  };
                  globalMounts = [
                    {
                      path = credentialDirectory;
                      readOnly = true;
                    }
                  ];
                };
                storage = {
                  # Silences and the notification log are disposable.
                  type = "emptyDir";
                  sizeLimit = "64Mi";
                  globalMounts = [ { path = "/alertmanager"; } ];
                };
              };
            };
          };
        };
      };
  };
}
