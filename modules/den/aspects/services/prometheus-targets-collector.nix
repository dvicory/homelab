# Consumer of the `prometheus-targets` quirk on a compute host, in the style
# of persist-collector and firewall-collector.
#
# It does two things with this host's targets:
# - admits only the compute guest, on the private host–guest interface, to
#   each target port;
# - publishes, as read-only options, what the cluster collector needs: the
#   resolved scrape targets and the pools, disks and mounts that must keep
#   reporting. The cluster monitoring aspect reads these from this host's
#   evaluated configuration.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  readOnly =
    type: description:
    mkOption {
      inherit type description;
      readOnly = true;
    };
in
{
  den.aspects.services.prometheus-targets-collector = {
    nixos =
      {
        host,
        config,
        lib,
        prometheus-targets,
        ...
      }:
      let
        compute = host.settings.virtualization.compute;
        telemetry = host.settings.services.host-telemetry;
        # The host's address on the compute network is the Incus bridge
        # address that the compute aspect declares for that network.
        network =
          lib.findFirst (entry: entry.name == compute.network)
            (throw "compute network ${compute.network} is not in the Incus preseed")
            config.virtualisation.incus.preseed.networks;
        listenAddress = builtins.head (lib.splitString "/" network.config."ipv4.address");
        # The pipe also collects other hosts' targets; only this host's are
        # served here.
        targets = lib.filter (target: target.host == host.name) prometheus-targets;
        ports = lib.unique (map (target: target.port) targets);
        mergerfsPools = builtins.attrNames (host.settings.services.mergerfs.pools or { });
        luksMounts = lib.mapAttrsToList (_: disk: disk.mountpoint) (
          lib.filterAttrs (_: disk: disk.provisioned) (host.settings.disk.luks-storage.disks or { })
        );
        rootPool = host.zfs.rootPool.name or null;
      in
      {
        options.homelab.monitoring = {
          listenAddress = readOnly types.str "Host address on the private host-guest network. Host telemetry listens only here.";
          interface = readOnly types.str "Private host-guest interface that host telemetry is admitted on.";
          guestAddress = readOnly types.str "The only source address admitted to host telemetry.";
          scrapeTargets = readOnly (types.listOf types.attrs) "Resolved host scrape targets: job, address, path, interval, labels.";
          pools = readOnly (types.listOf types.str) "ZFS pools that must keep reporting.";
          disks = readOnly (types.attrsOf types.str) "Physical disks, by readable name and stable path, whose SMART health must keep reporting.";
          requiredMounts = readOnly (types.listOf types.str) "Mountpoints that must be present.";
        };

        config = {
          homelab.monitoring = {
            inherit listenAddress;
            interface = compute.network;
            guestAddress = compute.address;
            scrapeTargets = map (target: {
              inherit (target)
                job
                path
                interval
                labels
                ;
              address = "${listenAddress}:${toString target.port}";
            }) targets;
            pools = lib.optional (rootPool != null) rootPool;
            disks = telemetry.expectedDisks;
            requiredMounts = lib.sort builtins.lessThan (
              lib.unique (mergerfsPools ++ luksMounts ++ telemetry.extraRequiredMounts)
            );
          };

          # The bind address is bridge-only; this rule also checks the
          # interface and the source, so the LAN, the tailnet and the
          # internet cannot reach the ports.
          networking.firewall.extraInputRules = lib.concatMapStringsSep "\n" (
            port: ''iifname "${compute.network}" ip saddr ${compute.address} tcp dport ${toString port} accept''
          ) ports;
        };
      };
  };
}
