# Behaviour test: NetworkPolicy enforcement in the unprivileged compute guest,
# by the committed kube-network-policies enforcer, and the migration to it
# from K3s's embedded controller.
#
# The fixture host runs the evaluated host's Incus envelope, kernel and
# sysctls and creates the real compute guest through the production lifecycle
# helper. The guest receives every committed NetworkPolicy and Service, a
# stand-in Pod for each committed workload, and Pods that committed policies
# select until the node reaches its Pod limit. The enforcer's objects are the
# committed network-policy application, as Argo applies them; its image is
# pulled by digest from its registry.
#
# The scenario first runs the guest as one from before this change (K3s's
# embedded controller and kube-proxy in iptables mode, with the runtime
# send-buffer stopgap), migrates it in the runbook's order and requires that
# a Pod that must be refused never gets through. Then, at the kernel's default
# send buffer, after the migration and again after a guest restart (which drops
# the pre-change unit), it requires the representative boundaries (Kanidm's
# private policy, a Gateway backend policy, the media caller boundary), a new
# Pod's first connection to be decided by policy, a ready enforcer whose
# metrics count verdicts, no kube-router rule, no failed restore, and working
# ClusterIP and NodePort forwarding. After the restart kube-proxy must run in
# nftables mode with its whole table accepted at the default buffers. It also
# kills the enforcer and requires new connections to be refused until it is
# back (fail-closed).
#
# Without the enforcer the stranger reaches radarr once K3s's controller is
# disabled, and the test fails. x86_64/KVM only; the enforcer image comes from
# its registry, so the builder must permit sandbox = relaxed.
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
          # The scenario's probe loops write their logs here.
          extraCommands = "mkdir -m 1777 tmp";
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
                --image ${standInImage.imageName}:${standInImage.imageTag} \
                --node-port ${toString config.den.clusters.prod-home.ingress.nodePort}
            '';
        scenario = ./compute-network-policy-runtime.py;
        # K3s's unit as a guest from before this change ran it: the embedded
        # network-policy controller on, and kube-proxy in iptables mode, read
        # from a copy of the guest's own kube-proxy configuration that the
        # scenario writes to /run inside the guest.
        k3sExecStart = guest.config.systemd.services.k3s.serviceConfig.ExecStart;
        proxyConfig = lib.head (
          lib.splitString " " (lib.elemAt (lib.splitString "--kube-proxy-arg=config=" k3sExecStart) 1)
        );
        beforeProxyConfig = "/run/k3s-kube-proxy-before-enforcer.json";
        withoutFlag =
          lib.replaceStrings
            [ " \\\n --disable-network-policy" proxyConfig ]
            [
              ""
              beforeProxyConfig
            ]
            k3sExecStart;
        oldUnit =
          assert lib.assertMsg (
            !lib.hasInfix "disable-network-policy" withoutFlag && lib.hasInfix beforeProxyConfig withoutFlag
          ) "the pre-change K3s unit must drop the flag and use the iptables kube-proxy configuration";
          pkgs.writeText "k3s-before-enforcer.conf" ''
            [Service]
            ExecStart=
            ExecStart=${builtins.unsafeDiscardStringContext withoutFlag}
          '';
        cleanup = ../den/aspects/kubernetes/_kube-router-cleanup.sh;
        # The contract is enforcement at the kernel's default send buffer, so
        # the fixture runs there even if the host ever raises it.
        kernelDefaultWmem = 212992;
        library = ./prod-home-replacement.py;
        test =
          (pkgs.testers.runNixOSTest {
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
                  # Sized for GitHub's hosted x86-64 runner (4 vCPUs, 16 GiB).
                  # With the node at its Pod limit the fixture host uses about
                  # 2.8 GiB besides page cache; more vCPUs than the runner has,
                  # or a larger guest, starves the runner until GitHub loses it.
                  cores = 4;
                  memorySize = 6144;
                  diskSize = 65536;
                  # The enforcer image is pulled by digest from its registry.
                  restrictNetwork = false;
                  useNixStoreImage = true;
                  writableStore = true;
                  writableStoreUseTmpfs = false;
                  additionalPaths = [
                    computeGuest
                    guestBundle
                    standInImage
                    inputs'
                    oldUnit
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
                  pkgs.curl
                  pkgs.findutils
                  pkgs.jq
                  pkgs.nftables
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
                # Take the host's bridge and socket-buffer sysctls verbatim,
                # except the send-buffer default, which stays at the kernel's.
                boot.kernel.sysctl =
                  lib.filterAttrs (
                    name: _: lib.hasPrefix "net.bridge.bridge-nf-call-" name || lib.hasPrefix "net.core." name
                  ) hostConfig.boot.kernel.sysctl
                  // {
                    "net.core.wmem_default" = kernelDefaultWmem;
                  };
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
              fixture_host.copy_from_host("${cleanup}", "/tmp/kube-router-cleanup.sh")
              (status, _) = fixture_host.execute(
                  "python3 -u /tmp/compute-network-policy-runtime.py"
                  " --library /tmp/prod_home_replacement.py"
                  " --bundle ${guestBundle}"
                  " --helper ${computeGuest}/bin/compute-guest"
                  " --image ${standInImage}"
                  " --inputs ${inputs'}"
                  " --old-unit ${oldUnit}"
                  " --proxy-config ${builtins.unsafeDiscardStringContext proxyConfig}"
                  " --before-proxy-config ${beforeProxyConfig}"
                  " --cleanup /tmp/kube-router-cleanup.sh"
                  " --kernel-default-wmem ${toString kernelDefaultWmem}"
                  f" < /dev/null > {console} 2>&1",
                  timeout=90 * 60,
              )
              assert status == 0, "compute-network-policy-runtime scenario failed"
            '';
          }).overrideTestDerivation
            (_: {
              # The enforcer image is pulled from its registry. Builders must
              # explicitly permit this with sandbox = relaxed.
              __noChroot = true;
            });
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
