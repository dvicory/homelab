{
  config,
  den,
  inputs,
  lib,
  self,
  ...
}:
{
  # Upgrade acceptance for an existing compute guest: the guest is created
  # under the envelope the host declared before the media storage capability
  # existed, then the fixture host activates the current declaration with
  # switch-to-configuration and the guest is carried across. x86_64/KVM only.
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
        cluster = config.den.clusters.prod-home;
        hostEntity = config.den.hosts.${cluster.hostSystem}.${cluster.hostName};
        current = hostEntity.settings.virtualization.compute;
        mediaSecret = "jellyfin--jellyfin-admin--password";
        # The declaration before the media capability: no identity-mapped
        # GID, no media attachment, no Jellyfin retained path or credential.
        previous = current // {
          storageCapabilities = [ ];
          devices = removeAttrs current.devices [ "media" ];
          retainedPaths = removeAttrs current.retainedPaths [ "jellyfin-config" ];
          runtimeSecrets = removeAttrs current.runtimeSecrets [ mediaSecret ];
        };
        previousHost = hostEntity // {
          settings = hostEntity.settings // {
            virtualization = hostEntity.settings.virtualization // {
              compute = previous;
            };
          };
        };
        # Evaluate the same aspect code the host uses, with the earlier entity.
        computeAspect =
          (import ../den/aspects/virtualization/compute.nix {
            inherit
              den
              lib
              inputs
              config
              ;
          }).den.aspects.virtualization.compute.nixos;
        secretsAspect =
          (import ../den/aspects/services/kubernetes-runtime-secrets.nix {
            inherit den inputs lib;
          }).den.aspects.services."kubernetes-runtime-secrets".nixos;
        computeGuest = pkgs.callPackage (inputs.self + "/pkgs/by-name/compute-runtime/package.nix") { };
        guestBundle = guest.config.system.build.computeBundle;
        # Jellyfin's helper images are the only guest difference: the earlier
        # guest imports every other declared image at boot.
        helperImages = [
          self.packages.${system}.jellyfin-provisioner-image
          self.packages.${system}.jellarr-image
        ];
        previousGuest = guest.extendModules {
          modules = [
            {
              services.k3s.images = lib.mkForce (
                lib.filter (image: !(lib.elem image helperImages)) guest.config.services.k3s.images
              );
            }
          ];
        };
        previousBundle = previousGuest.config.system.build.computeBundle;
        descriptor = builtins.fromJSON hostConfig.environment.etc."homelab/compute.json".text;
        poolPath = descriptor.poolPath;
        scenario = ./compute-guest-upgrade.py;
        library = ./prod-home-replacement.py;
        # Replace the old map's override with a narrower one so the upgraded
        # declaration wins over the base declaration it inherits.
        upgraded = lib.mkOverride 40;

        test = pkgs.testers.runNixOSTest {
          name = "compute-guest-upgrade";
          globalTimeout = 2 * 60 * 60;
          requiredFeatures.kvm = true;

          nodes.fixture-host =
            {
              config,
              lib,
              pkgs,
              ...
            }:
            let
              before = computeAspect {
                host = previousHost;
                inherit config lib pkgs;
              };
              beforeSecrets = secretsAspect {
                host = previousHost;
                inherit lib pkgs;
              };
              reproduced = computeAspect {
                host = hostEntity;
                inherit config lib pkgs;
              };
              stageUnit = hostConfig.systemd.services.compute-stage-secrets;
            in
            {
              system.stateVersion = "26.05";
              networking.hostId = "c057a9e3";
              users.groups.media.gid = 505;

              # The fixture's aspect evaluation must reproduce the host's
              # descriptor exactly, or the earlier declaration is not
              # derived from the same code.
              assertions = [
                {
                  assertion =
                    reproduced.environment.etc."homelab/compute.json".text
                    == hostConfig.environment.etc."homelab/compute.json".text;
                  message = "compute aspect re-evaluation does not reproduce the host descriptor";
                }
              ];

              virtualisation = {
                cores = 4;
                memorySize = 5120;
                diskSize = 65536;
                useNixStoreImage = true;
                writableStore = true;
                writableStoreUseTmpfs = false;
                additionalPaths = [
                  computeGuest
                  guestBundle
                  previousBundle
                ]
                ++ helperImages;
                incus = {
                  enable = true;
                  package = hostConfig.virtualisation.incus.package;
                  inherit (before.virtualisation.incus) preseed;
                };
              };

              # The earlier declaration, verbatim from the aspect.
              environment.etc."homelab/compute.json" = before.environment.etc."homelab/compute.json";
              users.users.root.subGidRanges = before.users.users.root.subGidRanges;
              systemd.services.incus-preseed.serviceConfig.ExecStart =
                before.systemd.services.incus-preseed.serviceConfig.ExecStart;
              # Production starts these with the host; the scenario starts them
              # after the disposable pool and inputs exist.
              systemd.services.incus-preseed.wantedBy = lib.mkForce [ ];
              systemd.services.compute-stage-secrets = {
                inherit (beforeSecrets.systemd.services.compute-stage-secrets)
                  description
                  path
                  serviceConfig
                  script
                  ;
              };

              # The current declaration: exactly what hvn-hyp1 activates.
              specialisation.upgraded.configuration = {
                environment.etc."homelab/compute.json".text =
                  upgraded
                    hostConfig.environment.etc."homelab/compute.json".text;
                users.users.root.subGidRanges = upgraded hostConfig.users.users.root.subGidRanges;
                virtualisation.incus.preseed = upgraded hostConfig.virtualisation.incus.preseed;
                systemd.services.incus-preseed.serviceConfig.ExecStart =
                  upgraded hostConfig.systemd.services.incus-preseed.serviceConfig.ExecStart;
                systemd.services.compute-stage-secrets = {
                  path = upgraded stageUnit.path;
                  script = upgraded stageUnit.script;
                };
              };

              environment.systemPackages = [
                pkgs.coreutils
                pkgs.findutils
                pkgs.jq
                pkgs.openssh
                pkgs.python3
                pkgs.util-linux
                hostConfig.boot.zfs.package
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
            fixture_host.succeed("mkdir -p ${poolPath}")
            fixture_host.succeed("truncate -s 28G /var/lib/incus-storage-pools.vdev")
            fixture_host.succeed(
                "zpool create -f -o ashift=12 -O mountpoint=none "
                "compute-upgrade /var/lib/incus-storage-pools.vdev"
            )
            fixture_host.succeed("zfs create -o mountpoint=${poolPath} compute-upgrade/incus-compute")
            console = "/dev/${
              (import "${pkgs.path}/nixos/lib/qemu-common.nix" {
                inherit (pkgs) lib stdenv;
              }).qemuSerialDevice
            }"
            fixture_host.succeed(f"echo 'Upgrade serial output ready' > {console}")
            fixture_host.wait_for_console_text("Upgrade serial output ready", timeout=10)
            fixture_host.copy_from_host("${scenario}", "/tmp/compute-guest-upgrade.py")
            fixture_host.copy_from_host("${library}", "/tmp/prod_home_replacement.py")
            (status, _) = fixture_host.execute(
                "python3 -u /tmp/compute-guest-upgrade.py"
                " --library /tmp/prod_home_replacement.py"
                " --previous-bundle ${previousBundle}"
                " --bundle ${guestBundle}"
                " --helper ${computeGuest}/bin/compute-guest"
                " --images ${lib.concatStringsSep "," (map toString helperImages)}"
                " --upgraded /run/current-system/specialisation/upgraded"
                f" < /dev/null > {console} 2>&1",
                timeout=2 * 60 * 60,
            )
            assert status == 0, "compute-guest-upgrade scenario failed"
          '';
        };
      in
      {
        legacyPackages.compute-guest-upgrade-test = test // {
          inherit guestBundle previousBundle;
          previousGuestSystem = previousGuest.config.system.build.toplevel;
          previousDescriptor =
            (computeAspect {
              host = previousHost;
              config = hostConfig;
              inherit lib pkgs;
            }).environment.etc."homelab/compute.json".text;
        };
        checks.compute-guest-upgrade = test // {
          meta = test.meta // {
            hestia.group = "${system}-compute-guest-upgrade";
          };
        };
      }
    );
}
