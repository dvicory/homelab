# Unit tests for the rendered prod-home alert rules. vmalert-tool from the
# same VictoriaMetrics release as the pinned images evaluates the rule file
# that the vmalert ConfigMap carries, unchanged, against synthetic series.
#
# Alert cases pin a time bound from the fleet-monitoring spec: the alert is
# expected to fire by the bound and, where the spec says so, not before.
{
  lib,
  self,
  ...
}:
let
  hvn = self.nixosConfigurations.hvn-hyp1.config.homelab.monitoring;
  hostName = "hvn-hyp1";
  instance = builtins.head (map (target: target.address) hvn.scrapeTargets);
  # vmalert-tool starts every test at 2000-01-01T00:00:00Z.
  start = 946684800;
  gib = n: n * 1024 * 1024 * 1024;
  labelString =
    labels: lib.concatStringsSep "," (lib.mapAttrsToList (key: value: ''${key}="${value}"'') labels);
  series = name: labels: values: {
    series = "${name}{${labelString labels}}";
    inherit values;
  };
  nodeLabels = {
    job = "host-node";
    host = hostName;
    inherit instance;
  };
  ksm = {
    job = "kube-state-metrics";
  };
  alert = labels: summary: {
    exp_labels = labels;
    exp_annotations = { inherit summary; };
  };
  expect = evalTime: group: name: alerts: {
    eval_time = evalTime;
    groupname = group;
    alertname = name;
    exp_alerts = alerts;
  };
  # Fresh textfile modification times: each sample equals its own time.
  freshMtime =
    file:
    series "node_textfile_mtime_seconds" (
      nodeLabels // { file = "/run/host-telemetry/${file}"; }
    ) "${toString start}+30x200";
  allJobs = [
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
  upFor =
    jobs:
    map (
      job:
      series "up" {
        inherit job;
        instance = "${job}:1";
      } "1x200"
    ) jobs;
  upEverywhere = upFor allJobs ++ [ (series "up" nodeLabels "1x200") ];
  pod = name: {
    namespace = "jellyfin";
    pod = name;
  };
  container = name: pod name // { container = "jellyfin"; };

  tests = [
    {
      name = "the upstream pod CPU dashboard selects the cluster-labeled recording rule";
      interval = "30s";
      input_series = [
        (series "container_cpu_usage_seconds_total" (
          container "jellyfin-0"
          // {
            job = "cadvisor";
            cluster = "prod-home";
            node = "hvn-hyp1";
            image = "jellyfin";
          }
        ) "0+15x20")
      ];
      metricsql_expr_test = [
        {
          # k8s-resources-pod.json CPU Usage query, with dashboard variables resolved.
          expr = ''sum(max by (cluster, namespace, pod, container)(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m{namespace="jellyfin", pod="jellyfin-0", cluster="prod-home", container!=""})) by (container)'';
          eval_time = "10m";
          exp_samples = [
            {
              labels = ''{container="jellyfin"}'';
              value = 0.5;
            }
          ];
        }
      ];
    }
    {
      name = "a single OOM kill is critical within 5 minutes, even while Argo CD reports Healthy";
      interval = "30s";
      input_series = [
        (series "kube_pod_container_status_restarts_total" (ksm // container "jellyfin-0") "0x10 1x20")
        (series "kube_pod_container_status_last_terminated_reason" (
          ksm // container "jellyfin-0" // { reason = "OOMKilled"; }
        ) "_x10 1x20")
        (series "argocd_app_info" {
          job = "argocd";
          namespace = "argocd";
          name = "jellyfin";
          health_status = "Healthy";
          sync_status = "Synced";
        } "1x30")
      ];
      alert_rule_test = [
        (expect "5m" "workloads" "KubeContainerOOMKilled" [ ])
        (expect "6m" "workloads" "KubeContainerOOMKilled" [
          (alert (
            ksm // container "jellyfin-0" // { severity = "critical"; }
          ) "jellyfin/jellyfin-0 container jellyfin was OOMKilled and restarted.")
        ])
        (expect "6m" "workloads" "KubeContainerRestarted" [ ])
        (expect "6m" "gitops" "ArgoApplicationDegraded" [ ])
      ];
    }
    {
      name = "a restart for another reason is a warning";
      interval = "30s";
      input_series = [
        (series "kube_pod_container_status_restarts_total" (ksm // container "jellyfin-0") "0x10 1x20")
        (series "kube_pod_container_status_last_terminated_reason" (
          ksm // container "jellyfin-0" // { reason = "Error"; }
        ) "_x10 1x20")
      ];
      alert_rule_test = [
        (expect "6m" "workloads" "KubeContainerRestarted" [
          (alert (
            ksm // container "jellyfin-0" // { severity = "warning"; }
          ) "jellyfin/jellyfin-0 container jellyfin restarted.")
        ])
        (expect "6m" "workloads" "KubeContainerOOMKilled" [ ])
      ];
    }
    {
      name = "a crash loop fires at 15 minutes and not before";
      interval = "30s";
      input_series = [
        (series "kube_pod_container_status_waiting_reason" (
          ksm // container "jellyfin-0" // { reason = "CrashLoopBackOff"; }
        ) "1x60")
      ];
      alert_rule_test = [
        (expect "14m30s" "workloads" "KubePodCrashLooping" [ ])
        (expect "15m30s" "workloads" "KubePodCrashLooping" [
          (alert (
            container "jellyfin-0" // { severity = "critical"; }
          ) "jellyfin/jellyfin-0 container jellyfin is crash-looping.")
        ])
      ];
    }
    {
      name = "finished pods never count as not ready, and an eviction alerts once";
      interval = "1m";
      input_series = [
        # Evicted at 10m; it stays in phase Failed, with its container in
        # ContainerStatusUnknown, after its replacement is Ready.
        (series "kube_pod_status_phase" (ksm // pod "jellyfin-old" // { phase = "Running"; }) "1x9 0x300")
        (series "kube_pod_status_phase" (ksm // pod "jellyfin-old" // { phase = "Failed"; }) "0x9 1x300")
        (series "kube_pod_status_ready" (ksm // pod "jellyfin-old" // { condition = "true"; }) "1x9 0x300")
        (series "kube_pod_status_reason" (ksm // pod "jellyfin-old" // { reason = "Evicted"; }) "0x9 1x300")
        (series "kube_pod_container_status_waiting_reason" (
          ksm // container "jellyfin-old" // { reason = "ContainerStatusUnknown"; }
        ) "_x9 1x300")
        (series "kube_pod_status_phase" (ksm // pod "jellyfin-new" // { phase = "Running"; }) "_x9 1x300")
        (series "kube_pod_status_ready" (ksm // pod "jellyfin-new" // { condition = "true"; }) "_x9 1x300")
        # A Job pod that finished successfully.
        (series "kube_pod_status_phase" (ksm // pod "done" // { phase = "Succeeded"; }) "1x300")
        (series "kube_pod_status_ready" (ksm // pod "done" // { condition = "true"; }) "0x300")
      ];
      alert_rule_test = [
        (expect "12m" "workloads" "KubePodEvicted" [
          (alert (
            ksm
            // pod "jellyfin-old"
            // {
              reason = "Evicted";
              severity = "warning";
            }
          ) "jellyfin/jellyfin-old was evicted.")
        ])
        (expect "45m" "workloads" "KubePodEvicted" [ ])
        (expect "4h" "workloads" "KubePodEvicted" [ ])
        (expect "30m" "workloads" "KubePodNotReady" [ ])
        (expect "4h" "workloads" "KubePodNotReady" [ ])
      ];
    }
    {
      name = "a pod that stays not ready fires within 20 minutes";
      interval = "30s";
      input_series = [
        (series "kube_pod_status_phase" (ksm // pod "stuck" // { phase = "Pending"; }) "1x60")
        (series "kube_pod_status_ready" (ksm // pod "stuck" // { condition = "true"; }) "0x60")
      ];
      alert_rule_test = [
        (expect "14m30s" "workloads" "KubePodNotReady" [ ])
        (expect "15m30s" "workloads" "KubePodNotReady" [
          (alert (
            pod "stuck" // { severity = "critical"; }
          ) "jellyfin/stuck has not been ready for 15 minutes.")
        ])
      ];
    }
    {
      name = "only a terminal Job failure alerts";
      interval = "30s";
      input_series = [
        (series "kube_job_failed" (
          ksm
          // {
            namespace = "media";
            job_name = "failing";
            condition = "true";
          }
        ) "0x5 1x20")
        # The first pod fails, a retry succeeds.
        (series "kube_job_status_failed" (
          ksm
          // {
            namespace = "media";
            job_name = "retried";
          }
        ) "0x3 1x20")
        (series "kube_job_failed" (
          ksm
          // {
            namespace = "media";
            job_name = "retried";
            condition = "true";
          }
        ) "0x25")
        (series "kube_job_complete" (
          ksm
          // {
            namespace = "media";
            job_name = "retried";
            condition = "true";
          }
        ) "0x6 1x20")
      ];
      alert_rule_test = [
        (expect "2m" "workloads" "KubeJobFailed" [ ])
        (expect "4m" "workloads" "KubeJobFailed" [
          (alert (
            ksm
            // {
              namespace = "media";
              job_name = "failing";
              condition = "true";
              severity = "warning";
            }
          ) "Job media/failing failed.")
        ])
      ];
    }
    {
      name = "sustained CPU throttling of a limited container warns, and resolves when it stops";
      interval = "30s";
      input_series =
        lib.concatMap
          (
            {
              name,
              throttled,
              limit,
            }:
            let
              labels = {
                job = "cadvisor";
                namespace = "jellyfin";
                pod = "jellyfin-0";
                container = name;
              };
            in
            [
              (series "container_cpu_cfs_periods_total" labels "0+300x80")
              (series "container_cpu_cfs_throttled_periods_total" labels throttled)
            ]
            ++ lib.optional (limit != null) (
              series "kube_pod_container_resource_limits" (
                ksm
                // container "jellyfin-0"
                // {
                  container = name;
                  resource = "cpu";
                  unit = "core";
                }
              ) "${limit}x80"
            )
          )
          [
            # Throttled in 40 % of periods for 20 minutes, then not at all.
            {
              name = "jellyfin";
              throttled = "0+120x40 4800+0x40";
              limit = "2";
            }
            # 10 % stays below the bound.
            {
              name = "light";
              throttled = "0+30x80";
              limit = "1";
            }
            # Without a CPU limit the container is ignored.
            {
              name = "unlimited";
              throttled = "0+150x80";
              limit = null;
            }
          ];
      alert_rule_test = [
        (expect "14m" "workloads" "KubeContainerCPUThrottled" [ ])
        (expect "17m" "workloads" "KubeContainerCPUThrottled" [
          (alert (
            container "jellyfin-0" // { severity = "warning"; }
          ) "jellyfin/jellyfin-0 container jellyfin was CPU-throttled in 40% of its periods for 15 minutes.")
        ])
        (expect "30m" "workloads" "KubeContainerCPUThrottled" [ ])
      ];
    }
    {
      name = "a working set above 90 % of the memory limit warns after 10 minutes, and resolves";
      interval = "30s";
      input_series = [
        # 95 % of a 4 GiB limit for 20 minutes, then 2.5 GiB.
        (series "container_memory_working_set_bytes" (
          container "jellyfin-0"
          // {
            job = "cadvisor";
            image = "jellyfin";
          }
        ) "4080218931x40 2684354560x40")
        (series "kube_pod_container_resource_limits" (
          ksm
          // container "jellyfin-0"
          // {
            resource = "memory";
            unit = "byte";
          }
        ) "4294967296x80")
        # 80 % never warns.
        (series "container_memory_working_set_bytes" (
          pod "jellyfin-0"
          // {
            job = "cadvisor";
            container = "sidecar";
            image = "sidecar";
          }
        ) "3435973837x80")
        (series "kube_pod_container_resource_limits" (
          ksm
          // pod "jellyfin-0"
          // {
            container = "sidecar";
            resource = "memory";
            unit = "byte";
          }
        ) "4294967296x80")
      ];
      alert_rule_test = [
        (expect "9m" "workloads" "KubeContainerMemoryNearLimit" [ ])
        (expect "11m" "workloads" "KubeContainerMemoryNearLimit" [
          (alert (
            container "jellyfin-0" // { severity = "warning"; }
          ) "jellyfin/jellyfin-0 container jellyfin has used 95% of its memory limit for 10 minutes.")
        ])
        (expect "25m" "workloads" "KubeContainerMemoryNearLimit" [ ])
      ];
    }
    {
      name = "GitOps: a 25-minute sync does not alert; a stuck one does within 40 minutes";
      interval = "30s";
      input_series = [
        (series "argocd_app_info" {
          job = "argocd";
          namespace = "argocd";
          name = "routine";
          health_status = "Healthy";
          sync_status = "OutOfSync";
        } "1x50")
        (series "argocd_app_info" {
          job = "argocd";
          namespace = "argocd";
          name = "stuck";
          health_status = "Healthy";
          sync_status = "OutOfSync";
        } "1x100")
        (series "argocd_app_info" {
          job = "argocd";
          namespace = "argocd";
          name = "broken";
          health_status = "Degraded";
          sync_status = "Synced";
        } "1x100")
        (series "argocd_app_info" {
          job = "argocd";
          namespace = "argocd";
          name = "apps";
          health_status = "Degraded";
          sync_status = "Synced";
        } "1x100")
      ];
      alert_rule_test = [
        (expect "25m" "gitops" "ArgoApplicationOutOfSync" [ ])
        (expect "31m" "gitops" "ArgoApplicationOutOfSync" [
          (alert {
            namespace = "argocd";
            name = "stuck";
            severity = "warning";
          } "Argo CD Application stuck has been out of sync for 30 minutes.")
        ])
        (expect "14m30s" "gitops" "ArgoApplicationDegraded" [ ])
        # The root Application only mirrors its children.
        (expect "16m" "gitops" "ArgoApplicationDegraded" [
          (alert {
            namespace = "argocd";
            name = "broken";
            severity = "critical";
          } "Argo CD Application broken is degraded or cannot compare its source.")
        ])
      ];
    }
    {
      name = "host storage: an absent required mount, and low free space";
      interval = "30s";
      input_series = upEverywhere ++ [
        (series "node_filesystem_size_bytes" (
          nodeLabels
          // {
            mountpoint = "/mnt/storage-clear/media4";
            fstype = "xfs";
          }
        ) "100x80")
        (series "node_filesystem_avail_bytes" (
          nodeLabels
          // {
            mountpoint = "/mnt/storage-clear/media4";
            fstype = "xfs";
          }
        ) "8x80")
        (series "node_filesystem_size_bytes" (
          nodeLabels
          // {
            mountpoint = "/persist";
            fstype = "zfs";
          }
        ) "100x80")
        (series "node_filesystem_avail_bytes" (
          nodeLabels
          // {
            mountpoint = "/persist";
            fstype = "zfs";
          }
        ) "4x80")
      ];
      alert_rule_test = [
        (expect "1m30s" "host-storage" "HostRequiredMountMissing" [ ])
        (expect "3m" "host-storage" "HostRequiredMountMissing" [
          (alert {
            job = "host-node";
            host = hostName;
            mountpoint = "/srv/media/data";
            severity = "critical";
          } "Required mount /srv/media/data on ${hostName} is not mounted.")
        ])
        (expect "29m" "host-storage" "HostFilesystemLowSpace" [ ])
        (expect "31m" "host-storage" "HostFilesystemLowSpace" [
          (alert (
            nodeLabels
            // {
              mountpoint = "/mnt/storage-clear/media4";
              fstype = "xfs";
              severity = "warning";
            }
          ) "/mnt/storage-clear/media4 on ${hostName} has 8% free.")
          (alert (
            nodeLabels
            // {
              mountpoint = "/persist";
              fstype = "zfs";
              severity = "warning";
            }
          ) "/persist on ${hostName} has 4% free.")
          (alert (
            nodeLabels
            // {
              mountpoint = "/persist";
              fstype = "zfs";
              severity = "critical";
            }
          ) "/persist on ${hostName} has 4% free.")
        ])
      ];
    }
    {
      name = "a missing host source fires, and a firing pool alert holds while it is gone";
      interval = "30s";
      input_series = upFor allJobs ++ [
        (series "up" nodeLabels "1x10 0x200")
        (series "homelab_zpool_healthy" (nodeLabels // { pool = "rpool"; }) "0x10")
      ];
      alert_rule_test = [
        (expect "4m" "host-storage" "HostZpoolUnhealthy" [
          (alert (
            nodeLabels
            // {
              pool = "rpool";
              severity = "critical";
            }
          ) "ZFS pool rpool on ${hostName} is not ONLINE.")
        ])
        (expect "11m" "missing-telemetry" "TelemetrySourceDown" [
          (alert (
            nodeLabels // { severity = "critical"; }
          ) "Host telemetry host-node on ${hostName} is not reporting.")
        ])
        (expect "60m" "host-storage" "HostZpoolUnhealthy" [
          (alert (
            nodeLabels
            // {
              pool = "rpool";
              severity = "critical";
            }
          ) "ZFS pool rpool on ${hostName} is not ONLINE.")
        ])
      ];
    }
    {
      name = "a scrape job that vanishes from discovery fires through absent(up)";
      interval = "30s";
      input_series = upFor (lib.remove "cadvisor" allJobs) ++ [ (series "up" nodeLabels "1x200") ];
      alert_rule_test = [
        (expect "6m" "missing-telemetry" "TelemetrySourceDown" [
          (alert {
            job = "cadvisor";
            severity = "critical";
          } "Telemetry source cadvisor is not reporting.")
        ])
      ];
    }
    {
      name = "stale and incomplete textfile producers behind a live exporter";
      interval = "30s";
      input_series =
        upEverywhere
        ++ [
          # zpool.prom stops refreshing at the start; smart.prom stays fresh.
          (series "node_textfile_mtime_seconds" (
            nodeLabels // { file = "/run/host-telemetry/zpool.prom"; }
          ) "${toString start}x200")
          (freshMtime "smart.prom")
          (series "node_textfile_scrape_error" nodeLabels "0x200")
          (series "homelab_zpool_present" (nodeLabels // { pool = "rpool"; }) "1x200")
        ]
        ++ lib.mapAttrsToList (
          disk: path:
          series "homelab_smart_device_up" (
            nodeLabels
            // {
              inherit disk;
              id = baseNameOf path;
            }
          ) (if disk == "media4" then "0x200" else "1x200")
        ) (removeAttrs hvn.disks [ "spare-c" ]);
      alert_rule_test = [
        (expect "9m30s" "missing-telemetry" "HostZpoolStatusStale" [ ])
        (expect "10m30s" "missing-telemetry" "HostZpoolStatusStale" [
          (alert (
            nodeLabels
            // {
              file = "/run/host-telemetry/zpool.prom";
              severity = "critical";
            }
          ) "zpool.prom on ${hostName} has not been refreshed for 10 minutes.")
        ])
        (expect "19m" "missing-telemetry" "HostDiskTelemetryMissing" [ ])
        (expect "21m" "missing-telemetry" "HostDiskTelemetryMissing" [
          (alert
            {
              host = hostName;
              disk = "media4";
              id = baseNameOf hvn.disks.media4;
              severity = "critical";
            }
            "Disk media4 (${baseNameOf hvn.disks.media4}) on ${hostName} was not read in the last two SMART runs."
          )
          (alert
            {
              host = hostName;
              disk = "spare-c";
              id = baseNameOf hvn.disks.spare-c;
              severity = "critical";
            }
            "Disk spare-c (${baseNameOf hvn.disks.spare-c}) on ${hostName} was not read in the last two SMART runs."
          )
        ])
        (expect "21m" "missing-telemetry" "HostSmartStatusStale" [ ])
      ];
    }
    {
      name = "a textfile scrape error, a pool missing from a fresh zpool.prom, and a stale smart.prom";
      interval = "30s";
      input_series = upEverywhere ++ [
        (freshMtime "zpool.prom")
        (series "node_textfile_mtime_seconds" (
          nodeLabels // { file = "/run/host-telemetry/smart.prom"; }
        ) "${toString start}x200")
        (series "node_textfile_scrape_error" nodeLabels "0x4 1x200")
      ];
      alert_rule_test = [
        (expect "3m" "missing-telemetry" "HostZpoolMissing" [
          (alert {
            host = hostName;
            pool = "rpool";
            severity = "critical";
          } "ZFS pool rpool is missing from zpool.prom on ${hostName}.")
        ])
        (expect "3m" "missing-telemetry" "HostZpoolStatusStale" [
          (alert (
            nodeLabels // { severity = "critical"; }
          ) "zpool.prom on ${hostName} has not been refreshed for 10 minutes.")
        ])
        (expect "44m" "missing-telemetry" "HostSmartStatusStale" [ ])
        (expect "46m" "missing-telemetry" "HostSmartStatusStale" [
          (alert (
            nodeLabels
            // {
              file = "/run/host-telemetry/smart.prom";
              severity = "critical";
            }
          ) "smart.prom on ${hostName} has not been refreshed for 45 minutes.")
        ])
      ];
    }
    {
      name = "metrics storage: free space before the floor, and unexpected growth";
      interval = "30s";
      input_series = [
        (series "vm_free_disk_space_bytes" {
          job = "victoriametrics";
          path = "/storage";
        } "${toString (gib 90)}x20 ${toString (gib 60)}x40")
        (series "vm_data_size_bytes" {
          job = "victoriametrics";
          type = "indexdb/file";
        } "${toString (gib 5)}x80")
        (series "vm_data_size_bytes" {
          job = "victoriametrics";
          type = "storage/big";
        } "${toString (gib 16)}x80")
      ];
      alert_rule_test = [
        (expect "6m" "monitoring-storage" "MonitoringStorageLow" [
          (alert {
            job = "victoriametrics";
            path = "/storage";
            severity = "warning";
          } "Metrics storage has 90GiB free; ingestion stops at 50 GiB.")
        ])
        (expect "17m" "monitoring-storage" "MonitoringStorageLow" [
          (alert {
            job = "victoriametrics";
            path = "/storage";
            severity = "warning";
          } "Metrics storage has 60GiB free; ingestion stops at 50 GiB.")
          (alert {
            job = "victoriametrics";
            path = "/storage";
            severity = "critical";
          } "Metrics storage has 60GiB free; ingestion stops at 50 GiB.")
        ])
        (expect "31m" "monitoring-storage" "MonitoringStorageGrowth" [
          (alert { severity = "warning"; } "Metrics history is 21GiB, expected under 9 GiB.")
        ])
      ];
    }
    {
      name = "Watchdog: fires while the store writes and a core source is fresh";
      interval = "30s";
      input_series = [
        (series "vm_rows_added_to_storage_total" { job = "victoriametrics"; } "0+100x40")
        (series "kubelet_running_pods" { job = "kubelet"; } "5x40")
      ];
      alert_rule_test = [
        (expect "5m" "watchdog" "Watchdog" [
          (alert { severity = "none"; } "Homelab monitoring heartbeat.")
        ])
      ];
    }
    {
      name = "Watchdog: stops within 3.5 minutes once the store stops writing";
      interval = "30s";
      input_series = [
        (series "vm_rows_added_to_storage_total" { job = "victoriametrics"; } "0+100x10 1000x30")
        (series "kubelet_running_pods" { job = "kubelet"; } "5x40")
        (series "machine_cpu_cores" { job = "cadvisor"; } "12x40")
        (series "kube_node_info" { job = "kube-state-metrics"; } "1x40")
        (series "node_time_seconds" { job = "host-node"; } "1x40")
      ];
      alert_rule_test = [
        (expect "4m" "watchdog" "Watchdog" [
          (alert { severity = "none"; } "Homelab monitoring heartbeat.")
        ])
        (expect "8m30s" "watchdog" "Watchdog" [ ])
      ];
    }
    {
      name = "Watchdog: stops when every core source is stale, keeps firing with one stale";
      interval = "30s";
      input_series = [
        (series "vm_rows_added_to_storage_total" { job = "victoriametrics"; } "0+100x60")
        # All four core sources stop at 5m.
        (series "kubelet_running_pods" {
          job = "kubelet";
          case = "all";
        } "5x10")
        (series "machine_cpu_cores" {
          job = "cadvisor";
          case = "all";
        } "12x10")
        (series "kube_node_info" {
          job = "kube-state-metrics";
          case = "all";
        } "1x10")
        (series "node_time_seconds" {
          job = "host-node";
          case = "all";
        } "1x10")
      ];
      alert_rule_test = [
        (expect "4m" "watchdog" "Watchdog" [
          (alert { severity = "none"; } "Homelab monitoring heartbeat.")
        ])
        (expect "12m" "watchdog" "Watchdog" [ ])
      ];
    }
    {
      name = "Watchdog: one stale core source does not stop the heartbeat";
      interval = "30s";
      input_series = [
        (series "vm_rows_added_to_storage_total" { job = "victoriametrics"; } "0+100x60")
        (series "kubelet_running_pods" { job = "kubelet"; } "5x10")
        (series "machine_cpu_cores" { job = "cadvisor"; } "12x60")
        (series "kube_node_info" { job = "kube-state-metrics"; } "1x60")
        (series "node_time_seconds" { job = "host-node"; } "1x60")
      ];
      alert_rule_test = [
        (expect "12m" "watchdog" "Watchdog" [
          (alert { severity = "none"; } "Homelab monitoring heartbeat.")
        ])
      ];
    }
    {
      name = "a failing channel raises AlertDeliveryFailing with its integration";
      interval = "30s";
      input_series = [
        (series "alertmanager_notifications_failed_total" {
          job = "alertmanager";
          integration = "pushover";
        } "0x5 1x20")
        (series "alertmanager_notifications_failed_total" {
          job = "alertmanager";
          integration = "telegram";
        } "0x25")
      ];
      alert_rule_test = [
        (expect "4m" "delivery" "AlertDeliveryFailing" [
          (alert {
            integration = "pushover";
            severity = "critical";
          } "pushover notifications are failing.")
        ])
      ];
    }
    {
      name = "endpoints: a failing probe fires after 5 minutes";
      interval = "30s";
      input_series = [
        (series "probe_success" {
          job = "blackbox";
          route = "jellyfin";
          instance = "jellyfin.example.test";
        } "0x30")
      ];
      alert_rule_test = [
        (expect "4m30s" "endpoints" "EndpointDown" [ ])
        (expect "5m30s" "endpoints" "EndpointDown" [
          (alert {
            job = "blackbox";
            route = "jellyfin";
            instance = "jellyfin.example.test";
            severity = "critical";
          } "jellyfin.example.test has not answered for 5 minutes.")
        ])
      ];
    }
  ];
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      objects = self.nixidyEnvs.${system}.prod-home.config.applications.monitoring.objects;
      data =
        objects: name:
        (lib.findFirst (
          object: object.kind == "ConfigMap" && object.metadata.name == name
        ) (throw "monitoring ConfigMap ${name} is not rendered") objects).data;
      rules = pkgs.writeText "rules.json" (data objects "vmalert-rules")."rules.json";
      testFile = pkgs.writeText "tests.json" (
        builtins.toJSON {
          rule_files = [ "rules.json" ];
          evaluation_interval = "30s";
          inherit tests;
        }
      );
      addedMount = "/srv/staged-mount";
      retiredMount = "/srv/media/data";
      withoutRetired = lib.remove retiredMount hvn.requiredMounts;
      mountStages =
        map
          (
            stage:
            let
              # Render the production aspect with each rollout's host expectations.
              aspect = import ../den/aspects/kubernetes/services/monitoring/alerting.nix {
                inherit lib;
                config = { };
                inputs.self.nixosConfigurations.${hostName}.config.homelab.monitoring = hvn // {
                  requiredMounts = stage.expected;
                };
              };
              stagedObjects =
                (aspect.den.aspects.kubernetes.services.monitoring.alerting.k8s-manifests {
                  cluster = {
                    inherit hostName;
                    routes = { };
                  };
                  computeResources.instance = "compute-1";
                }).applications.monitoring.objects;
              stagedRules = pkgs.writeText "staged-rules.json" (data stagedObjects "vmalert-rules")."rules.json";
              stagedTests = pkgs.writeText "staged-tests.json" (
                builtins.toJSON {
                  rule_files = [ "rules.json" ];
                  evaluation_interval = "30s";
                  tests = [
                    {
                      name = stage.name;
                      interval = "30s";
                      input_series =
                        map (
                          mountpoint: series "node_filesystem_size_bytes" (nodeLabels // { inherit mountpoint; }) "100x40"
                        ) stage.present
                        ++ lib.optional stage.recovers (
                          series "node_filesystem_size_bytes" (nodeLabels // { mountpoint = addedMount; }) "_x8 100x32"
                        );
                      alert_rule_test = [
                        (expect "1m30s" "host-storage" "HostRequiredMountMissing" [ ])
                        (expect "3m" "host-storage" "HostRequiredMountMissing" (
                          map (
                            mountpoint:
                            alert {
                              job = "host-node";
                              host = hostName;
                              inherit mountpoint;
                              severity = "critical";
                            } "Required mount ${mountpoint} on ${hostName} is not mounted."
                          ) stage.missing
                        ))
                        (expect "6m" "host-storage" "HostRequiredMountMissing" [ ])
                      ];
                    }
                  ];
                }
              );
            in
            ''
              cp ${stagedRules} rules.json
              cp ${stagedTests} tests.json
              vmalert-tool unittest --files=tests.json
            ''
          )
          [
            {
              name = "host-first addition is observed before it becomes required";
              expected = hvn.requiredMounts;
              present = hvn.requiredMounts ++ [ addedMount ];
              missing = [ ];
              recovers = false;
            }
            {
              name = "a newly expected but missing mount fires and resolves on observation";
              expected = hvn.requiredMounts ++ [ addedMount ];
              present = hvn.requiredMounts;
              missing = [ addedMount ];
              recovers = true;
            }
            {
              name = "monitor-first retirement permits the mount to disappear";
              expected = withoutRetired;
              present = withoutRetired;
              missing = [ ];
              recovers = false;
            }
          ];
    in
    {
      checks.monitoring-rules =
        pkgs.runCommand "monitoring-rules"
          {
            nativeBuildInputs = [ pkgs.victoriametrics ];
            # vmalert-tool serves its in-process store on loopback.
            __darwinAllowLocalNetworking = true;
          }
          ''
            cp ${rules} rules.json
            cp ${testFile} tests.json
            chmod u+w rules.json tests.json
            vmalert-tool unittest --files=tests.json
            ${lib.concatStringsSep "\n" mountStages}
            touch $out
          '';
    };
}
