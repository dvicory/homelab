{
  inputs,
  lib,
  self,
  ...
}:
{
  # The replacement acceptance runs real x86_64 production evaluations
  # (hvn-hyp1, compute-1) inside an x86_64 fixture-host VM. No architecture
  # synthesis, no hostPlatform forcing: other systems get no such test.
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        hostConfig = self.nixosConfigurations.hvn-hyp1.config;
        descriptor = builtins.fromJSON hostConfig.environment.etc."homelab/compute.json".text;
        preseed = removeAttrs hostConfig.virtualisation.incus.preseed [ "config" ];
        bridgeAddress = lib.head (lib.splitString "/" descriptor.networkConfig."ipv4.address");
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
        fixture = pkgs.writeText "prod-home-replacement-fixture.json" (
          builtins.toJSON {
            inherit
              descriptor
              preseed
              nftables
              bridgeAddress
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
        scenario = ./prod-home-replacement.py;
        smoke = ./jellyfin_smoke.py;
        computeGuest = pkgs.callPackage (inputs.self + "/pkgs/by-name/compute-guest/package.nix") { };
        guestBundle = self.nixosConfigurations.compute-1.config.system.build.computeBundle;
        canonical = inputs.self + "/generated/manifests/prod-home";
        seedManifests = self.packages.${system}.household-bootstrap-manifests;
        # Verbatim canonical inputs for the recovery test. The scenario copies
        # these into a disposable local Git origin; K3s pulls the pinned
        # registry images over the network, so no image fixture lives here.
        testRepo = pkgs.runCommand "prod-home-recovery-repo" { } ''
          mkdir -p "$out"/{apps,jellyfin,jellyfin-retained}
          cp ${canonical}/apps/Application-jellyfin.yaml ${canonical}/apps/Application-jellyfin-retained.yaml "$out/apps/"
          cp ${canonical}/jellyfin/*.yaml "$out/jellyfin/"
          cp ${canonical}/jellyfin-retained/*.yaml "$out/jellyfin-retained/"
          cp ${canonical}/bootstrap.yaml "$out/canonical-bootstrap.yaml"
          cp ${canonical}/radarr/Deployment-radarr.yaml "$out/writer-fixture.yaml"
        '';
        # The shipped seed tree with only the root Application swapped for the
        # fixture origin. This is the dependency-injection seam: the same
        # household-bootstrap-host implementation runs against fixture
        # manifests without a recovery-specific code path.
        testSeed = pkgs.runCommand "prod-home-test-seed" { } ''
          mkdir -p "$out"
          cp ${seedManifests}/* "$out/"
          chmod -R u+w "$out"
          cat > "$out/root.yaml" <<EOF
          apiVersion: argoproj.io/v1alpha1
          kind: Application
          metadata:
            name: recovery-test-apps
            namespace: argocd
          spec:
            destination:
              namespace: argocd
              server: https://kubernetes.default.svc
            project: default
            source:
              repoURL: git://${bridgeAddress}/recovery.git
              targetRevision: main
              path: ./apps
            syncPolicy:
              automated:
                prune: true
                selfHeal: true
              syncOptions:
                - ServerSideApply=true
          EOF
        '';
        bootstrapHost = self.packages.${system}.household-bootstrap-host;
        test =
          (pkgs.testers.runNixOSTest {
            name = "prod-home-replacement";
            globalTimeout = 4 * 60 * 60;

            nodes.fixture-host =
              { pkgs, ... }:
              {
                system.stateVersion = "26.05";

                # Production hosts materialize the storage-capability groups
                # from the group registry; the media-namespace layout script
                # installs paths owned by group media (GID 505, see
                # modules/den/groups/default.nix).
                users.groups.media.gid = 505;

                # The lifecycle helper requires root subordinate coverage for
                # the compute range and every identity-mapped capability GID.
                # NixOS defaults provide neither, so declare both from the
                # same descriptor the helper verifies against.
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
                    testSeed
                    bootstrapHost
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
                  pkgs.jq
                  pkgs.kubectl
                  pkgs.mergerfs
                  pkgs.nftables
                  pkgs.nix
                  pkgs.openssh
                  pkgs.python3
                  pkgs.util-linux
                  pkgs.xz
                  pkgs.yq-go
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
              fixture_host.wait_for_unit("incus.service", timeout=600)
              console = "/dev/ttyS0"
              fixture_host.succeed(f"echo 'Replacement serial output ready' > {console}")
              fixture_host.wait_for_console_text("Replacement serial output ready", timeout=10)
              fixture_host.copy_from_host_via_shell("${scenario}", "/tmp/prod-home-replacement.py")
              fixture_host.copy_from_host_via_shell("${smoke}", "/tmp/jellyfin_smoke.py")
              # The driver streams the VM console while execute waits for exit.
              (status, _) = fixture_host.execute(
                  "python3 -u /tmp/prod-home-replacement.py"
                  " --bundle ${guestBundle}"
                  " --fixture ${fixture}"
                  " --repo ${testRepo}"
                  " --seed ${testSeed}"
                  " --smoke /tmp/jellyfin_smoke.py"
                  " --bootstrap-host ${bootstrapHost}/bin/household-bootstrap-host"
                  " --helper ${computeGuest}/bin/compute-guest"
                  f" < /dev/null > {console} 2>&1",
                  timeout=4 * 60 * 60,
              )
              assert status == 0, "prod-home-replacement scenario failed"
            '';
          }).overrideTestDerivation
            (_: {
              # Registry pulls are part of this online recovery acceptance.
              # Builders must explicitly permit this with sandbox = relaxed.
              __noChroot = true;
            });
      in
      {
        # The same inputs can exercise the scenario on a disposable x86_64 Linux host.
        legacyPackages.prod-home-replacement-test = test // {
          inherit
            fixture
            testRepo
            testSeed
            guestBundle
            ;
        };
        checks.prod-home-replacement = test // {
          meta = test.meta // {
            hestia.group = "${system}-prod-home-replacement";
          };
        };
      }
    );
}
