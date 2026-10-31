# Fleet monitoring for prod-home: collection and metrics storage.
#
# VictoriaMetrics scrapes every source every 30 s and keeps 90 days on a
# host-retained path. The `alerting` sub-aspect (alerting.nix) evaluates
# rules and routes alerts; the `dashboards` sub-aspect (dashboards.nix)
# serves Grafana behind administrator sign-in.
#
# Monitoring never gates the platform: its Applications sync after every
# other Application (waves 5 and 6), it defines no CRDs, and alerting depends
# on neither identity, the Gateway nor cert-manager.
{
  den,
  inputs,
  lib,
  ...
}:
let
  namespace = "monitoring";
  protect = {
    "argocd.argoproj.io/sync-options" = "Prune=false,Delete=false";
  };
  # VictoriaMetrics' UID and GID in the guest, which own the retained path.
  metricsIdentity = {
    uid = 3100;
    gid = 3100;
  };
  image = {
    repository = "docker.io/victoriametrics/victoria-metrics";
    tag = "v1.151.0";
    digest = "sha256:6d164540a04f49ba4e696cbdb70f9fee78be1e94b8f2a1292743a0b1ab8275bd";
    pullPolicy = "IfNotPresent";
  };
  # Native routes are probed on a health path; administrator routes at the
  # root, where the entrance must answer with its redirect to sign-in. A
  # native route missing here fails evaluation.
  healthPaths = {
    idm = "/status";
    jellyfin = "/health";
    requests = "/api/v1/status";
  };
  resources = cpuRequest: memoryRequest: cpuLimit: memoryLimit: {
    requests = {
      cpu = cpuRequest;
      memory = memoryRequest;
    };
    limits = {
      cpu = cpuLimit;
      memory = memoryLimit;
    };
  };
  labelsFor = name: {
    "app.kubernetes.io/name" = name;
    "app.kubernetes.io/part-of" = "monitoring";
  };
