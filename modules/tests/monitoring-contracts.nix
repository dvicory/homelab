# Inspect canonical output at build time, as media-contracts does. The independent
# prod-home-manifests-fresh gate checks it against each native renderer; importing
# application.objects here would force foreign-platform Helm during inventory.
{ config, inputs, lib, self, ... }:
let
  cluster = config.den.clusters.prod-home;
  hvn = self.nixosConfigurations.hvn-hyp1.config;
  telemetry = hvn.homelab.monitoring;
  compute = config.den.hosts.x86_64-linux.hvn-hyp1.settings.virtualization.compute;
  gatewayAspect =
    (import ../den/aspects/kubernetes/services/gateway.nix { }).den.aspects.kubernetes.services.gateway;
  grafanaRouteIn = phase:
    lib.any (object: object.kind == "HTTPRoute" && object.metadata.name == "grafana")
      (gatewayAspect.k8s-manifests {
        cluster = lib.recursiveUpdate cluster { settings.kubernetes.services.identity.phase = phase; };
        computeResources = { inherit (compute) instance; };
        inherit lib;
        charts = { };
      }).applications.gateway.objects;
  bridgeAddress = builtins.head (lib.splitString "/" (
    lib.findFirst (network: network.name == compute.network) null
      hvn.virtualisation.incus.preseed.networks
  ).config."ipv4.address");
  hostChecks = {
    "the host exporter listens beyond the compute bridge address" =
      hvn.systemd.sockets.host-telemetry-node-exporter.socketConfig.ListenStream == "${bridgeAddress}:9100"
      && telemetry.listenAddress == bridgeAddress;
    "the host firewall admits something other than the guest on the compute bridge" =
      hvn.networking.firewall.extraInputRules
      == ''iifname "${compute.network}" ip saddr ${compute.address} tcp dport 9100 accept'';
    "a host telemetry unit is wanted by a target that activation waits on" = lib.all (
      unit: hvn.systemd.services.${unit}.wantedBy == [ ]
    ) [ "host-telemetry-node-exporter" "host-telemetry-zpool-status" "host-telemetry-smart-status" ];
    "the required mounts are not exactly media4 and the MergerFS pool" =
      telemetry.requiredMounts == [ "/mnt/storage-clear/media4" "/srv/media/data" ];
    "Grafana's route is served outside identity phase normal" =
      !(grafanaRouteIn "initial") && !(grafanaRouteIn "provisioning");
  };
in
{
  perSystem = { pkgs, system, ... }:
    let
      # Read chart pins from the production aspects, without entering nixidy's
      # Helm object merge. All rendered object assertions read canonical output.
      renderArgs = {
        inherit cluster;
        charts = inputs.nixhelm.chartsDerivations.${system};
        lib = import (inputs.nixidy + "/lib") {
          inherit pkgs;
          kubelib = inputs.nixidy.inputs.nix-kube-generators;
        };
        computeResources = {
          inherit (compute) instance retainedPaths;
          stateRoot = {
            guestPath = compute.stateGuestPath;
            marker = compute.stateMarker;
          };
        };
      };
      monitoring = config.den.aspects.kubernetes.services.monitoring;
      chartReleases =
        (monitoring.k8s-manifests renderArgs).applications.monitoring.helm.releases
        // ((monitoring.dashboards.k8s-manifests renderArgs).applications.monitoring.helm.releases or { });
      rendered = ../../generated/manifests/prod-home;
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      contractInputs = pkgs.writeText "monitoring-contract-inputs.json" (builtins.toJSON {
        inherit hostChecks;
        routes = cluster.routes;
        adminGroup = cluster.settings.kubernetes.services.identity.adminGroup;
        metricsPath = compute.retainedPaths.monitoring-metrics.guestPath;
        markerPath = "${compute.stateGuestPath}/${compute.stateMarker}";
        charts = map (release: {
          name = release.chart.name;
          hash = release.chart.outputHash or null;
        }) (builtins.attrValues chartReleases);
      });
    in
    {
      checks.monitoring-contracts = pkgs.runCommand "monitoring-contracts" {
        nativeBuildInputs = [ python ];
      } ''
        python ${./_monitoring-contracts.py} ${rendered} ${contractInputs}
        touch $out
      '';
    };
}
