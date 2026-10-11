{
  inputs,
  lib,
  ...
}:
{
  # Incus mount isolation under the persistence layouts it must handle. Each
  # node restarts an unprivileged container whose disk device source contains
  # a mount, the case that left a busy copy in production:
  #
  # - directory: impermanence binds /var/lib/incus after boot, as on hvn-hyp1.
  # - parent: a bind of /var/lib made after boot. Both binds are peers of the
  #   filesystem they come from, so Incus mounts propagate to /persist.
  # - early-parent: impermanence binds /var/lib, which NixOS needs for boot,
  #   in the initrd. That bind gets its own peer group (as /var/lib/nixos has
  #   on hvn-hyp1), so nothing propagates and the unit has nothing to do.
  # - unpersisted: no bind; the unit has nothing to do.
  #
  # legacyPackages.incus-mount-isolation-unprotected runs the directory and
  # parent scenarios without the unit; it is expected to fail.
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        incus =
          (import ../den/aspects/virtualization/incus.nix { inherit lib; }).den.aspects.virtualization.incus;

        # A unified Incus image: busybox and its store closure, with an init
        # that only waits.
        busybox = pkgs.busybox;
        closure = pkgs.closureInfo { rootPaths = [ busybox ]; };
        image = pkgs.runCommand "incus-busybox-image.tar.gz" { } ''
          mkdir -p image/rootfs/{bin,sbin,dev,proc,sys,tmp,etc,srv/media,nix/store}
          cp -a $(cat ${closure}/store-paths) image/rootfs/nix/store/
          ln -s ${busybox}/bin/busybox image/rootfs/bin/sh
          ln -s ${busybox}/bin/busybox image/rootfs/bin/cat
          printf '#!${busybox}/bin/sh\nexec ${busybox}/bin/sleep 2147483647\n' > image/rootfs/sbin/init
          chmod 0755 image/rootfs/sbin/init
          printf 'architecture: x86_64\ncreation_date: 1\nproperties:\n  description: busybox\n' > image/metadata.yaml
          tar -C image --owner=0 --group=0 --numeric-owner -czf $out metadata.yaml rootfs
        '';

        node =
          {
            isolate,
            persisted ? null,
            boundAfterBoot ? null,
          }:
          { lib, ... }:
          {
            imports = [
              incus.nixos
              inputs.impermanence.nixosModules.impermanence
            ];
            system.stateVersion = "26.05";
            virtualisation = {
              cores = 2;
              memorySize = 1536;
              incus.preseed = {
                storage_pools = [
                  {
                    name = "default";
                    driver = "dir";
                  }
                ];
                profiles = [
                  {
                    name = "default";
                    devices.root = {
                      path = "/";
                      pool = "default";
                      type = "disk";
                    };
                  }
                ];
              };
            };
            # Impermanence requires every filesystem it binds into to be
            # mounted in the initrd; the root filesystem is.
            virtualisation.fileSystems."/".neededForBoot = true;
            environment.persistence = lib.mkIf (persisted != null) {
              "/persist" = {
                enableWarnings = false;
                hideMounts = true;
                directories = [ persisted ];
              };
            };
            # The same mount impermanence declares for a directory it does
            # not need for boot.
            systemd.mounts = lib.optional (boundAfterBoot != null) {
              what = "/persist${boundAfterBoot}";
              where = boundAfterBoot;
              type = "none";
              options = "bind";
              wantedBy = [ "local-fs.target" ];
              before = [ "local-fs.target" ];
              unitConfig.DefaultDependencies = false;
            };
            system.activationScripts = lib.mkIf (boundAfterBoot != null) {
              persist-source = "mkdir -p /persist${boundAfterBoot}";
            };
            networking.nftables.enable = true;
            systemd.services.incus-mount-isolation.enable = isolate;
          };

        mkTest =
          { name, isolate }:
          pkgs.testers.runNixOSTest {
            inherit name;
            requiredFeatures.kvm = true;

            nodes = {
              directory = node {
                inherit isolate;
                persisted = "/var/lib/incus";
              };
              parent = node {
                inherit isolate;
                boundAfterBoot = "/var/lib";
              };
            }
            // lib.optionalAttrs isolate {
              early-parent = node {
                inherit isolate;
                persisted = "/var/lib";
              };
              unpersisted = node { inherit isolate; };
            };

            testScript = ''
              isolate = ${if isolate then "True" else "False"}
              copies_below = "/persist/var/lib/incus/"

              def copies(machine):
                  targets = machine.succeed("findmnt --raw --noheadings --output TARGET").splitlines()
                  return [target for target in targets if target.startswith(copies_below)]

              def propagation(machine):
                  # With stacked mounts, the last line is the visible one.
                  return machine.succeed("findmnt --noheadings --output PROPAGATION --target /var/lib/incus").split()[-1]

              def boot(machine):
                  machine.wait_for_unit("incus.service")
                  machine.wait_for_unit("incus-preseed.service")
                  machine.fail("journalctl --boot --no-pager | grep -i 'ordering cycle'")

              def lifecycle(machine, command, step):
                  status, output = machine.execute(f"incus {command} c 2>&1")
                  assert status == 0, f"{step}: incus {command} failed: {output.strip()}"
                  assert machine.succeed("incus exec c -- cat /srv/media/data/probe") == "probe\n", step

              def restart_with_nested_source(machine):
                  # As on the host, /srv/media/data is its own mount below the
                  # attached /srv/media (MergerFS there, tmpfs here).
                  machine.succeed(
                      "mkdir -p /srv/media/data",
                      "mount -t tmpfs -o size=1m tmpfs /srv/media/data",
                      "echo probe > /srv/media/data/probe && chmod 0644 /srv/media/data/probe",
                      "incus image import ${image} --alias busybox",
                      "incus init busybox c",
                      "incus config device add c media disk source=/srv/media path=/srv/media "
                      "recursive=true propagation=rslave required=false",
                  )
                  lifecycle(machine, "start", "first start")
                  machine.succeed("incus stop --force c")
                  lifecycle(machine, "start", "start after stop")
                  lifecycle(machine, "restart --force", "restart")
                  assert copies(machine) == [], f"copies remain: {copies(machine)}"

              start_all()

              # Run both reproducing layouts before failing, so a failure shows
              # which of them reproduce it.
              failures = []
              for machine in [directory, parent]:
                  with subtest(f"{machine.name}: restart a container with a nested disk source"):
                      try:
                          boot(machine)
                          if isolate:
                              machine.succeed("systemctl is-active incus-mount-isolation.service")
                              assert propagation(machine) == "private", propagation(machine)
                          restart_with_nested_source(machine)
                      except Exception as error:
                          machine.log(f"FAILED: {error}")
                          failures.append(f"{machine.name}: {error}")
              assert failures == [], "; ".join(failures)

              ${lib.optionalString isolate protectedScript}
            '';
          };

        # Checks that need the unit: restarts while an instance runs, removal
        # of copies made before it ran, the layouts it leaves alone, and a
        # refusal.
        protectedScript = ''
          for machine in [directory, parent]:
              with subtest(f"{machine.name}: the unit restarts while an instance runs"):
                  machine.succeed("systemctl restart incus-mount-isolation.service")
                  assert machine.succeed("incus list c --format csv --columns s").strip() == "RUNNING"
                  assert copies(machine) == [], f"copies remain: {copies(machine)}"

          for machine, bind in [(directory, "/var/lib/incus"), (parent, "/var/lib")]:
              with subtest(f"{machine.name}: copies made before the unit ran are removed"):
                  # Stack a fresh bind, again a peer of the root filesystem, and
                  # start Incus on it: a host where Incus ran before the unit.
                  machine.succeed("incus stop --force c", "systemctl stop incus.service incus.socket")
                  machine.succeed(f"mount --bind /persist{bind} {bind}")
                  assert propagation(machine) == "shared", propagation(machine)
                  machine.succeed("systemctl start incus.service", "incus start c")
                  assert copies(machine) != [], "the fresh bind propagates Incus mounts"
                  # As activation does, with the instance running.
                  machine.succeed("systemctl restart incus-mount-isolation.service")
                  assert propagation(machine) == "private", propagation(machine)
                  assert copies(machine) == [], f"copies remain: {copies(machine)}"
                  assert machine.succeed("incus exec c -- cat /srv/media/data/probe") == "probe\n"
                  machine.succeed("incus stop --force c")
                  lifecycle(machine, "start", "start after the unit removed copies")

          for machine in [early_parent, unpersisted]:
              with subtest(f"{machine.name}: nothing to isolate"):
                  boot(machine)
                  machine.succeed("systemctl is-active incus-mount-isolation.service")
                  assert propagation(machine) == "shared", propagation(machine)
                  restart_with_nested_source(machine)

          with subtest("unpersisted: a second view of the root filesystem is refused"):
              unpersisted.succeed("mkdir -p /mnt/root-view && mount --bind / /mnt/root-view")
              unpersisted.fail("systemctl restart incus-mount-isolation.service")
              assert propagation(unpersisted) == "shared", propagation(unpersisted)
              unpersisted.succeed("umount /mnt/root-view")
              unpersisted.succeed("systemctl restart incus-mount-isolation.service")
        '';

        test = mkTest {
          name = "incus-mount-isolation";
          isolate = true;
        };
      in
      {
        legacyPackages = {
          incus-mount-isolation-test = test;
          incus-mount-isolation-unprotected = mkTest {
            name = "incus-mount-isolation-unprotected";
            isolate = false;
          };
        };
        checks.incus-mount-isolation = test // {
          meta = test.meta // {
            hestia.group = "${system}-incus-runtime";
          };
        };
      }
    );
}