in
{
  den.aspects.kubernetes.services.monitoring = {
    includes = [
      den.aspects.kubernetes.services.monitoring.alerting
      den.aspects.kubernetes.services.monitoring.dashboards
    ];

    compute-resources = _: {
      retainedPaths.monitoring-metrics = metricsIdentity // {
        mode = "0700";
      };
    };

    k8s-manifests =
      {
        config,
        cluster,
        computeResources,
        charts ? { },
        lib,
        ...
      }:
      let
        host = inputs.self.nixosConfigurations.${cluster.hostName}.config.homelab.monitoring;
        identityHostname = builtins.head cluster.routes.idm.hostnames;
        grafanaPods = lib.optional (cluster.routes ? grafana) {
          podSelector.matchLabels = cluster.routes.grafana.backendPodSelector;
        };
        retained = computeResources.retainedPaths.monitoring-metrics;
        stateMarker = "${computeResources.stateRoot.guestPath}/${computeResources.stateRoot.marker}";
        serviceAddress = name: port: "${name}.${namespace}.svc:${toString port}";
        nodeAddress = host.guestAddress;
        nodeSelector."kubernetes.io/hostname" = computeResources.instance;

        # Derive visibility from the Gateway's effective HTTPRoutes, including
        # its identity and Seerr publication boundaries, rather than probing
        # intentionally unpublished entrances.
        publishedRoutes = lib.getAttrs (
          map (route: route.metadata.name) (
            lib.filter (object: object.kind == "HTTPRoute") (
              config.applications.gateway.objects ++ (config.applications.identity-gateway.objects or [ ])
            )
          )
        ) cluster.routes;
        # Send each probe to the gateway NodePort with the route's SNI and Host:
        # the hop the host forwards household HTTPS to.
        probes = lib.mapAttrs (
          name: route:
          let
            hostname = builtins.head route.hostnames;
            admin = route.auth == "admin";
            path =
              if admin then
                "/"
              else
                healthPaths.${name} or (throw "monitoring: native route ${name} has no endpoint probe health path");
          in
          {
            inherit hostname;
            module = "route-${name}";
            target = "https://${nodeAddress}:${toString cluster.ingress.nodePort}${path}";
            config = {
              prober = "http";
              timeout = "10s";
              http = {
                method = "GET";
                preferred_ip_protocol = "ip4";
                follow_redirects = false;
                fail_if_not_ssl = true;
                headers.Host = hostname;
                tls_config.server_name = hostname;
              }
              // (
                if admin then
                  {
                    valid_status_codes = [ 302 ];
                    fail_if_header_not_matches = [
                      {
                        header = "Location";
                        regexp = "^https://${lib.escapeRegex identityHostname}/";
                        allow_missing = false;
                      }
                    ];
                  }
                else
                  { valid_status_codes = [ ]; }
              );
            };
          }
        ) publishedRoutes;

        static = job: targets: {
          job_name = job;
          static_configs = [ { inherit targets; } ];
        };
        # Kubelet and cAdvisor on each node, with the collector's token. K3s
        # serves the kubelet with a self-signed certificate.
        kubeletJob = job: path: {
          job_name = job;
          scheme = "https";
          metrics_path = path;
          bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token";
          tls_config.insecure_skip_verify = true;
          kubernetes_sd_configs = [ { role = "node"; } ];
          relabel_configs = [
            {
              source_labels = [ "__meta_kubernetes_node_name" ];
              target_label = "node";
            }
          ];
        };
        scrape = {
          global = {
            scrape_interval = "30s";
            scrape_timeout = "10s";
            external_labels.cluster = cluster.name;
          };
          # The host exporters come from the targets the host publishes
          # through the `prometheus-targets` quirk.
          scrape_configs =
            map (target: {
              job_name = target.job;
              metrics_path = target.path;
              scrape_interval = target.interval;
              static_configs = [
                {
                  targets = [ target.address ];
                  inherit (target) labels;
                }
              ];
            }) host.scrapeTargets
            ++ [
              (kubeletJob "kubelet" "/metrics")
              (kubeletJob "cadvisor" "/metrics/cadvisor")
              (static "argocd" [ "argocd-application-controller-metrics.argocd.svc:8082" ])
              (static "cert-manager" [ "cert-manager.cert-manager.svc:9402" ])
              (static "kube-state-metrics" [ (serviceAddress "kube-state-metrics" 8080) ])
              {
                job_name = "blackbox";
                metrics_path = "/probe";
                static_configs = lib.mapAttrsToList (name: probe: {
                  targets = [ probe.target ];
                  labels = {
                    route = name;
                    inherit (probe) module hostname;
                  };
                }) probes;
                relabel_configs = [
                  {
                    source_labels = [ "__address__" ];
                    target_label = "__param_target";
                  }
                  {
                    source_labels = [ "module" ];
                    target_label = "__param_module";
                  }
                  {
                    source_labels = [ "hostname" ];
                    target_label = "instance";
                  }
                  {
                    target_label = "__address__";
                    replacement = serviceAddress "blackbox" 9115;
                  }
                  {
                    action = "labeldrop";
                    regex = "module|hostname";
                  }
                ];
              }
              (static "victoriametrics" [ "localhost:8428" ])
              (static "vmalert" [ (serviceAddress "vmalert" 8880) ])
              (static "alertmanager" [ (serviceAddress "alertmanager" 9093) ])
            ];
        };
        scrapeConfig = builtins.toJSON scrape;

        victoriametricsAccess = [
          {
            apiVersion = "v1";
            kind = "ServiceAccount";
            metadata = {
              name = "victoriametrics";
              inherit namespace;
            };
            automountServiceAccountToken = false;
          }
          # Read-only access for node discovery and kubelet metrics.
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRole";
            metadata.name = "monitoring-victoriametrics";
            rules = [
              {
                apiGroups = [ "" ];
                resources = [ "nodes" ];
                verbs = [
                  "get"
                  "list"
                  "watch"
                ];
              }
              {
                apiGroups = [ "" ];
                resources = [ "nodes/metrics" ];
                verbs = [ "get" ];
              }
            ];
          }
          {
            apiVersion = "rbac.authorization.k8s.io/v1";
            kind = "ClusterRoleBinding";
            metadata.name = "monitoring-victoriametrics";
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "ClusterRole";
              name = "monitoring-victoriametrics";
            };
            subjects = [
              {
                kind = "ServiceAccount";
                name = "victoriametrics";
                inherit namespace;
              }
            ];
          }
        ];

        policy = name: selector: port: sources: {
          apiVersion = "networking.k8s.io/v1";
          kind = "NetworkPolicy";
          metadata = { inherit name namespace; };
          spec = {
            podSelector.matchLabels = selector;
            policyTypes = [ "Ingress" ];
            ingress = [
              {
                from = sources;
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
        fromVictoriaMetrics = [ { podSelector.matchLabels = labelsFor "victoriametrics"; } ];
        ksmLabels = {
          "app.kubernetes.io/instance" = "kube-state-metrics";
          "app.kubernetes.io/name" = "kube-state-metrics";
        };
        blackboxLabels = {
          "app.kubernetes.io/instance" = "blackbox";
          "app.kubernetes.io/name" = "prometheus-blackbox-exporter";
        };
        # Default-deny ingress for the namespace, then one allow per
        # component and port. alerting.nix and dashboards.nix add theirs.
        networkPolicies = [
          {
            apiVersion = "networking.k8s.io/v1";
            kind = "NetworkPolicy";
            metadata = {
              name = "default-deny-ingress";
              inherit namespace;
            };
            spec = {
              podSelector = { };
              policyTypes = [ "Ingress" ];
            };
          }
          (policy "victoriametrics" (labelsFor "victoriametrics") 8428 (
            [ { podSelector.matchLabels = labelsFor "vmalert"; } ] ++ grafanaPods
          ))
          (policy "kube-state-metrics" ksmLabels 8080 fromVictoriaMetrics)
          (policy "blackbox" blackboxLabels 9115 fromVictoriaMetrics)
        ];
      in
      assert lib.assertMsg (
        retained.uid == metricsIdentity.uid && retained.gid == metricsIdentity.gid && !retained.readOnly
      ) "monitoring-metrics must be a writable retained path owned by VictoriaMetrics";
      {
        # Identity publishes Grafana's client Secret into this namespace at
        # wave 2, and identity-gateway writes the Grafana route's
        # ReferenceGrant and backend policy here at wave 4. Monitoring's own
        # Applications sync last, so the Namespace lives in identity's
        # retained Application, which syncs before both. A Namespace has no
        # health to degrade, so identity gains no dependency on monitoring.
        applications.identity-retained.objects = [
          {
            apiVersion = "v1";
            kind = "Namespace";
            metadata = {
              name = namespace;
              annotations = protect;
            };
          }
        ];

        # Not the usual early retained wave: that would put monitoring in
        # front of every other Application.
        applications.monitoring-retained = {
          inherit namespace;
          annotations."argocd.argoproj.io/sync-wave" = "5";
          createNamespace = false;
          retained = true;
          resources = {
            persistentVolumes.monitoring-metrics = {
              metadata.annotations = protect;
              spec = {
                # A label, not a limit: Kubernetes does not enforce a local
                # volume's capacity. Retention and the free-space floor bound
                # the history.
                capacity.storage = "20Gi";
                accessModes = [ "ReadWriteOnce" ];
                persistentVolumeReclaimPolicy = "Retain";
                storageClassName = "";
                claimRef = {
                  inherit namespace;
                  name = "monitoring-metrics";
                };
                local.path = retained.guestPath;
                nodeAffinity.required.nodeSelectorTerms = [
                  {
                    matchExpressions = [
                      {
                        key = "kubernetes.io/hostname";
                        operator = "In";
                        values = [ computeResources.instance ];
                      }
                    ];
                  }
                ];
              };
            };
            persistentVolumeClaims.monitoring-metrics = {
              metadata.annotations = protect;
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                storageClassName = "";
                volumeName = "monitoring-metrics";
                resources.requests.storage = "20Gi";
              };
            };
          };
        };

        applications.monitoring = {
          inherit namespace;
          annotations."argocd.argoproj.io/sync-wave" = "6";
          createNamespace = false;
          finalizer = "foreground";
          objects = victoriametricsAccess ++ networkPolicies;
          helm.releases = {
            victoriametrics = {
              chart = charts.bjw-s-labs.app-template;
              values = {
                fullnameOverride = "victoriametrics";
                global.createDefaultServiceAccount = false;
                defaultPodOptions = {
                  inherit nodeSelector;
                  labels = labelsFor "victoriametrics";
                  automountServiceAccountToken = true;
                  enableServiceLinks = false;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = metricsIdentity.uid;
                    runAsGroup = metricsIdentity.gid;
                    seccompProfile.type = "RuntimeDefault";
                  };
                };
                controllers.main = {
                  type = "deployment";
                  strategy = "Recreate";
                  replicas = 1;
                  serviceAccount.name = "victoriametrics";
                  containers.victoriametrics = {
                    inherit image;
                    args = [
                      "-storageDataPath=/storage"
                      "-retentionPeriod=90d"
                      # Refuse new writes before the shared pool's last 50 GiB.
                      "-storage.minFreeDiskSpaceBytes=50GiB"
                      "-promscrape.config=/etc/victoriametrics/scrape.json"
                      "-promscrape.config.strictParse=true"
                      "-httpListenAddr=:8428"
                    ];
                    ports = [
                      {
                        name = "http";
                        containerPort = 8428;
                      }
                    ];
                    probes = {
                      liveness.enabled = false;
                      startup.enabled = false;
                      readiness = {
                        enabled = true;
                        custom = true;
                        spec = {
                          httpGet = {
                            path = "/health";
                            port = 8428;
                          };
                          periodSeconds = 10;
                        };
                      };
                    };
                    resources = resources "100m" "384Mi" "1" "1536Mi";
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      readOnlyRootFilesystem = true;
                      capabilities.drop = [ "ALL" ];
                    };
                  };
                };
                service.main = {
                  controller = "main";
                  type = "ClusterIP";
                  extraSelectorLabels = labelsFor "victoriametrics";
                  ports.http = {
                    port = 8428;
                    targetPort = 8428;
                    protocol = "TCP";
                  };
                };
                configMaps.scrape = {
                  forceRename = "victoriametrics-scrape";
                  # The chart includes this content in the Pod rollout checksum.
                  includeInChecksum = true;
                  data."scrape.json" = scrapeConfig;
                };
                persistence = {
                  # Only consume the retained claim; the chart creates no storage.
                  storage = {
                    type = "persistentVolumeClaim";
                    existingClaim = "monitoring-metrics";
                    globalMounts = [ { path = "/storage"; } ];
                  };
                  scrape = {
                    type = "configMap";
                    identifier = "scrape";
                    defaultMode = 420; # 0644, the existing ConfigMap projection mode.
                    globalMounts = [
                      {
                        path = "/etc/victoriametrics";
                        readOnly = true;
                      }
                    ];
                  };
                  # A missing marker must fail startup, never create substitute storage.
                  state-marker = {
                    type = "hostPath";
                    hostPath = stateMarker;
                    hostPathType = "File";
                    globalMounts = [
                      {
                        path = "/run/homelab-state-root";
                        readOnly = true;
                      }
                    ];
                  };
                };
              };
            };
            kube-state-metrics = {
              chart = lib.helm.downloadHelmChart {
                repo = "https://prometheus-community.github.io/helm-charts";
                chart = "kube-state-metrics";
                version = "8.6.0";
                chartHash = "sha256-6f0ybk5ZeHvr6hHPr/WFuES5bFO/cJJWQFdQM/9tSEU=";
              };
              values = {
                fullnameOverride = "kube-state-metrics";
                image = {
                  registry = "registry.k8s.io";
                  repository = "kube-state-metrics/kube-state-metrics";
                  tag = "v2.20.0";
                  sha = "sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b";
                };
                # No Secrets or ConfigMaps, and no label or annotation
                # allowlists: low cardinality, and no Secret metadata in
                # metrics.
                collectors = [
                  "cronjobs"
                  "daemonsets"
                  "deployments"
                  "jobs"
                  "namespaces"
                  "nodes"
                  "persistentvolumeclaims"
                  "persistentvolumes"
                  "pods"
                  "replicasets"
                  "statefulsets"
                ];
                metricLabelsAllowlist = [ ];
                metricAnnotationsAllowList = [ ];
                selfMonitor.enabled = false;
                prometheus.monitor.enabled = false;
                networkPolicy.enabled = false;
                inherit nodeSelector;
                resources = resources "25m" "64Mi" "250m" "256Mi";
              };
            };
            blackbox = {
              chart = charts.prometheus-community.prometheus-blackbox-exporter;
              values = {
                fullnameOverride = "blackbox";
                image = {
                  registry = "quay.io";
                  repository = "prometheus/blackbox-exporter";
                  tag = "v0.28.0";
                  digest = "sha256:e753ff9f3fc458d02cca5eddab5a77e1c175eee484a8925ac7d524f04366c2fc";
                };
                config.modules = lib.mapAttrs' (_: probe: lib.nameValuePair probe.module probe.config) probes;
                configReloader.enabled = false;
                serviceMonitor.enabled = false;
                networkPolicy.enabled = false;
                automountServiceAccountToken = false;
                inherit nodeSelector;
                resources = resources "10m" "32Mi" "100m" "128Mi";
              };
            };
          };
        };
      };
  };
}
