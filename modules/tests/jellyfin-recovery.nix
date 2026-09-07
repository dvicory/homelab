{
  inputs,
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      guestSystem = builtins.replaceStrings [ "darwin" ] [ "linux" ] system;
      guestPkgs = inputs.nixpkgs.legacyPackages.${guestSystem};
      guest = self.nixosConfigurations.compute-1.extendModules {
        modules = [{
          nixpkgs.hostPlatform = lib.mkForce guestSystem;
          networking.firewall.allowedTCPPorts = lib.mkAfter [ 30096 ];
        }];
      };
      host = self.nixosConfigurations.hvn-hyp1.extendModules {
        modules = [ { nixpkgs.hostPlatform = lib.mkForce guestSystem; } ];
      };
      guestBundle = guest.config.system.build.computeBundle;
      hostConfig = host.config;
      descriptor = builtins.fromJSON hostConfig.environment.etc."homelab/compute.json".text;
      preseed = removeAttrs hostConfig.virtualisation.incus.preseed [ "config" ];
      mounts =
        map
          (mount: {
            inherit (mount)
              what
              where
              options
              bindsTo
              after
              ;
          })
          (
            lib.filter (
              mount: lib.hasPrefix "/run/homelab-compute/pinned-" mount.where
            ) hostConfig.systemd.mounts
          );
      nftables =
        lib.mapAttrsToList
          (name: table: {
            inherit name;
            inherit (table) family content;
          })
          (
            lib.filterAttrs (
              name: _:
              lib.elem name [
                "homelab-compute-boundary"
                "homelab-compute-bridge-boundary"
              ]
            ) hostConfig.networking.nftables.tables
          );
      fixture = pkgs.writeText "jellyfin-recovery-fixture.json" (
        builtins.toJSON {
          inherit
            descriptor
            preseed
            mounts
            nftables
            ;
          rootScript = hostConfig.systemd.services.compute-media-root.script;
          exportCommand = hostConfig.systemd.services.compute-media-export.serviceConfig.ExecStart;
          exportStop = hostConfig.systemd.services.compute-media-export.serviceConfig.ExecStop;
        }
      );
      scenario = ./jellyfin-recovery.py;
      computeGuest = guestPkgs.callPackage (inputs.self + "/pkgs/by-name/compute-guest/package.nix") { };
      image = self.packages.${guestSystem}.jellyfin-image;
      # Only this disposable fixture exposes a private NodePort. Production
      # keeps the shared chart's ClusterIP service behind the authenticated edge.
      application = (self.nixidyEnvs.${guestSystem}.prod-home.override (old: {
        modules = old.modules ++ [{
          applications.jellyfin.helm.releases.jellyfin.values = {
            service.main = {
              type = lib.mkForce "NodePort";
              ports.http.nodePort = 30096;
            };
            controllers.main = {
              initContainers.prepare.image = {
                tag = lib.mkForce (lib.last (lib.splitString ":" image.imageReference));
                pullPolicy = lib.mkForce "Never";
              };
              containers.main.image = {
                tag = lib.mkForce (lib.last (lib.splitString ":" image.imageReference));
                pullPolicy = lib.mkForce "Never";
              };
            };
          };
        }];
      })).config.build.environmentPackage;
      test = pkgs.testers.runNixOSTest {
        name = "jellyfin-recovery";
        globalTimeout = 4 * 60 * 60;

        nodes."compute-recovery" =
          { pkgs, ... }:
          {
            system.stateVersion = "26.05";

            virtualisation = {
              cores = 4;
              memorySize = 5120;
              diskSize = 24576;
              restrictNetwork = true;
              useNixStoreImage = true;
              writableStore = true;
              writableStoreUseTmpfs = false;
              additionalPaths = [
                computeGuest
                fixture
                guestBundle
                application
                image
              ];

              incus = {
                enable = true;
                package = hostConfig.virtualisation.incus.package;
                # The scenario deliberately exercises a fresh native preseed.
                preseed = null;
              };
            };

            environment.systemPackages = [
              pkgs.bash
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              pkgs.gnused
              pkgs.gnutar
              pkgs.iproute2
              pkgs.iputils
              pkgs.mergerfs
              pkgs.nftables
              pkgs.nix
              pkgs.openssh
              pkgs.python3
              pkgs.util-linux
              pkgs.xz
              computeGuest
            ];

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
          compute_recovery.wait_for_unit("incus.service", timeout=600)
          compute_recovery.copy_from_host_via_shell("${scenario}", "/tmp/jellyfin-recovery.py")
          compute_recovery.succeed(
              "python3 /tmp/jellyfin-recovery.py"
              " --bundle ${guestBundle}"
              " --fixture ${fixture}"
              " --application ${application}"
              " --image ${image}"
              " --helper ${computeGuest}/bin/compute-guest < /dev/null",
              timeout=4 * 60 * 60,
          )
        '';
      };
    in
    {
      # Run locally with native Apple virtualization; CI uses Linux KVM.
      legacyPackages.jellyfin-recovery-test = test // {
        # The same inputs can exercise the scenario in a disposable Linux VM.
        inherit fixture application image guestBundle;
      };
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        jellyfin-recovery = test // {
          meta = test.meta // {
            hestia.group = "${system}-jellyfin-runtime";
          };
        };
      };
    };
}
