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
        modules = [
          {
            nixpkgs.hostPlatform = lib.mkForce guestSystem;
            # Test access only: the scenario port-forwards the canonical
            # ClusterIP service to the guest address for API verification.
            networking.firewall.allowedTCPPorts = lib.mkAfter [ 8096 ];
          }
        ];
      };
      host = self.nixosConfigurations.hvn-hyp1.extendModules {
        modules = [ { nixpkgs.hostPlatform = lib.mkForce guestSystem; } ];
      };
      guestBundle = guest.config.system.build.computeBundle;
      hostConfig = host.config;
      descriptor = builtins.fromJSON hostConfig.environment.etc."homelab/compute.json".text;
      preseed = removeAttrs hostConfig.virtualisation.incus.preseed [ "config" ];
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
            nftables
            ;
          mediaPool = {
            start = hostConfig.systemd.services."mergerfs-mnt-srv-media".serviceConfig.ExecStart;
            preStart = hostConfig.systemd.services."mergerfs-mnt-srv-media".serviceConfig.ExecStartPre;
            stop = hostConfig.systemd.services."mergerfs-mnt-srv-media".serviceConfig.ExecStop;
            environment = hostConfig.environment.etc."mergerfs/srv-media.conf".text;
          };
          mediaRootScript = hostConfig.systemd.services.media-namespace.script;
          secretStageScript = hostConfig.systemd.services.compute-stage-secrets.script;
          secretStagePath = lib.makeBinPath hostConfig.systemd.services.compute-stage-secrets.path;
        }
      );
      scenario = ./jellyfin-recovery.py;
      computeGuest = guestPkgs.callPackage (inputs.self + "/pkgs/by-name/compute-guest/package.nix") { };
      canonical = inputs.self + "/generated/manifests/prod-home";
      seed = self.packages.${guestSystem}.household-bootstrap-manifests;
      # Verbatim canonical inputs for the recovery test. The scenario copies
      # these into a disposable local Git origin; only the test-local root
      # Application and the fixture's repository URL are written at runtime.
      # No image fixture lives here: K3s pulls the pinned registry images.
      testRepo = pkgs.runCommand "jellyfin-recovery-repo" { } ''
        mkdir -p "$out"/{apps,jellyfin,jellyfin-retained,seed}
        cp ${canonical}/apps/Application-jellyfin.yaml ${canonical}/apps/Application-jellyfin-retained.yaml "$out/apps/"
        cp ${canonical}/jellyfin/*.yaml "$out/jellyfin/"
        cp ${canonical}/jellyfin-retained/*.yaml "$out/jellyfin-retained/"
        cp ${seed}/* "$out/seed/"
        cp ${canonical}/bootstrap.yaml "$out/canonical-bootstrap.yaml"
      '';
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
              # The recovery path pulls pinned registry images, so this
              # integration test keeps normal network access. Deterministic
              # contract checks stay in evaluation-time tests.
              restrictNetwork = false;
              useNixStoreImage = true;
              writableStore = true;
              writableStoreUseTmpfs = false;
              additionalPaths = [
                computeGuest
                fixture
                guestBundle
                testRepo
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
              pkgs.git
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
            # The disposable Git origin fixture serves the guest over the
            # Incus bridge; registry pulls use normal outbound access.
            networking.firewall.allowedTCPPorts = [ 9418 ];
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
              " --repo ${testRepo}"
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
        inherit fixture testRepo guestBundle;
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
