# Behaviour test: NetworkPolicy enforcement keeps working in the
# unprivileged compute guest.
#
# K3s's embedded network-policy controller replaces the guest's whole iptables
# filter table with one iptables-restore call. The guest's iptables uses the
# nf_tables backend, which sends that table as one netlink batch, and the
# kernel refuses a batch larger than the socket's send buffer. Inside an
# unprivileged Incus container iptables cannot force a larger buffer, so it
# gets the host's net.core.wmem_default. When the table outgrows that, every
# sync fails with "Message too long": rules freeze, and Pods started later,
# including every Pod after a restart, get no policy.
#
# The fixture host runs the evaluated host's Incus envelope, kernel, and
# bridge and socket-buffer sysctls, and creates the real compute guest through
# the production lifecycle helper. The guest receives every committed
# NetworkPolicy, a stand-in Pod for each committed workload, and then Pods
# that committed policies select until the node reaches its Pod limit. The
# test requires, on first boot and again after a guest restart, when every
# Pod has a new address, that:
#
#   - K3s's journal holds no failed policy sync;
#   - every policy-selected Pod has its firewall chain at its current address;
#   - the Gateway proxy and declared callers reach Kanidm and the media apps,
#     and other Pods are refused;
#   - the traced restore batch is larger than the old 212992-byte default and
#     fits the guest's send buffer.
#
# Without the host's net.core.wmem_default declaration this test fails on
# first boot. x86_64/KVM only. All images are local, so the test needs no
# registry.
{
  config,
  inputs,
  lib,
  self,
  ...
}:
let
  manifests = ../../generated/manifests/prod-home;
in
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
        computeGuest = pkgs.callPackage (inputs.self + "/pkgs/by-name/compute-runtime/package.nix") { };
        guestBundle = guest.config.system.build.computeBundle;
        stageUnit = hostConfig.systemd.services.compute-stage-secrets;
        standInImage = pkgs.dockerTools.buildImage {
          name = "homelab/network-policy-stand-in";
          tag = "1";
          copyToRoot = pkgs.buildEnv {
            name = "network-policy-stand-in-root";
            paths = [
              pkgs.busybox
              (pkgs.runCommand "network-policy-stand-in-www" { } ''
                mkdir -p "$out/www"
                echo stand-in > "$out/www/index.html"
              '')
            ];
          };
        };
        inputs' =
          pkgs.runCommand "network-policy-runtime-inputs"
            {
              nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
            }
            ''
              mkdir "$out"
              python ${./compute-network-policy-inputs.py} ${manifests} "$out" \
                --image ${standInImage.imageName}:${standInImage.imageTag}
            '';
        scenario = ./compute-network-policy-runtime.py;
        library = ./prod-home-replacement.py;
        test = pkgs.testers.runNixOSTest {
          name = "compute-network-policy-runtime";
          globalTimeout = 2 * 60 * 60;
          requiredFeatures.kvm = true;

          nodes.fixture-host =
            { lib, pkgs, ... }:
            {
              system.stateVersion = "26.05";
              networking.hostId = "c057a9e4";
              users.groups.media.gid = 505;

              virtualisation = {
                cores = 8;
                memorySize = 10240;
                diskSize = 65536;
                useNixStoreImage = true;
                writableStore = true;
                writableStoreUseTmpfs = false;
                additionalPaths = [
                  computeGuest
                  guestBundle
                  standInImage
                  inputs'
                ];
                incus = {
                  enable = true;
                  package = hostConfig.virtualisation.incus.package;
                  inherit (hostConfig.virtualisation.incus) preseed;
                };
              };

              environment.etc."homelab/compute.json" = hostConfig.environment.etc."homelab/compute.json";
              users.users.root.subGidRanges = hostConfig.users.users.root.subGidRanges;
              systemd.services.incus-preseed.serviceConfig.ExecStart =
                lib.mkForce hostConfig.systemd.services.incus-preseed.serviceConfig.ExecStart;
              # Production starts these with the host; the scenario starts them
              # after the disposable pool and inputs exist.
              systemd.services.incus-preseed.wantedBy = lib.mkForce [ ];
              systemd.services.compute-stage-secrets = {
                inherit (stageUnit)
                  description
                  path
                  serviceConfig
                  script
                  ;
              };

              environment.systemPackages = [
                pkgs.coreutils
                pkgs.findutils
                pkgs.jq
                pkgs.openssh
                pkgs.procps
                pkgs.python3
                pkgs.strace
                pkgs.util-linux
                hostConfig.boot.zfs.package
                computeGuest
              ];

              boot.kernelPackages = hostConfig.boot.kernelPackages;
              boot.zfs.package = hostConfig.boot.zfs.package;
              boot.supportedFilesystems = [ "zfs" ];
              boot.kernelModules = [ "zfs" ];
              # The host's socket-buffer default decides what the guest's
              # iptables can send; take it and the bridge sysctls verbatim.
              boot.kernel.sysctl = lib.filterAttrs (
                name: _: lib.hasPrefix "net.bridge.bridge-nf-call-" name || lib.hasPrefix "net.core." name
              ) hostConfig.boot.kernel.sysctl;
              networking.useNetworkd = hostConfig.networking.useNetworkd;
              networking.dhcpcd.enable = hostConfig.networking.dhcpcd.enable;
              networking.firewall.interfaces.${descriptor.network} =
                hostConfig.networking.firewall.interfaces.${descriptor.network};
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
                "network-policy /var/lib/incus-storage-pools.vdev"
            )
            fixture_host.succeed("zfs create -o mountpoint=${descriptor.poolPath} network-policy/incus-compute")
            console = "/dev/${
              (import "${pkgs.path}/nixos/lib/qemu-common.nix" {
                inherit (pkgs) lib stdenv;
              }).qemuSerialDevice
            }"
            fixture_host.succeed(f"echo 'Network policy serial output ready' > {console}")
            fixture_host.wait_for_console_text("Network policy serial output ready", timeout=10)
            fixture_host.copy_from_host("${scenario}", "/tmp/compute-network-policy-runtime.py")
            fixture_host.copy_from_host("${library}", "/tmp/prod_home_replacement.py")
            (status, _) = fixture_host.execute(
                "python3 -u /tmp/compute-network-policy-runtime.py"
                " --library /tmp/prod_home_replacement.py"
                " --bundle ${guestBundle}"
                " --helper ${computeGuest}/bin/compute-guest"
                " --image ${standInImage}"
                " --inputs ${inputs'}"
                f" < /dev/null > {console} 2>&1",
                timeout=90 * 60,
            )
            assert status == 0, "compute-network-policy-runtime scenario failed"
          '';
        };
      in
      {
        legacyPackages.compute-network-policy-runtime-test = test // {
          inherit guestBundle;
          inputs = inputs';
        };
        checks.compute-network-policy-runtime = test // {
          meta = test.meta // {
            hestia.group = "${system}-compute-network-policy-runtime";
          };
        };
      }
    );
}
