{ lib, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    lib.optionalAttrs
      (lib.elem system [
        "x86_64-linux"
        "aarch64-linux"
      ])
      (
        let
          coordinator = config.packages.homelab-preserve;
          adapter = config.packages.homelab-preserve-zfs-reference;

          zfsReference = role: simulateReceiveFailure: {
            referenceOnly = true;
            inherit role simulateReceiveFailure;
            sourceRoot = "source";
            sourceDataset = "source/state";
            sourceMountRoot = "/source";
            receiverRoot = "receiver/copies";
            scratchRoot = "receiver/scratch";
            scratchMountRoot = "/restore";
          };

          integration = id: {
            integrationId = "zfs-reference-${id}";
            owner = "zfs-reference";
            adapter = "${adapter}/bin/homelab-preserve-zfs-reference";
            protocolVersion = 1;
            timeoutSeconds = 120;
            maxResponseBytes = 1048576;
            fixtureOnly = true;
            operations = [
              "describe"
              "status"
              "points"
              "run"
              "restore"
              "verify"
            ];
            fidelityGuarantees = [
              "posix-filesystem"
              "zfs-dataset"
            ];
            guaranteedConsistency = "filesystem";
            nativePointRepresentations = [ "openzfs.snapshot" ];
            payloadRepresentation = null;
          };

          route =
            {
              id,
              targetId,
              domain,
              role,
              simulateReceiveFailure,
            }:
            {
              routeId = id;
              obligationId = "fixture/state::${id}";
              target = {
                inherit targetId;
                failureDomain = {
                  site = "fixture";
                  inherit domain;
                };
              };
              integration = integration id;
              operation = "run";
              eligibleIntegrations = [ "zfs-reference-${id}" ];
              semanticRequirements = {
                dataKind = "filesystem";
                requiredConsistency = "filesystem";
                routeRequiredConsistency = null;
                requiredFidelity = [ "posix-filesystem" ];
                acceptedPayloadFormats = [ ];
              };
              guaranteedConsistency = "filesystem";
              payloadRepresentation = null;
              nativePointRepresentations = [ "openzfs.snapshot" ];
              ownerConfig = {
                source = {
                  subpath = null;
                  include = [ ];
                  exclude = [ ];
                };
                native.zfsReference = zfsReference role simulateReceiveFailure;
              };
              status = "resolved";
              issues = [ ];
            };

          mkManifest = simulateReceiveFailure: {
            schemaVersion = 1;
            kind = "executable-plan";
            fixtureOnly = true;
            scratchDestinations.scratch = {
              nativeParent = "receiver/scratch";
              mountRoot = "/restore";
            };
            states = [
              {
                stateId = "fixture/state";
                mode = "enabled";
                operational = true;
                realization = {
                  kind = "zfs-dataset";
                  owner = {
                    kind = "host";
                    id = "preserve-zfs-vm";
                  };
                  locator = "source/state";
                  path = "/source";
                  capabilities = [
                    "filesystem-read"
                    "zfs-snapshot"
                    "zfs-send"
                  ];
                  boundary = {
                    recursive = false;
                    requiredChildren = [ ];
                    exclusions = [ ];
                  };
                  access = [ ];
                  physicalBacking = null;
                };
                routes = [
                  (route {
                    id = "local";
                    targetId = "local-target";
                    domain = "local-domain";
                    role = "local";
                    inherit simulateReceiveFailure;
                  })
                  (route {
                    id = "replica";
                    targetId = "replica-target";
                    domain = "replica-domain";
                    role = "replica";
                    inherit simulateReceiveFailure;
                  })
                ];
                issues = [ ];
              }
            ];
          };

          manifest = pkgs.writeText "preserve-zfs-manifest.json" (builtins.toJSON (mkManifest false));
          failManifest = pkgs.writeText "preserve-zfs-fail-manifest.json" (builtins.toJSON (mkManifest true));

          test = (
            pkgs.testers.runNixOSTest {
              name = "preserve-zfs-reference";
              globalTimeout = 60 * 60;
              requiredFeatures.kvm = system != "aarch64-linux";

              nodes.machine =
                { config, pkgs, ... }:
                {
                  system.stateVersion = "26.05";
                  networking.hostName = "preserve-zfs-reference";
                  networking.hostId = "7a3f9c21";

                  boot.supportedFilesystems = [ "zfs" ];
                  boot.kernelModules = [ "zfs" ];
                  boot.zfs.forceImportRoot = false;

                  virtualisation = {
                    cores = 2;
                    memorySize = 4096;
                    emptyDiskImages = [
                      4096
                      4096
                    ];
                    additionalPaths = [
                      manifest
                      failManifest
                    ];
                  };

                  environment.systemPackages = [
                    coordinator
                    adapter
                    pkgs.acl
                    pkgs.attr
                    pkgs.coreutils
                    pkgs.findutils
                    pkgs.gawk
                    pkgs.gnugrep
                    pkgs.jq
                    pkgs.util-linux
                    config.boot.zfs.package
                  ];
                };

              testScript = ''
                import json

                machine.start()
                machine.wait_for_unit("multi-user.target", timeout=600)
                machine.succeed("modprobe zfs")

                def sh(command):
                    return machine.succeed(command).strip()

                def report_points(report):
                    assert report["kind"] == "points", report
                    assert report["stateId"] == "fixture/state", report
                    assert all(route["status"] == "ok" for route in report["routes"]), report
                    return [point for route in report["routes"] for point in route["points"]]

                machine.succeed("zpool create -f -o ashift=12 -O mountpoint=none source /dev/vdb")
                machine.succeed("zpool create -f -o ashift=12 -O mountpoint=none receiver /dev/vdc")
                machine.succeed(
                    "zfs create -o mountpoint=/source -o xattr=sa -o acltype=posixacl source/state"
                )
                machine.succeed(
                    "zfs create -o mountpoint=none -o canmount=off -o sharenfs=off -o sharesmb=off"
                    " receiver/copies"
                )
                machine.succeed(
                    "zfs create -o mountpoint=/restore -o sharenfs=off -o sharesmb=off receiver/scratch"
                )
                machine.wait_for_file("/source")
                machine.wait_for_file("/restore")

                machine.succeed("mkdir -p /source/nested/dir")
                machine.succeed("printf 'regular-bytes-v1' > /source/regular.txt")
                machine.succeed("printf 'nested-bytes-v1' > /source/nested/dir/inner.txt")
                machine.succeed("ln -s regular.txt /source/rel-link")
                machine.succeed("ln /source/regular.txt /source/hard-link")
                machine.succeed("chown 1234:1234 /source/regular.txt")
                machine.succeed("chmod 640 /source/regular.txt")
                machine.succeed("chmod 750 /source/nested")
                machine.succeed("setfacl -m u:2345:r /source/regular.txt")
                machine.succeed("setfattr -n user.fixture -v fixture-xattr-value /source/regular.txt")
                machine.succeed("truncate -s 64M /source/sparse.bin")
                machine.succeed(
                    "dd if=/dev/urandom of=/source/sparse.bin bs=4k count=8 conv=notrunc status=none"
                )
                machine.succeed("zfs create source/state/nested-dataset")
                machine.succeed(
                    "printf 'nested-dataset-sentinel' > /source/nested-dataset/sentinel.txt"
                )

                oracle = {
                    "regular_sha": sh("sha256sum /source/regular.txt | cut -d' ' -f1"),
                    "inner_sha": sh("sha256sum /source/nested/dir/inner.txt | cut -d' ' -f1"),
                    "regular_stat": sh("stat -c '%u:%g:%a' /source/regular.txt"),
                    "nested_mode": sh("stat -c '%a' /source/nested"),
                    "link_target": sh("readlink /source/rel-link"),
                    "acl": sh("getfacl -c /source/regular.txt | grep 'user:2345'"),
                    "xattr": sh(
                        "getfattr -n user.fixture --only-values /source/regular.txt"
                    ),
                    "sparse_size": int(sh("stat -c %s /source/sparse.bin")),
                    "sparse_blocks": int(sh("du -B1 /source/sparse.bin | cut -f1")),
                }
                assert oracle["sparse_blocks"] < oracle["sparse_size"] // 8

                status_empty = json.loads(
                    sh("homelab-preserve --manifest ${manifest} --json status --observe")
                )
                empty_routes = status_empty["states"][0]["routes"]
                assert all(route["observed"] and route["pointCount"] == 0 for route in empty_routes), empty_routes

                sh("homelab-preserve --manifest ${manifest} --json run fixture/state --route replica")

                machine.succeed("printf 'regular-bytes-v2' > /source/regular.txt")
                machine.succeed("printf 'nested-bytes-v2' > /source/nested/dir/inner.txt")
                machine.succeed("printf 'added-in-v2' > /source/v2-only.txt")

                sh("homelab-preserve --manifest ${manifest} --json run fixture/state --route replica")

                points = report_points(
                    json.loads(
                        sh("homelab-preserve --manifest ${manifest} --json points fixture/state")
                    )
                )
                local = sorted(
                    (point for point in points if point["routeId"] == "local"),
                    key=lambda point: point["captureId"],
                )
                replica = sorted(
                    (point for point in points if point["routeId"] == "replica"),
                    key=lambda point: point["captureId"],
                )
                assert len(local) == 2, points
                assert len(replica) == 2, points
                assert [point["captureId"] for point in local] == [
                    point["captureId"] for point in replica
                ]
                assert all(point["completion"] == "complete" for point in points)
                assert all(point["consistency"] == "filesystem" for point in points)
                assert all(
                    point["nativeRepresentation"]["kind"] == "openzfs.snapshot"
                    for point in points
                )
                assert all(point["payloadRepresentation"] is None for point in points)
                assert all(point["owner"] == "zfs-reference" for point in points)
                assert all(len(point["nativeId"]) > 0 for point in points)

                status_full = json.loads(
                    sh("homelab-preserve --manifest ${manifest} --json status --observe")
                )
                full_routes = {
                    route["routeId"]: route for route in status_full["states"][0]["routes"]
                }
                assert full_routes["local"]["pointCount"] == 2
                assert full_routes["replica"]["pointCount"] == 2

                old_capture = local[0]["captureId"]
                older = next(point for point in replica if point["captureId"] == old_capture)

                def snapshot_inventory():
                    return sh(
                        "zfs list -r -t snapshot -o name,guid,creation"
                        " source/state receiver/copies | sort"
                    )

                retained_before = snapshot_inventory()

                sh(
                    "homelab-preserve --manifest ${manifest} restore fixture/state"
                    " --from replica --point " + older["nativeId"]
                    + " --to scratch:scratch1 --execute --receipt /root/receipt1.json"
                )
                sh("homelab-preserve --manifest ${manifest} --json verify /root/receipt1.json")

                def check_restored(path):
                    assert sh(f"sha256sum {path}/regular.txt | cut -d' ' -f1") == oracle["regular_sha"]
                    assert (
                        sh(f"sha256sum {path}/nested/dir/inner.txt | cut -d' ' -f1")
                        == oracle["inner_sha"]
                    )
                    assert sh(f"stat -c '%u:%g:%a' {path}/regular.txt") == oracle["regular_stat"]
                    assert sh(f"stat -c '%a' {path}/nested") == oracle["nested_mode"]
                    assert sh(f"stat -c '%i' {path}/regular.txt") == sh(
                        f"stat -c '%i' {path}/hard-link"
                    )
                    assert sh(f"readlink {path}/rel-link") == oracle["link_target"]
                    assert oracle["acl"] in sh(f"getfacl -c {path}/regular.txt")
                    assert (
                        sh(f"getfattr -n user.fixture --only-values {path}/regular.txt")
                        == "fixture-xattr-value"
                    )
                    assert int(sh(f"stat -c %s {path}/sparse.bin")) == oracle["sparse_size"]
                    assert int(sh(f"du -B1 {path}/sparse.bin | cut -f1")) < oracle["sparse_size"] // 8
                    assert sh(
                        f"test -e {path}/nested-dataset/sentinel.txt && echo present || echo absent"
                    ) == "absent"
                    assert sh(
                        f"test -e {path}/v2-only.txt && echo present || echo absent"
                    ) == "absent"

                check_restored("/restore/scratch1")

                sh(
                    "homelab-preserve --manifest ${manifest} restore fixture/state"
                    " --from replica --point " + older["nativeId"]
                    + " --to scratch:scratch2 --execute --receipt /root/receipt2.json"
                )
                sh("homelab-preserve --manifest ${manifest} --json verify /root/receipt2.json")
                check_restored("/restore/scratch2")

                assert snapshot_inventory() == retained_before

                machine.succeed("printf 'tampered' > /restore/scratch1/regular.txt")
                machine.fail(
                    "homelab-preserve --manifest ${manifest} verify /root/receipt1.json"
                )

                machine.fail(
                    "homelab-preserve --manifest ${failManifest} --json run fixture/state"
                    " --route replica"
                )
                after_failure = report_points(
                    json.loads(
                        sh("homelab-preserve --manifest ${manifest} --json points fixture/state")
                    )
                )
                local_after = [p for p in after_failure if p["routeId"] == "local"]
                replica_after = [p for p in after_failure if p["routeId"] == "replica"]
                assert len(local_after) == 3, after_failure
                assert len(replica_after) == 2, after_failure
                assert all(point["completion"] == "complete" for point in after_failure)

                machine.fail(
                    "homelab-preserve --manifest ${manifest} restore fixture/state"
                    " --from replica --point " + older["nativeId"]
                    + " --to 'scratch:../escape' --execute --receipt /root/receipt-escape.json"
                )
                machine.fail(
                    "homelab-preserve --manifest ${manifest} restore fixture/state"
                    " --from replica --point " + older["nativeId"]
                    + " --to scratch:scratch2 --execute --receipt /root/receipt-again.json"
                )

                sh(
                    "jq '.states[0].routes[1].ownerConfig.native.zfsReference.referenceOnly = false'"
                    " ${manifest} > /root/not-reference.json"
                )
                machine.fail(
                    "homelab-preserve --manifest /root/not-reference.json run fixture/state"
                    " --route replica"
                )

                sh(
                    "jq '.scratchDestinations.scratch.nativeParent = \"receiver/copies\"'"
                    " ${manifest} > /root/alias-target.json"
                )
                machine.fail(
                    "homelab-preserve --manifest /root/alias-target.json restore fixture/state"
                    " --from replica --point " + older["nativeId"]
                    + " --to scratch:aliasdst --execute --receipt /root/receipt-alias.json"
                )
                assert sh(
                    "zfs list -o name receiver/copies/aliasdst >/dev/null 2>&1 && echo present || echo absent"
                ) == "absent"

                sh(
                    "jq '.scratchDestinations.scratch.nativeParent = \"elsewhere/scratch\"'"
                    " ${manifest} > /root/out-of-root.json"
                )
                machine.fail(
                    "homelab-preserve --manifest /root/out-of-root.json restore fixture/state"
                    " --from replica --point " + older["nativeId"]
                    + " --to scratch:outofroot --execute --receipt /root/receipt-oor.json"
                )

                sh(
                    "jq '.scratchDestinations.scratch.nativeParent = \"source/state\" |"
                    " .scratchDestinations.scratch.mountRoot = \"/source\"'"
                    " ${manifest} > /root/alias-source.json"
                )
                machine.fail(
                    "homelab-preserve --manifest /root/alias-source.json restore fixture/state"
                    " --from replica --point " + older["nativeId"]
                    + " --to scratch:salias --execute --receipt /root/receipt-salias.json"
                )

                machine.succeed(
                    "zfs create -o mountpoint=/hostile -o sharenfs=on receiver/hostile"
                )
                sh(
                    "jq '.scratchDestinations.scratch.nativeParent = \"receiver/hostile\" |"
                    " .scratchDestinations.scratch.mountRoot = \"/hostile\" |"
                    " .states[0].routes[1].ownerConfig.native.zfsReference.scratchRoot = \"receiver/hostile\" |"
                    " .states[0].routes[1].ownerConfig.native.zfsReference.scratchMountRoot = \"/hostile\"'"
                    " ${manifest} > /root/hostile.json"
                )
                machine.fail(
                    "homelab-preserve --manifest /root/hostile.json restore fixture/state"
                    " --from replica --point " + older["nativeId"]
                    + " --to scratch:hdst --execute --receipt /root/receipt-hostile.json"
                )
                assert sh(
                    "zfs list -o name receiver/hostile/hdst >/dev/null 2>&1 && echo present || echo absent"
                ) == "absent"

                machine.succeed("zpool export source")

                sh(
                    "jq 'del(.states[0].routes[0])' ${manifest} > /root/replica-only.json"
                )
                after_loss = report_points(
                    json.loads(
                        sh(
                            "homelab-preserve --manifest /root/replica-only.json --json points"
                            " fixture/state"
                        )
                    )
                )
                replica_after_loss = [
                    point for point in after_loss if point["routeId"] == "replica"
                ]
                assert len(replica_after_loss) == 2, after_loss
                older_after_loss = next(
                    point for point in replica_after_loss if point["captureId"] == old_capture
                )
                sh(
                    "homelab-preserve --manifest /root/replica-only.json restore fixture/state"
                    " --from replica --point " + older_after_loss["nativeId"]
                    + " --to scratch:scratch3 --execute --receipt /root/receipt3.json"
                )
                sh(
                    "homelab-preserve --manifest /root/replica-only.json --json verify"
                    " /root/receipt3.json"
                )
                check_restored("/restore/scratch3")
              '';
            }
          );
        in
        {
          checks.preserve-zfs-reference = test;
        }
      );
}
