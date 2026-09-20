{
  config,
  inputs,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        inherit
          (import ./_compute-configurations.nix {
            inherit self lib system;
            hostName = config.den.clusters.prod-home.hostName;
          })
          hostConfig
          guest
          ;
        descriptor = builtins.fromJSON hostConfig.environment.etc."homelab/compute.json".text;
        baseCluster = config.den.clusters.prod-home;
        cluster = baseCluster;
        clusterEnvironment = config.den.environments.${cluster.environment};
        compute =
          config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
        bridgeAddress = lib.head (lib.splitString "/" descriptor.networkConfig."ipv4.address");
        fixtureDescriptor = descriptor // {
          runtimeSecrets = lib.filterAttrs (
            name: _: lib.hasPrefix "monitoring--grafana-admin--" name
          ) descriptor.runtimeSecrets;
        };
        webhookURL = "http://${bridgeAddress}:18080/alertmanager";
        rendered = self.nixidyEnvs.${system}.prod-home.override {
          extraSpecialArgs = {
            inherit
              inputs
              system
              clusterEnvironment
              compute
              ;
            environment = clusterEnvironment;
            cluster = lib.recursiveUpdate baseCluster {
              settings.kubernetes.services.monitoring.webhookURL = webhookURL;
            };
          };
        };
        manifestSource = rendered.config.build.environmentPackage;
        fixture = pkgs.writeText "monitoring-runtime-fixture.json" (
          builtins.toJSON {
            descriptor = fixtureDescriptor;
            inherit bridgeAddress webhookURL;
            preseedCommand = hostConfig.systemd.services.incus-preseed.serviceConfig.ExecStart;
            preseedPath = lib.makeBinPath hostConfig.systemd.services.incus-preseed.path;
          }
        );
        scenario = ./monitoring-runtime.py;
        computeGuest = pkgs.callPackage (inputs.self + "/pkgs/by-name/compute-runtime/package.nix") { };
        guestBundle = guest.config.system.build.computeBundle;
        seedManifests = self.packages.${system}.household-bootstrap-manifests;
        bootstrapHost = self.packages.${system}.household-bootstrap-host;
        testRepo = pkgs.runCommand "monitoring-runtime-repo" { } ''
          mkdir -p "$out/apps"
          for name in monitoring monitoring-retained loki alloy; do
            cp ${manifestSource}/apps/Application-''${name}.yaml "$out/apps/"
            cp -R ${manifestSource}/''${name} "$out/''${name}"
          done
        '';
        testSeed = pkgs.runCommand "monitoring-runtime-seed" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
          mkdir -p "$out"
          cp ${seedManifests}/* "$out/"
          chmod -R u+w "$out"
          yq -i '
            .metadata.name = "monitoring-runtime-apps"
            | .spec.source.repoURL = "git://${bridgeAddress}/monitoring.git"
            | .spec.source.path = "./apps"
          ' "$out/root.yaml"
        '';
        test =
          (pkgs.testers.runNixOSTest {
            name = "monitoring-runtime";
            globalTimeout = 2 * 60 * 60;
            requiredFeatures.kvm = true;

            nodes.fixture-host =
              { pkgs, ... }:
              {
                system.stateVersion = "26.05";
                networking.hostId = "b14fdd71";

                users.groups.media.gid = 505;
                users.users.root.subUidRanges = [
                  {
                    startUid = descriptor.idmapBase;
                    count = descriptor.idmapSize;
                  }
                ];
                users.users.root.subGidRanges = [
                  {
                    startGid = descriptor.idmapBase;
                    count = descriptor.idmapSize;
                  }
                ]
                ++ map (row: {
                  startGid = row.hostid;
                  count = 1;
                }) (lib.filter (row: row.nsid == row.hostid) descriptor.idmap.gid);

                virtualisation = {
                  cores = 4;
                  memorySize = 6144;
                  diskSize = 65536;
                  restrictNetwork = false;
                  useNixStoreImage = true;
                  writableStore = true;
                  writableStoreUseTmpfs = false;
                  additionalPaths = [
                    computeGuest
                    fixture
                    guestBundle
                    testRepo
                    testSeed
                    bootstrapHost
                  ];
                  incus = {
                    enable = true;
                    package = hostConfig.virtualisation.incus.package;
                    preseed = null;
                  };
                };

                environment.etc."homelab/compute.json".text = builtins.toJSON fixtureDescriptor;
                environment.systemPackages = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.git
                  pkgs.iproute2
                  pkgs.iputils
                  pkgs.jq
                  pkgs.kubectl
                  pkgs.nftables
                  pkgs.nix
                  pkgs.openssh
                  pkgs.python3
                  pkgs.util-linux
                  hostConfig.boot.zfs.package
                  pkgs.xz
                  pkgs.yq-go
                  computeGuest
                ];

                boot.kernelPackages = hostConfig.boot.kernelPackages;
                boot.zfs.package = hostConfig.boot.zfs.package;
                boot.supportedFilesystems = [ "zfs" ];
                boot.kernelModules = [ "zfs" ];
                boot.kernel.sysctl = lib.filterAttrs (
                  name: _: lib.hasPrefix "net.bridge.bridge-nf-call-" name
                ) hostConfig.boot.kernel.sysctl;
                networking.useNetworkd = hostConfig.networking.useNetworkd;
                networking.dhcpcd.enable = hostConfig.networking.dhcpcd.enable;
                networking.firewall.interfaces.${descriptor.network} =
                  hostConfig.networking.firewall.interfaces.${descriptor.network};
                networking.firewall.allowedTCPPorts = [
                  9418
                  18080
                ];
                networking.nftables.enable = true;

                systemd.tmpfiles.rules = [
                  "d /var/lib/incus-storage-pools 0755 root root -"
                  "d /var/lib/incus-storage-pools/incus-compute 0755 root root -"
                ];
              };

            testScript = ''
              start_all()
              fixture_host.wait_for_unit("incus.service", timeout=600)
              fixture_host.succeed("modprobe zfs")
              fixture_host.succeed("mkdir -p ${descriptor.poolPath}")
              fixture_host.succeed("truncate -s 28G /var/lib/incus-storage-pools.vdev")
              fixture_host.succeed(
                  "zpool create -f -o ashift=12 -O mountpoint=none "
                  "monitoring-runtime /var/lib/incus-storage-pools.vdev"
              )
              fixture_host.succeed(
                  "zfs create -o mountpoint=${descriptor.poolPath} "
                  "monitoring-runtime/incus-compute"
              )
              fixture_host.succeed(
                  "findmnt -n -o FSTYPE -M ${descriptor.poolPath} | grep -qx zfs"
              )
              console = "/dev/${
                (import "${pkgs.path}/nixos/lib/qemu-common.nix" {
                  inherit (pkgs) lib stdenv;
                }).qemuSerialDevice
              }"
              fixture_host.succeed(f"echo 'Monitoring serial output ready' > {console}")
              fixture_host.wait_for_console_text("Monitoring serial output ready", timeout=10)
              fixture_host.copy_from_host("${scenario}", "/tmp/monitoring-runtime.py")
              (status, _) = fixture_host.execute(
                  "python3 -u /tmp/monitoring-runtime.py"
                  " --bundle ${guestBundle}"
                  " --fixture ${fixture}"
                  " --repo ${testRepo}"
                  " --seed ${testSeed}"
                  " --bootstrap-host ${bootstrapHost}/bin/household-bootstrap-host"
                  " --helper ${computeGuest}/bin/compute-guest"
                  f" < /dev/null > {console} 2>&1",
                  timeout=2 * 60 * 60,
              )
              assert status == 0, "monitoring runtime scenario failed"
            '';
          }).overrideTestDerivation
            (_: {
              __noChroot = true;
            });
      in
      {
        checks.monitoring-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-monitoring-runtime";
          };
        };
      }
    );
}
