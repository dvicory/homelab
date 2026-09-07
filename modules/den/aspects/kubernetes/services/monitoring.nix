{
  den.aspects.kubernetes.services.monitoring.k8s-manifests =
    { charts, cluster, lib, prometheus-targets ? [ ], ... }:
    let
      cfg = cluster.settings.kubernetes.services.monitoring;
      route = cluster.routes.grafana;
      retained = { "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false"; };
      nodeSelector = { "kubernetes.io/hostname" = cluster.nodeName; };
      resources = memory: {
        requests = { cpu = "50m"; inherit memory; };
        limits = { cpu = "2"; inherit memory; };
      };
      securityContext = uid: {
        runAsNonRoot = true;
        runAsUser = uid;
        runAsGroup = uid;
        fsGroup = uid;
        fsGroupChangePolicy = "OnRootMismatch";
      };
      disks = {
        prometheus = { size = "20Gi"; claim = "prometheus-data-prometheus-monitoring-prometheus-0"; };
        alertmanager = { size = "1Gi"; claim = "alertmanager-data-alertmanager-monitoring-alertmanager-0"; };
        grafana = { size = "2Gi"; claim = "grafana-data"; };
        loki = { size = "20Gi"; claim = "loki-data"; };
      };
      storage = name: {
        volumeClaimTemplate = {
          metadata = { name = "${name}-data"; annotations = retained; };
          spec = {
            storageClassName = "";
            accessModes = [ "ReadWriteOnce" ];
            volumeName = "monitoring-${name}";
            resources.requests.storage = disks.${name}.size;
          };
        };
      };
      scrapes = lib.concatMap (target: map (exporter: {
        job = exporter.job;
        address = "${target.ip}:${toString exporter.port}";
        labels = { inherit (target) hostname; exporter = exporter.job; };
      }) target.exporters) prometheus-targets;
      alert = name: expression: duration: summary: description: {
        alert = name;
        expr = expression;
        "for" = duration;
        labels.severity = "warning";
        annotations = { inherit summary description; };
      };
      recoveryRules = [
        (alert "RecoveryMetricsMissing" ''absent(homelab_recovery_last_attempt_success{recovery_set="household"}) or absent(homelab_recovery_last_success_timestamp_seconds{recovery_set="household"})'' "15m"
          "Recovery reporting missing: household" "Check the recovery command, its atomic textfile publication and the node exporter scrape target. Missing reporting is not a successful recovery point.")
        (alert "RecoveryPointStale" ''time() - homelab_recovery_last_success_timestamp_seconds{recovery_set="household"} > ${toString cfg.recoveryMaxAgeSeconds}'' "15m"
          "No recent complete recovery point: household" "Inspect the last export and retained destination, then complete a new application-consistent export. Same-host exports are not independent backups.")
        (alert "RecoveryAttemptFailed" ''homelab_recovery_last_attempt_success{recovery_set="household"} == 0'' "1m"
          "Recovery attempt failed: household" "Inspect the recovery command output and destination capacity; correct the failure and rerun the complete recovery set.")
      ];
    in
    {
      applications = {
        monitoring-retained = {
          namespace = "monitoring";
          objects = [ {
            apiVersion = "v1";
            kind = "Namespace";
            metadata = { name = "monitoring"; annotations = retained; };
          } ] ++ lib.concatLists (lib.mapAttrsToList (name: disk: [
            {
              apiVersion = "v1";
              kind = "PersistentVolume";
              metadata = { name = "monitoring-${name}"; annotations = retained; };
              spec = {
                capacity.storage = disk.size;
                volumeMode = "Filesystem";
                accessModes = [ "ReadWriteOnce" ];
                persistentVolumeReclaimPolicy = "Retain";
                storageClassName = "";
                local.path = "${cluster.storageRoot}/monitoring/${name}";
                claimRef = { namespace = "monitoring"; name = disk.claim; };
                nodeAffinity.required.nodeSelectorTerms = [ {
                  matchExpressions = [ { key = "kubernetes.io/hostname"; operator = "In"; values = [ cluster.nodeName ]; } ];
                } ];
              };
            }
            {
              apiVersion = "v1";
              kind = "PersistentVolumeClaim";
              metadata = { name = disk.claim; namespace = "monitoring"; annotations = retained; };
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                storageClassName = "";
                volumeName = "monitoring-${name}";
                resources.requests.storage = disk.size;
              };
            }
          ]) disks);
        };
        monitoring = {
          namespace = "monitoring";
          syncPolicy.syncOptions.serverSideApply = true;
          helm.releases.monitoring = {
            chart = charts.prometheus-community.kube-prometheus-stack;
            values = {
              fullnameOverride = "monitoring";
              crds.enabled = true;
              nodeExporter.enabled = false;
              kubeStateMetrics.enabled = true;
              "kube-state-metrics".image.tag = "v2.20.0";
              kubeControllerManager.enabled = false;
              kubeScheduler.enabled = false;
              kubeProxy.enabled = false;
              kubeEtcd.enabled = false;
              prometheusOperator = {
                resources = resources "256Mi";
                prometheusConfigReloader.resources = resources "64Mi";
              };
              "kube-state-metrics".resources = resources "128Mi";
              prometheus.prometheusSpec = {
                image.tag = "v3.14.0-distroless";
                replicas = 1;
                retention = "7d";
                retentionSize = "15GB";
                resources = resources "2Gi";
                inherit nodeSelector;
                securityContext = securityContext 65534;
                storageSpec = storage "prometheus";
                persistentVolumeClaimRetentionPolicy = { whenDeleted = "Retain"; whenScaled = "Retain"; };
                serviceMonitorSelectorNilUsesHelmValues = false;
                podMonitorSelectorNilUsesHelmValues = false;
                ruleSelectorNilUsesHelmValues = false;
                additionalScrapeConfigs = lib.mapAttrsToList (job_name: targets: {
                  inherit job_name;
                  scrape_interval = "30s";
                  static_configs = map (target: { targets = [ target.address ]; inherit (target) labels; }) targets;
                }) (lib.groupBy (target: target.job) scrapes);
              };
              alertmanager = {
                config = {
                  global.resolve_timeout = "5m";
                  route = {
                    receiver = "operator";
                    group_by = [ "alertname" "namespace" "recovery_set" ];
                    group_wait = "10s";
                    group_interval = "1m";
                    repeat_interval = "4h";
                  };
                  receivers = [ ({ name = "operator"; } // lib.optionalAttrs (cfg.webhookURL != null) {
                    webhook_configs = [ { url = cfg.webhookURL; send_resolved = true; } ];
                  }) ];
                };
                alertmanagerSpec = {
                  replicas = 1;
                  image.tag = "v0.34.0";
                  retention = "48h";
                  resources = resources "128Mi";
                  inherit nodeSelector;
                  securityContext = securityContext 65534;
                  storage = storage "alertmanager";
                  secrets = cfg.alertmanagerSecretMounts;
                  persistentVolumeClaimRetentionPolicy = { whenDeleted = "Retain"; whenScaled = "Retain"; };
                  useExistingSecret = cfg.alertmanagerConfigSecret != null;
                } // lib.optionalAttrs (cfg.alertmanagerConfigSecret != null) {
                  configSecret = cfg.alertmanagerConfigSecret;
                };
              };
              grafana = {
                enabled = true;
                image.tag = "13.2.0";
                fullnameOverride = "monitoring-grafana";
                replicas = 1;
                deploymentStrategy.type = "Recreate";
                inherit nodeSelector;
                securityContext = securityContext 472;
                initChownData.enabled = false;
                resources = resources "384Mi";
                persistence = { enabled = true; existingClaim = "grafana-data"; };
                admin = { existingSecret = "grafana-admin"; userKey = "admin-user"; passwordKey = "admin-password"; };
                service = { type = "ClusterIP"; port = 80; };
                "grafana.ini" = {
                  server = {
                    domain = builtins.head route.hostnames;
                    root_url = "https://${builtins.head route.hostnames}${route.pathPrefix}";
                    serve_from_sub_path = route.pathPrefix != "/";
                  };
                  analytics = { reporting_enabled = false; check_for_updates = false; };
                  "auth.anonymous".enabled = false;
                };
                sidecar.resources = resources "64Mi";
                additionalDataSources = [ {
                  name = "Loki";
                  type = "loki";
                  access = "proxy";
                  url = "http://loki.monitoring.svc:3100";
                } ];
              };
              additionalPrometheusRulesMap.household.groups = [ {
                name = "homelab.household";
                rules = [
                  (alert "ServiceUnavailable" ''kube_deployment_status_replicas_available{namespace=~"jellyfin|immich|media|identity|monitoring"} < kube_deployment_spec_replicas{namespace=~"jellyfin|immich|media|identity|monitoring"}'' "5m"
                    "Deployment unavailable: {{ $labels.namespace }}/{{ $labels.deployment }}" "Inspect deployment conditions, pod probes, events, runtime Secrets and retained volume bindings.")
                  (alert "StatefulServiceUnavailable" ''kube_statefulset_status_replicas_ready{namespace=~"immich|monitoring|identity"} < kube_statefulset_replicas{namespace=~"immich|monitoring|identity"}'' "5m"
                    "Stateful service unavailable: {{ $labels.namespace }}/{{ $labels.statefulset }}" "Inspect readiness, storage mounts and runtime credentials before restarting a stateful writer.")
                  (alert "MetricsTargetUnavailable" "up == 0" "5m"
                    "Metrics target unavailable: {{ $labels.job }} / {{ $labels.instance }}" "Inspect the exporter, private network path and Prometheus target error; missing metrics do not indicate health.")
                  (alert "MetricsCollectionMissing" "absent_over_time(up[15m])" "5m"
                    "All metrics collection targets are missing" "Inspect Prometheus target discovery and the private scrape path; an absent target set is not healthy.")
                  (alert "ClusterInventoryMissing" "absent_over_time(kube_node_info[15m])" "5m"
                    "Kubernetes inventory metrics are missing" "Check kube-state-metrics and its ServiceMonitor before trusting workload availability panels.")
                  (alert "PersistentStoragePressure" "kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.15" "10m"
                    "Persistent volume low on space: {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }}" "Inspect the owning workload and retained filesystem. Reduce retention or increase capacity; do not remove household data to make room for monitoring.")
                  (alert "NodeStoragePressure" ''node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|overlay|squashfs"} / node_filesystem_size_bytes < 0.15'' "10m"
                    "Node filesystem low on space: {{ $labels.hostname }} {{ $labels.mountpoint }}" "Check shared filesystem usage and recovery destination capacity; local PV capacity declarations are not filesystem quotas.")
                ] ++ recoveryRules;
              } ];
            };
          };
        };
        loki = {
          namespace = "monitoring";
          helm.releases.loki = {
            chart = charts.grafana.loki;
            extraOpts = [
              "--api-versions"
              "monitoring.coreos.com/v1/ServiceMonitor"
            ];
            values = {
              fullnameOverride = "loki";
              deploymentMode = "SingleBinary";
              loki = {
                image.tag = "3.6.11";
                auth_enabled = false;
                commonConfig.replication_factor = 1;
                storage.type = "filesystem";
                podSecurityContext = securityContext 10001;
                schemaConfig.configs = [ {
                  from = "2024-04-01";
                  store = "tsdb";
                  object_store = "filesystem";
                  schema = "v13";
                  index = { prefix = "index_"; period = "24h"; };
                } ];
                limits_config = {
                  retention_period = "72h";
                  ingestion_rate_mb = 1;
                  ingestion_burst_size_mb = 2;
                  max_query_parallelism = 2;
                  max_query_length = "72h";
                };
                compactor = {
                  working_directory = "/var/loki/compactor";
                  retention_enabled = true;
                  retention_delete_delay = "1h";
                  delete_request_store = "filesystem";
                };
              };
              singleBinary = {
                replicas = 1;
                inherit nodeSelector;
                resources = resources "768Mi";
                persistence.enabled = false;
                extraVolumes = [ { name = "retained"; persistentVolumeClaim.claimName = "loki-data"; } ];
                extraVolumeMounts = [ { name = "retained"; mountPath = "/var/loki"; } ];
              };
              read.replicas = 0;
              write.replicas = 0;
              backend.replicas = 0;
              gateway.enabled = false;
              chunksCache.enabled = false;
              resultsCache.enabled = false;
              lokiCanary.enabled = false;
              test.enabled = false;
              sidecar.rules.enabled = false;
              monitoring.serviceMonitor.enabled = true;
            };
          };
        };
        alloy = {
          namespace = "monitoring";
        helm.releases.alloy = {
          chart = lib.helm.downloadHelmChart {
            repo = "https://grafana.github.io/helm-charts";
            chart = "alloy";
            version = "1.12.0";
            chartHash = "sha256-hVMehnltg+8mKlxtUUSZHIw3R7jIjMW4BRfNuRG3z0o=";
          };
          values = {
            image.tag = "v1.19.0";
            crds.create = false;
            controller = {
              type = "daemonset";
              inherit nodeSelector;
              volumes.extra = [ {
                name = "alloy-data";
                hostPath = { path = "/var/lib/alloy"; type = "DirectoryOrCreate"; };
              } ];
            };
            configReloader.resources = resources "32Mi";
            alloy = {
              storagePath = "/tmp/alloy";
              resources = resources "192Mi";
              securityContext = { runAsUser = 0; runAsGroup = 0; allowPrivilegeEscalation = false; capabilities.drop = [ "ALL" ]; };
              mounts = {
                varlog = true;
                extra = [ { name = "alloy-data"; mountPath = "/tmp/alloy"; } ];
              };
              extraEnv = [ { name = "NODE_NAME"; valueFrom.fieldRef.fieldPath = "spec.nodeName"; } ];
              configMap.content = builtins.readFile ./_monitoring.alloy;
            };
          };
        };
      };
    };
    };
}
