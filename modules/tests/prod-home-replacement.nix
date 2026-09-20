{
  config,
  inputs,
  lib,
  self,
  ...
}:
{
  # The replacement acceptance runs the evaluated configuration natively for
  # x86_64-linux and aarch64-linux. Existing x86_64 uses production verbatim;
  # aarch64 is an explicitly hypothetical native fixture.
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs
      (lib.elem system [
        "x86_64-linux"
        "aarch64-linux"
      ])
      (
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
          poolPath = descriptor.poolPath;
          mergerfs = import ../den/aspects/services/_mergerfs.nix { inherit lib; };
          cluster = config.den.clusters.prod-home;
          mediaPoolPath = "${descriptor.devices.media.source}/data";
          mediaPoolUnit = hostConfig.systemd.services.${mergerfs.serviceNameFor mediaPoolPath};
          mediaPoolBranches =
            config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.services.mergerfs.pools.${mediaPoolPath}.branches;
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
                nftables
                bridgeAddress
                ;
              preseedCommand = hostConfig.systemd.services.incus-preseed.serviceConfig.ExecStart;
              preseedPath = lib.makeBinPath hostConfig.systemd.services.incus-preseed.path;
              mediaPool = {
                path = mediaPoolPath;
                branches = map (branch: branch.path) mediaPoolBranches;
                start = mediaPoolUnit.serviceConfig.ExecStart;
                stop = mediaPoolUnit.serviceConfig.ExecStop;
              };
              mediaRootScript = hostConfig.systemd.services.media-namespace.script;
              secretStageScript = hostConfig.systemd.services.compute-stage-secrets.script;
              secretStagePath = lib.makeBinPath hostConfig.systemd.services.compute-stage-secrets.path;
            }
          );
          scenario = ./prod-home-replacement.py;
          smoke = ./jellyfin_smoke.py;
          computeGuest = pkgs.callPackage (inputs.self + "/pkgs/by-name/compute-runtime/package.nix") { };
          guestBundle = guest.config.system.build.computeBundle;
          canonical = inputs.self + "/generated/manifests/prod-home";
          seedManifests = self.packages.${system}.household-bootstrap-manifests;
          # Canonical seed inputs are Argo namespace, CRDs, controllers and root
          # handoff only; Jellyfin and Argo workloads remain pinned registry
          # images from the canonical manifests, with no fixture image rewrites.
          # The scenario copies them into disposable local inputs.
          testRepo = pkgs.runCommand "prod-home-recovery-repo" { } ''
            mkdir -p "$out"/{apps,jellyfin,jellyfin-retained}
            cp ${canonical}/apps/Application-jellyfin.yaml ${canonical}/apps/Application-jellyfin-retained.yaml "$out/apps/"
            cp ${canonical}/jellyfin/*.yaml "$out/jellyfin/"
            cp ${canonical}/jellyfin-retained/*.yaml "$out/jellyfin-retained/"
            cp ${canonical}/bootstrap.yaml "$out/canonical-bootstrap.yaml"
          '';
          # The shipped seed tree with only the root Application swapped for the
          # fixture origin. This is the dependency-injection seam: the same
          # household-bootstrap-host implementation runs against fixture
          # manifests without a recovery-specific code path.
          testSeed = pkgs.runCommand "prod-home-test-seed" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
            mkdir -p "$out"
            cp ${seedManifests}/* "$out/"
            chmod -R u+w "$out"
            yq -i '
              .metadata.name = "recovery-test-apps"
              | .spec.source.repoURL = "git://${bridgeAddress}/recovery.git"
              | .spec.source.path = "./apps"
            ' "$out/root.yaml"
          '';
          bootstrapHost = self.packages.${system}.household-bootstrap-host;
          test =
            (pkgs.testers.runNixOSTest {
              name = "prod-home-replacement";
              globalTimeout = 4 * 60 * 60;
              # Hosted ARM runners lack KVM; retain the accelerator requirement elsewhere.
              requiredFeatures.kvm = system != "aarch64-linux";

              nodes.fixture-host =
                { pkgs, ... }:
                {
                  system.stateVersion = "26.05";
                  networking.hostId = "c057a9e2";

                  # Production hosts materialize the storage-capability groups
                  # from the group registry; the media-namespace layout script
                  # installs paths owned by group media (GID 505, see
                  # modules/den/groups/default.nix).
                  users.groups.media.gid = 505;

                  # Keep the fixture's subordinate authorization explicit for
                  # the compute range and identity-mapped capability GIDs.
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
                    diskSize = 65536;
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
                    hostConfig.boot.zfs.package
                    pkgs.xz
                    pkgs.yq-go
                    computeGuest
                  ];

                  # Exercise the exact production substrate rather than the
                  # nixpkgs default kernel/filesystem packages.
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
                fixture_host.succeed("modprobe zfs")
                fixture_host.succeed("mkdir -p ${poolPath}")
                fixture_host.succeed("truncate -s 28G /var/lib/incus-storage-pools.vdev")
                fixture_host.succeed(
                    "zpool create -f -o ashift=12 -O mountpoint=none "
                    "prod-home-replacement /var/lib/incus-storage-pools.vdev"
                )
                fixture_host.succeed(
                    "zfs create -o mountpoint=${poolPath} "
                    "prod-home-replacement/incus-compute"
                )
                fixture_host.succeed(
                    "findmnt -n -o FSTYPE -M ${poolPath} | grep -qx zfs"
                )
                fixture_host.succeed(
                    "findmnt -n -o SOURCE -M ${poolPath} | grep -qx "
                    "prod-home-replacement/incus-compute"
                )
                console = "/dev/${
                  (import "${pkgs.path}/nixos/lib/qemu-common.nix" {
                    inherit (pkgs) lib stdenv;
                  }).qemuSerialDevice
                }"
                fixture_host.succeed(f"echo 'Replacement serial output ready' > {console}")
                fixture_host.wait_for_console_text("Replacement serial output ready", timeout=10)
                fixture_host.copy_from_host("${scenario}", "/tmp/prod-home-replacement.py")
                fixture_host.copy_from_host("${smoke}", "/tmp/jellyfin_smoke.py")
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
          # The same inputs can exercise the scenario on a disposable native
          # x86_64 or aarch64 Linux host.
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
