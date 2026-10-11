# Evaluation-only checks for the boundaries prod-home monitoring must keep:
# it never gates other Applications, only Grafana is routed and only behind
# administrator sign-in, every route is probed and every scrape job has a
# missing-telemetry alert, metrics storage fails closed on its retained path,
# resources are bounded, ingress is default-deny, Secrets stay out of
# metrics, and host telemetry is reachable only from the guest.
{
  config,
  lib,
  self,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  hvn = self.nixosConfigurations.hvn-hyp1.config;
  telemetry = hvn.homelab.monitoring;
  compute = config.den.hosts.x86_64-linux.hvn-hyp1.settings.virtualization.compute;
  monitoringApplications = [
    "monitoring-retained"
    "monitoring"
  ];
  find =
    objects: kind: name:
    lib.findFirst (object: object.kind == kind && object.metadata.name == name) null objects;
  wave = application: lib.toInt (application.annotations."argocd.argoproj.io/sync-wave" or "0");
  cpu =
    value:
    let
      text = toString value;
    in
    if lib.hasSuffix "m" text then lib.toInt (lib.removeSuffix "m" text) else lib.toInt text * 1000;
  memory =
    value:
    let
      text = toString value;
      units = {
        Ki = 1024;
        Mi = 1024 * 1024;
        Gi = 1024 * 1024 * 1024;
      };
      suffix = lib.findFirst (unit: lib.hasSuffix unit text) null (builtins.attrNames units);
    in
    if suffix == null then lib.toInt text else lib.toInt (lib.removeSuffix suffix text) * units.${suffix};
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      env = self.nixidyEnvs.${system}.prod-home.config;
      applications = removeAttrs env.applications [
        "__bootstrap"
        "apps"
      ];
      objects = env.applications.monitoring.objects;
      retainedObjects = env.applications.monitoring-retained.objects;
      data = name: (find objects "ConfigMap" name).data;
      podSpecs = map (object: object.spec.template.spec) (
        lib.filter (
          object:
          builtins.elem object.kind [
            "Deployment"
            "StatefulSet"
            "DaemonSet"
          ]
        ) objects
      );
      containers = lib.concatMap (spec: (spec.initContainers or [ ]) ++ spec.containers) podSpecs;
      scrapeJobs = builtins.fromJSON (data "victoriametrics-scrape")."scrape.json";
      jobNames = map (job: job.job_name) scrapeJobs.scrape_configs;
      blackboxJob = lib.findFirst (job: job.job_name == "blackbox") { static_configs = [ ]; } scrapeJobs.scrape_configs;
      probedRoutes = map (target: target.labels.route) blackboxJob.static_configs;
      rules = lib.concatMap (group: group.rules) (builtins.fromJSON (data "vmalert-rules")."rules.json").groups;
      sourceDownJobs = map (rule: rule.labels.job) (
        lib.filter (rule: (rule.alert or null) == "TelemetrySourceDown") rules
      );
      hasGrafana = cluster.routes ? grafana;
      grafanaIni = (data "grafana")."grafana.ini" or "";
      policies = lib.filter (object: object.kind == "NetworkPolicy") objects;
      selects =
        policy: selector:
        let
          match = policy.spec.podSelector.matchLabels or { };
        in
        match != { } && lib.all (key: (selector.${key} or null) == match.${key}) (builtins.attrNames match);
      victoriametrics = find objects "Deployment" "victoriametrics";
      volume = name: lib.findFirst (v: v.name == name) { } victoriametrics.spec.template.spec.volumes;
      pv = find retainedObjects "PersistentVolume" "monitoring-metrics";
      ksmArgs = (builtins.head (find objects "Deployment" "kube-state-metrics").spec.template.spec.containers).args;
      ksmResources = lib.splitString "," (
        lib.removePrefix "--resources=" (lib.findFirst (lib.hasPrefix "--resources=") "" ksmArgs)
      );
      socket = hvn.systemd.sockets.host-telemetry-node-exporter.socketConfig;
      bridgeAddress = builtins.head (
        lib.splitString "/" (
          lib.findFirst (
            network: network.name == compute.network
          ) null hvn.virtualisation.incus.preseed.networks
        ).config."ipv4.address"
      );
      identityObjects = env.applications.identity.objects;
      gatewayObjects = env.applications.identity-gateway.objects;
      provision = (find identityObjects "ConfigMap" "kanidm-provision").data;
      grafanaClients = lib.filter (client: client.name == "grafana") (
        builtins.fromJSON provision."clients.json"
      );
      grafanaOauth = (builtins.fromJSON provision."state.json").systems.oauth2.grafana;
      grafanaUrls = map (hostname: "https://${hostname}") cluster.routes.grafana.hostnames;
      securityPolicy = find gatewayObjects "SecurityPolicy" "grafana-admin";
      httpRoute = find gatewayObjects "HTTPRoute" "grafana";
      gatewayAspect =
        (import ../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
      grafanaRouteIn =
        phase:
        lib.any (object: object.kind == "HTTPRoute" && object.metadata.name == "grafana")
          (gatewayAspect.k8s-manifests {
            cluster = lib.recursiveUpdate cluster { settings.kubernetes.services.identity.phase = phase; };
            computeResources = { inherit (compute) instance; };
            inherit lib;
            charts = { };
          }).applications.gateway.objects;

      checks = {
        "a non-monitoring Application syncs at wave 5 or later, where a degraded monitoring child could block it" =
          lib.all (
            name: builtins.elem name monitoringApplications || wave applications.${name} < 5
          ) (builtins.attrNames applications);
        "a monitoring Application syncs before wave 5" = lib.all (
          name: wave applications.${name} >= 5
        ) monitoringApplications;
        "a route serves a monitoring Service other than Grafana, or Grafana's route is not an administrator route" =
          lib.all (route: route.namespace != "monitoring" || route.service == "grafana") (
            builtins.attrValues cluster.routes
          )
          && (!hasGrafana || cluster.routes.grafana.auth == "admin");
        "a declared route has no endpoint probe" =
          lib.sort builtins.lessThan probedRoutes == builtins.attrNames cluster.routes;
        "a scrape job has no TelemetrySourceDown alert" = lib.all (job: builtins.elem job sourceDownJobs) jobNames;
        "a Watchdog core source is not scraped" = lib.all (job: builtins.elem job jobNames) [
          "kubelet"
          "cadvisor"
          "kube-state-metrics"
          "host-node"
        ];
        "a monitoring image is not pinned as tag@digest" = lib.all (
          container: builtins.match "[^@ ]+:[^@ ]+@sha256:[0-9a-f]{64}" container.image != null
        ) containers;
        "a monitoring chart has no pinned version and hash" = lib.all (
          release:
          (release.chart.outputHash or null) != null
          && builtins.match ".*-[0-9]+\\.[0-9]+\\.[0-9]+" release.chart.name != null
        ) (builtins.attrValues env.applications.monitoring.helm.releases);
        "VictoriaMetrics does not store only on the static local volume of its retained path" =
          (volume "storage").persistentVolumeClaim.claimName or null == "monitoring-metrics"
          && pv.spec.local.path or null == compute.retainedPaths.monitoring-metrics.guestPath
          && pv.spec.storageClassName == ""
          && (find retainedObjects "PersistentVolumeClaim" "monitoring-metrics").spec.volumeName
            == "monitoring-metrics";
        "VictoriaMetrics can start without the persistent state root's marker" =
          (volume "state-marker").hostPath or null == {
            path = "${compute.stateGuestPath}/${compute.stateMarker}";
            type = "File";
          };
        "a monitoring volume creates its host path" = lib.all (
          v: (v.hostPath.type or "") != "DirectoryOrCreate"
        ) (lib.concatMap (spec: spec.volumes or [ ]) podSpecs);
        "a monitoring container has no CPU or memory limit, or the total exceeds 3 CPU and 3.5Gi" =
          lib.all (c: c ? resources.limits.cpu && c ? resources.limits.memory) containers
          && lib.foldl' (sum: c: sum + cpu c.resources.limits.cpu) 0 containers <= 3000
          && lib.foldl' (sum: c: sum + memory c.resources.limits.memory) 0 containers <= 3584 * 1024 * 1024;
        "the monitoring namespace has no default-deny ingress policy" =
          (find objects "NetworkPolicy" "default-deny-ingress").spec or null == {
            podSelector = { };
            policyTypes = [ "Ingress" ];
          };
        "a monitoring Service is selected by no NetworkPolicy" = lib.all (
          service: lib.any (policy: selects policy service.spec.selector) policies
        ) (lib.filter (object: object.kind == "Service") objects);
        "something other than the Gateway may reach Grafana" =
          !hasGrafana
          || map (rule: rule.from) (find objects "NetworkPolicy" "grafana").spec.ingress == [
            [
              {
                namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "gateway";
                podSelector.matchLabels."gateway.envoyproxy.io/owning-gateway-name" = "household";
              }
            ]
          ];
        "kube-state-metrics exports Secrets or ConfigMaps, or its RBAC can write" =
          builtins.elem "pods" ksmResources
          && !(builtins.elem "secrets" ksmResources)
          && !(builtins.elem "configmaps" ksmResources)
          && lib.all (
            rule:
            lib.all (
              verb:
              builtins.elem verb [
                "get"
                "list"
                "watch"
              ]
            ) rule.verbs
          ) (find objects "ClusterRole" "kube-state-metrics").rules;
        "Alertmanager does not start without its delivery credentials" =
          (lib.findFirst (v: v.name == "delivery") { } (find objects "Deployment" "alertmanager")
            .spec.template.spec.volumes
          ).secret.optional or false;
        "the host exporter listens beyond the compute bridge address" =
          socket.ListenStream == "${bridgeAddress}:9100" && telemetry.listenAddress == bridgeAddress;
        "the host firewall admits something other than the guest on the compute bridge" =
          hvn.networking.firewall.extraInputRules
          == ''iifname "${compute.network}" ip saddr ${compute.address} tcp dport 9100 accept'';
        "a host telemetry unit is wanted by a target that activation waits on" = lib.all (
          unit: hvn.systemd.services.${unit}.wantedBy == [ ]
        ) [
          "host-telemetry-node-exporter"
          "host-telemetry-zpool-status"
          "host-telemetry-smart-status"
        ];
        "the required mounts are not exactly media4 and the MergerFS pool" =
          telemetry.requiredMounts == [
            "/mnt/storage-clear/media4"
            "/srv/media/data"
          ];
        "the monitoring Namespace is not created before identity publishes into it" =
          find env.applications.identity-retained.objects "Namespace" "monitoring" != null
          && wave env.applications.identity-retained < wave env.applications.identity;
      }
      // lib.optionalAttrs hasGrafana {
        "the Gateway's backend policy admits more than the Gateway proxy to Grafana" = lib.all (
          rule: lib.all (peer: peer ? podSelector && peer ? namespaceSelector) rule.from
        ) (find gatewayObjects "NetworkPolicy" "gateway-grafana-backend-ingress").spec.ingress;
        "Grafana's administrator password is stored rather than generated in memory at Pod start" =
          let
            spec = (find objects "Deployment" "grafana").spec.template.spec;
            env = (lib.findFirst (c: c.name == "grafana") { } spec.containers).env or [ ];
            password = lib.findFirst (e: e.name == "GF_SECURITY_ADMIN_PASSWORD") { } env;
            volume = lib.findFirst (v: v.name == "admin-password") { } spec.volumes;
          in
          password.value or "" == "$__file{/run/grafana-admin/password}"
          && volume.emptyDir.medium or "" == "Memory"
          && builtins.length (spec.initContainers or [ ]) == 1;
        "Grafana grants access other than through Kanidm sign-in by the administrator group" =
          lib.all (line: lib.hasInfix line grafanaIni) [
            "client_id = grafana"
            "use_pkce = true"
            "role_attribute_strict = true"
            "role_attribute_path = contains(groups[*], '${cluster.settings.kubernetes.services.identity.adminGroup}') && 'Admin' || ''"
            "disable_login_form = true"
            "[auth.basic]\nenabled = false"
            "[auth.anonymous]\nenabled = false"
            "client_secret = $__file{/etc/secrets/grafana-oidc/client-secret}"
          ];
        "Kanidm does not offer Grafana once, with both the entrance and Grafana callbacks" =
          builtins.length grafanaClients == 1
          && grafanaOauth.displayName == "Grafana"
          && lib.all (
            url:
            builtins.elem "${url}/oauth2/callback" grafanaOauth.originUrl
            && builtins.elem "${url}/login/generic_oauth" grafanaOauth.originUrl
          ) grafanaUrls;
        "identity does not publish Grafana's client secret into the monitoring namespace" =
          builtins.elem {
            namespace = "monitoring";
            name = "grafana-oidc";
            key = "client-secret";
            labels = { };
          } (builtins.head grafanaClients).secrets;
        "Grafana's route can sync before its entrance sign-in" =
          securityPolicy.spec.oidc.clientID == "grafana"
          && securityPolicy.spec.targetRefs == [
            {
              group = "gateway.networking.k8s.io";
              kind = "HTTPRoute";
              name = "grafana";
            }
          ]
          && securityPolicy.metadata.annotations."argocd.argoproj.io/sync-wave" == "-1"
          && httpRoute.metadata.annotations."argocd.argoproj.io/sync-wave" == "0";
        "Grafana's route is served outside identity phase normal" =
          !(grafanaRouteIn "initial") && !(grafanaRouteIn "provisioning");
        "Kanidm's NetworkPolicy does not admit Grafana's token exchange" = lib.any (
          rule:
          lib.any (
            peer:
            peer.namespaceSelector.matchLabels."kubernetes.io/metadata.name" or null == "monitoring"
            && peer.podSelector.matchLabels or null == cluster.routes.grafana.backendPodSelector
          ) (rule.from or [ ])
        ) (find identityObjects "NetworkPolicy" "kanidm-private").spec.ingress;
        "a provisioned dashboard is not valid JSON" = lib.all (
          text: builtins.isAttrs (builtins.fromJSON text)
        ) (builtins.attrValues (data "grafana-dashboards"));
        "Grafana provisions dashboards beyond the minimal set" =
          builtins.attrNames (data "grafana-dashboards") == [
            "homelab-overview.json"
            "k8s-resources-namespace.json"
            "k8s-resources-pod.json"
            "node-exporter-full.json"
          ];
      };
      failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
    in
    {
      checks.monitoring-contracts =
        assert lib.assertMsg (failures == [ ])
          "Monitoring contract checks failed:\n- ${lib.concatStringsSep "\n- " failures}";
        pkgs.writeText "monitoring-contracts" "ok\n";
    };
}
