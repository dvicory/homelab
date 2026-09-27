{
  lib,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      mergerfsLib = import ../den/aspects/services/_mergerfs.nix { inherit lib; };
      poolUnit = mergerfsLib.unitNameFor "/srv/media/data";
      mediaRoot = {
        group = "media";
        mode = "2770";
      };
      # The pool is evaluated through the module's own option, so the test runs
      # the production mount-option defaults rather than a copy of them.
      pools =
        (lib.evalModules {
          modules = [
            { options.pools = mergerfs.settings.pools; }
            {
              pools."/srv/media/data".branches = [
                {
                  path = "/srv/b0";
                  unit = "srv-b0.mount";
                  required = true;
                  create = true;
                }
                {
                  path = "/srv/b1";
                  unit = "srv-b1.mount";
                  required = true;
                  create = true;
                }
                # A cold branch: its existing content is required, but it
                # receives no new content.
                {
                  path = "/srv/b2";
                  unit = "srv-b2.mount";
                  required = true;
                  create = false;
                }
              ];
            }
          ];
        }).config.pools;
      host = {
        settings.services = {
          mergerfs = { inherit pools; };
          storage-roots.roots.media = {
            path = "/srv/media";
            user = "root";
            inherit (mediaRoot) group mode;
            access = [ ];
          };
        };
      };
      aspectArgs = {
        den = { };
        inherit lib pkgs;
      };
      mergerfs = (import ../den/aspects/services/mergerfs.nix aspectArgs).den.aspects.services.mergerfs;
      mediaNamespace =
        (import ../den/aspects/services/media-namespace.nix aspectArgs)
        .den.aspects.services.media-namespace;
      storageRoots =
        (import ../den/aspects/services/storage-roots.nix aspectArgs).den.aspects.services.storage-roots;
      test = pkgs.testers.runNixOSTest {
        name = "mergerfs-capability";
        requiredFeatures.kvm = true;

        nodes.machine =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          {
            imports = [
              (mergerfs.nixos {
                inherit
                  config
                  host
                  lib
                  pkgs
                  ;
              })
              (mediaNamespace.nixos { inherit host lib pkgs; })
              (storageRoots.nixos {
                inherit
                  config
                  host
                  lib
                  pkgs
                  ;
              })
            ];

            system.stateVersion = "26.05";
            virtualisation = {
              cores = 2;
              memorySize = 2048;
              diskSize = 4096;
              fileSystems = {
                "/srv/b0" = {
                  device = "b0";
                  fsType = "tmpfs";
                  options = [ "size=6G" ];
                };
                "/srv/b1" = {
                  device = "b1";
                  fsType = "tmpfs";
                  options = [ "size=7G" ];
                };
                "/srv/b2" = {
                  device = "archive";
                  fsType = "tmpfs";
                  options = [ "size=20G" ];
                };
              };
            };

            users.groups.media.gid = 505;
            environment.systemPackages = [ pkgs.acl ];
          };

        testScript = ''
          start_all()
          machine.wait_until_succeeds(
              "systemctl is-active ${poolUnit}", timeout=30
          )
          machine.wait_until_succeeds("systemctl is-active media-namespace.service", timeout=30)
          machine.succeed("mountpoint -q /srv/media/data")

          machine.succeed("mkdir /srv/b2/archive && printf retained > /srv/b2/archive/existing")
          machine.succeed("test \"$(cat /srv/media/data/archive/existing)\" = retained")
          # A directory held only by the cold branch reports the capacity of the
          # creation-eligible branches, not of the branch that holds it.
          machine.succeed(
              "blocks=$(df --output=avail --block-size=1M /srv/media/data/archive | tail -1); "
              "test \"$blocks\" -gt 12000 -a \"$blocks\" -lt 15000 || { "
              "echo \"reported available blocks: $blocks\"; exit 1; }"
          )

          # Archive capacity is visible for reads but excluded from writable
          # capacity because its branch is declared no-create.
          machine.succeed(
              "blocks=$(df --output=avail --block-size=1M /srv/media/data | tail -1); "
              "test \"$blocks\" -gt 12000 -a \"$blocks\" -lt 15000 || { "
              "echo \"reported available blocks: $blocks\"; df -h /srv/b0 /srv/b1 /srv/b2 /srv/media/data; exit 1; }"
          )
          machine.succeed(
              "before=$(df --output=avail --block-size=1M /srv/media/data | tail -1); "
              "dd if=/dev/zero of=/srv/media/data/capacity-check bs=1M count=32 status=none; "
              "after=$(df --output=avail --block-size=1M /srv/media/data | tail -1); "
              "test \"$after\" -lt \"$before\"; touch /srv/media/data/after-capacity-check"
          )

          # Supplemental possession of the media capability authorizes writes
          # and determines the inherited group; the same UID without it is denied.
          machine.succeed(
              "setpriv --reuid 6100 --regid 6100 --groups 505 -- "
              "touch /srv/media/data/library/supplemental"
          )
          machine.succeed("test \"$(stat -c %g /srv/media/data/library/supplemental)\" = 505")
          machine.fail(
              "setpriv --reuid 6100 --regid 6100 --groups 6100 -- "
              "touch /srv/media/data/library/without"
          )

          # With the workload umask the participating identity's entries take
          # the declared group through setgid and umask-shaped permission bits
          # with no corrective step; a directory keeps the root's declared mode.
          machine.succeed(
              "setpriv --reuid 6100 --regid 6100 --groups 505 -- sh -c "
              "'umask 007; touch /srv/media/data/library/new-file; "
              "mkdir /srv/media/data/library/new-dir'"
          )
          machine.succeed(
              "test \"$(stat -c '%g:%a' /srv/media/data/library/new-file)\" = 505:660"
          )
          machine.succeed(
              "test \"$(stat -c '%g:%a' /srv/media/data/library/new-dir)\" = 505:${mediaRoot.mode}"
          )

          # Another service UID holding the capability can modify that file;
          # a UID without it can neither read nor modify it.
          machine.succeed(
              "setpriv --reuid 6200 --regid 6200 --groups 505 -- sh -c "
              "'printf imported >> /srv/media/data/library/new-file'"
          )
          machine.fail(
              "setpriv --reuid 6300 --regid 6300 --groups 6300 -- "
              "cat /srv/media/data/library/new-file"
          )
          machine.fail(
              "setpriv --reuid 6300 --regid 6300 --groups 6300 -- sh -c "
              "'printf x >> /srv/media/data/library/new-file'"
          )

          # Routine activation must not chmod the live merged root back to its
          # fail-closed bare-directory mode.
          machine.succeed("systemd-tmpfiles --create")
          machine.succeed("test \"$(stat -c %a /srv/media/data)\" = 2770")
          machine.succeed(
              "setpriv --reuid 6100 --regid 6100 --groups 505 -- "
              "touch /srv/media/data/library/after-activation"
          )

          # Re-running namespace setup creates omissions without rewriting
          # application-managed metadata on existing directories.
          machine.succeed("chown root:root /srv/media/data/library/tv")
          machine.succeed("chmod 0751 /srv/media/data/library/tv")
          machine.succeed("setfacl -m u:nobody:rX /srv/media/data/library/tv")
          machine.succeed(
              "before=$(stat -c '%u:%g:%a' /srv/media/data/library/tv); "
              "acl_before=$(getfacl -cp /srv/media/data/library/tv); "
              "systemctl restart media-namespace.service; "
              "systemd-tmpfiles --create; "
              "after=$(stat -c '%u:%g:%a' /srv/media/data/library/tv); "
              "acl_after=$(getfacl -cp /srv/media/data/library/tv); "
              "test \"$after\" = \"$before\" || { "
              "echo \"metadata changed: $before -> $after\"; exit 1; }; "
              "test \"$acl_after\" = \"$acl_before\" || { "
              "echo \"ACL changed: $acl_before -> $acl_after\"; exit 1; }"
          )

          # A bind-mounted read-only player view remains the same filesystem.
          machine.succeed("mkdir /srv/read-only")
          machine.succeed("mount --bind /srv/media/data/library /srv/read-only")
          machine.succeed("mount -o remount,bind,ro /srv/read-only")
          machine.fail(
              "setpriv --reuid 6100 --regid 6100 --groups 505 -- "
              "touch /srv/read-only/blocked"
          )
          machine.succeed(
              "test \"$(stat -c %d /srv/read-only)\" = "
              "\"$(stat -c %d /srv/media/data/library)\""
          )

          # Linking within the common namespace preserves one allocation;
          # presenting the paths as separate filesystems cannot.
          machine.succeed(
              "setpriv --reuid 6100 --regid 6100 --groups 505 -- sh -c "
              "'printf x > /srv/media/data/downloads/usenet/complete/src && "
              "ln /srv/media/data/downloads/usenet/complete/src "
              "/srv/media/data/library/movies/dst'"
          )
          machine.fail("test -e /srv/b2/downloads/usenet/complete/src")
          machine.fail(
              "ln /srv/media/data/downloads/usenet/complete/src "
              "/srv/b2/separate-filesystem-link"
          )
          machine.wait_until_succeeds(
              "test \"$(stat -c %h /srv/media/data/downloads/usenet/complete/src)\" -eq 2",
              timeout=5,
          )
          machine.succeed(
              "test \"$(stat -c '%d:%i' /srv/media/data/downloads/usenet/complete/src)\" "
              "= \"$(stat -c '%d:%i' /srv/media/data/library/movies/dst)\""
          )
          machine.succeed(
              "if test -e /srv/b0/downloads/usenet/complete/src; then "
              "test ! -e /srv/b1/downloads/usenet/complete/src; "
              "test \"$(stat -c '%d:%i' /srv/b0/downloads/usenet/complete/src)\" "
              "= \"$(stat -c '%d:%i' /srv/b0/library/movies/dst)\"; "
              "else test -e /srv/b1/downloads/usenet/complete/src; "
              "test \"$(stat -c '%d:%i' /srv/b1/downloads/usenet/complete/src)\" "
              "= \"$(stat -c '%d:%i' /srv/b1/library/movies/dst)\"; fi"
          )

          # A show whose directory exists only on the cold branch still accepts
          # a new episode, and an import hardlink from downloads, on a
          # creation-eligible branch. Its existing episode stays modifiable on
          # the cold branch.
          machine.succeed(
              "install -d -o root -g 505 -m 2770 /srv/b2/library /srv/b2/library/tv "
              "/srv/b2/library/tv/cold-show && "
              "printf e01 > /srv/b2/library/tv/cold-show/e01 && "
              "chown root:505 /srv/b2/library/tv/cold-show/e01 && "
              "chmod 0660 /srv/b2/library/tv/cold-show/e01"
          )
          machine.succeed(
              "setpriv --reuid 6100 --regid 6100 --groups 505 -- sh -c "
              "'umask 007; printf e02 > /srv/media/data/library/tv/cold-show/e02 && "
              "printf e03 > /srv/media/data/downloads/usenet/complete/e03 && "
              "ln /srv/media/data/downloads/usenet/complete/e03 "
              "/srv/media/data/library/tv/cold-show/e03 && "
              "printf more >> /srv/media/data/library/tv/cold-show/e01'"
          )
          machine.fail("test -e /srv/b2/library/tv/cold-show/e02")
          machine.fail("test -e /srv/b2/library/tv/cold-show/e03")
          machine.succeed(
              "test -e /srv/b0/library/tv/cold-show/e02 -o -e /srv/b1/library/tv/cold-show/e02"
          )
          machine.succeed(
              "for b in /srv/b0 /srv/b1; do "
              "if test -e $b/downloads/usenet/complete/e03; then "
              "test \"$(stat -c %i $b/downloads/usenet/complete/e03)\" "
              "= \"$(stat -c %i $b/library/tv/cold-show/e03)\" && exit 0; fi; done; exit 1"
          )
          machine.succeed("test \"$(cat /srv/b2/library/tv/cold-show/e01)\" = e01more")

          # Losing a required mount stops the pool and its dependent layout while
          # unrelated mounts remain operational.
          machine.succeed("systemctl stop srv-b1.mount")
          machine.wait_until_fails("systemctl is-active ${poolUnit}")
          machine.wait_until_fails("systemctl is-active media-namespace.service")
          machine.fail("mountpoint -q /srv/media/data")
          machine.fail(
              "setpriv --reuid 6100 --regid 6100 --groups 505 -- "
              "touch /srv/media/data/unavailable"
          )
          machine.succeed("mountpoint -q /srv/b0")

          # Restoring the required mount restores the pool and its layout without
          # a separate operator action.
          machine.succeed("systemctl start srv-b1.mount")
          machine.wait_until_succeeds(
              "systemctl is-active ${poolUnit}", timeout=30
          )
          machine.wait_until_succeeds("systemctl is-active media-namespace.service", timeout=30)
          machine.succeed("mountpoint -q /srv/media/data")
          machine.succeed("test \"$(cat /srv/media/data/archive/existing)\" = retained")
        '';
      };
    in
    {
      legacyPackages.mergerfs-capability-test = test;
      checks = lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        mergerfs-capability = test // {
          meta = test.meta // {
            hestia.group = "${system}-mergerfs-runtime";
          };
        };
      };
    };
}
