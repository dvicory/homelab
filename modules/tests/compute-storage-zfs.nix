{
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
        production = self.nixosConfigurations.hvn-hyp1.config;
        guest = self.nixosConfigurations.compute-1;
        guestBundle =
          snapshotter:
          (guest.extendModules {
            modules = [
              {
                # Test-only fixture override. Production remains native.
                services.k3s.extraFlags = lib.mkForce [ "--snapshotter=${snapshotter}" ];
              }
            ];
          }).config.system.build.computeBundle;
        nativeBundle = guestBundle "native";
        overlayBundle = guestBundle "overlayfs";
        scenario = ./compute-storage-zfs.py;
        manifests = inputs.self + "/generated/manifests/prod-home/jellyfin";
        test =
          (pkgs.testers.runNixOSTest {
            name = "compute-storage-zfs";
            globalTimeout = 2 * 60 * 60;

            nodes.fixture-host =
              { ... }:
              {
                system.stateVersion = "26.05";
                networking.hostName = "fixture-host";
                networking.hostId = "c057a9e1";
                networking.nftables.enable = true;
                networking.firewall.interfaces = lib.genAttrs [ "sp-native" "sp-overlayfs" ] (_: {
                  allowedTCPPorts = [ 53 ];
                  allowedUDPPorts = [
                    53
                    67
                  ];
                });

                # Exercise the exact production substrate rather than the
                # nixpkgs default kernel/filesystem packages.
                boot.kernelPackages = production.boot.kernelPackages;
                boot.zfs.package = production.boot.zfs.package;
                boot.supportedFilesystems = [ "zfs" ];
                boot.kernelModules = [ "zfs" ];

                # Incus obtains two isolated guest maps from NixOS-generated
                # subordinate files. The scenario only reads and compares them.
                users.users.root.subUidRanges = [
                  {
                    startUid = 2000000000;
                    count = 131072;
                  }
                ];
                users.users.root.subGidRanges = [
                  {
                    startGid = 2000000000;
                    count = 131072;
                  }
                ];

                virtualisation = {
                  cores = 4;
                  memorySize = 5120;
                  diskSize = 65536;
                  restrictNetwork = false;
                  useNixStoreImage = true;
                  writableStore = true;
                  writableStoreUseTmpfs = false;
                  additionalPaths = [
                    nativeBundle
                    overlayBundle
                    manifests
                    scenario
                  ];
                  incus = {
                    enable = true;
                    package = production.virtualisation.incus.package;
                    preseed = null;
                  };
                };

                environment.systemPackages = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.gnused
                  pkgs.jq
                  pkgs.kubectl
                  pkgs.python3
                  pkgs.util-linux
                  production.boot.zfs.package
                  production.virtualisation.incus.package
                ];

                systemd.tmpfiles.rules = [
                  "d /var/lib/compute-storage-zfs 0755 root root -"
                ];
              };

            testScript = ''
              start_all()
              fixture_host.wait_for_unit("multi-user.target", timeout=600)
              fixture_host.wait_for_unit("incus.service", timeout=600)
              fixture_host.succeed("modprobe zfs")
              fixture_host.succeed("mkdir -p /var/lib/compute-storage-zfs/native /var/lib/compute-storage-zfs/overlayfs")
              fixture_host.succeed("truncate -s 28G /var/lib/compute-storage-zfs.vdev")
              fixture_host.succeed(
                  "zpool create -f -o ashift=12 -O mountpoint=none compute-storage /var/lib/compute-storage-zfs.vdev"
              )
              fixture_host.succeed(
                  "zfs create -o mountpoint=/var/lib/compute-storage-zfs/native compute-storage/native"
              )
              fixture_host.succeed(
                  "zfs create -o mountpoint=/var/lib/compute-storage-zfs/overlayfs compute-storage/overlayfs"
              )
              fixture_host.succeed("findmnt -n -o FSTYPE /var/lib/compute-storage-zfs/native | grep -qx zfs")
              fixture_host.succeed("findmnt -n -o FSTYPE /var/lib/compute-storage-zfs/overlayfs | grep -qx zfs")
              console = "/dev/ttyS0"
              fixture_host.succeed(f"echo 'Compute storage serial output ready' > {console}")
              fixture_host.wait_for_console_text("Compute storage serial output ready", timeout=10)
              fixture_host.copy_from_host_via_shell("${scenario}", "/tmp/compute-storage-zfs.py")
              (status, _) = fixture_host.execute(
                  "python3 -u /tmp/compute-storage-zfs.py"
                  " --native-bundle ${nativeBundle}"
                  " --overlay-bundle ${overlayBundle}"
                  " --manifests ${manifests}"
                  " --pool-root /var/lib/compute-storage-zfs"
                  " --output /tmp/compute-storage-zfs-evidence"
                  " --observe-seconds 180"
                  f" < /dev/null > {console} 2>&1",
                  timeout=2 * 60 * 60,
              )
              fixture_host.copy_from_machine("/tmp/compute-storage-zfs-evidence", "evidence")
              assert status == 0, "compute-storage-zfs scenario failed"
            '';
          }).overrideTestDerivation
            (_: {
              # Jellyfin is deliberately pulled from its canonical registry
              # manifest; builders must permit this online check explicitly.
              __noChroot = true;
            });
      in
      {
        legacyPackages.compute-storage-zfs-test = test // {
          inherit nativeBundle overlayBundle manifests;
        };
        checks.compute-storage-zfs = test // {
          meta = test.meta // {
            hestia.group = "${system}-compute-storage-zfs";
          };
        };
      }
    );
}
