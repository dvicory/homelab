# Inspect canonical output at build time, as media-contracts does. The independent
# prod-home-manifests-fresh gate checks it against each native renderer; importing
# application.objects here would force foreign-platform Helm during inventory.
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
  bridgeAddress = builtins.head (
    lib.splitString "/"
      (lib.findFirst (
        network: network.name == compute.network
      ) null hvn.virtualisation.incus.preseed.networks).config."ipv4.address"
  );
  hostChecks = {
    "the host exporter listens beyond the compute bridge address" =
      hvn.systemd.sockets.host-telemetry-node-exporter.socketConfig.ListenStream
      == "${bridgeAddress}:9100"
      && telemetry.listenAddress == bridgeAddress;
    "the host firewall admits something other than the guest on the compute bridge" =
      hvn.networking.firewall.extraInputRules
      == ''iifname "${compute.network}" ip saddr ${compute.address} tcp dport 9100 accept'';
    "a host telemetry unit is wanted by a target that activation waits on" =
      lib.all (unit: hvn.systemd.services.${unit}.wantedBy == [ ])
        [
          "host-telemetry-node-exporter"
          "host-telemetry-zpool-status"
          "host-telemetry-smart-status"
        ];
  };
in
{
  perSystem =
    { pkgs, ... }:
    let
      rendered = ../../generated/manifests/prod-home;
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      contractInputs = pkgs.writeText "monitoring-contract-inputs.json" (
        builtins.toJSON {
          inherit hostChecks;
          routes = cluster.routes;
          adminGroup = cluster.settings.kubernetes.services.identity.adminGroup;
          metricsPath = compute.retainedPaths.monitoring-metrics.guestPath;
          metricsOwner = {
            inherit (compute.retainedPaths.monitoring-metrics) uid gid;
          };
          markerPath = "${compute.stateGuestPath}/${compute.stateMarker}";
        }
      );
    in
    {
      checks.monitoring-contracts =
        pkgs.runCommand "monitoring-contracts"
          {
            nativeBuildInputs = [ python ];
          }
          ''
            python ${./_monitoring-contracts.py} ${rendered} ${contractInputs}
            touch $out
          '';
    };
}
