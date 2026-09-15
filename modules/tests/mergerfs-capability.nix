{
  lib,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      host = {
        settings.services = {
          mergerfs.pools."/srv/media/data" = {
            options = [
              "allow_other"
              "category.create=epmfs"
              "moveonenospc=false"
              "statfs-ignore=nc"
              "statfs=full"
            ];
            branches = [
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
              {
                path = "/srv/b2";
                unit = "srv-b2.mount";
                required = false;
                create = false;
              }
            ];
          };
          storage-roots.roots.media = {
            path = "/srv/media";
            user = "root";
            group = "media";
            mode = "2770";
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
          };

        testScript = ''
          start_all()
          machine.wait_until_succeeds(
              "systemctl is-active mergerfs-mnt-srv-media-data.service", timeout=30
          )
          machine.wait_until_succeeds("systemctl is-active media-namespace.service", timeout=30)
          machine.succeed("mountpoint -q /srv/media/data")

          machine.succeed("mkdir /srv/b2/archive && printf retained > /srv/b2/archive/existing")
          machine.succeed("test \"$(cat /srv/media/data/archive/existing)\" = retained")

          # Archive capacity is visible for reads but excluded from writable
          # capacity because its branch is declared no-create.
          machine.succeed(
              "blocks=$(df --output=size --block-size=1M /srv/media/data | tail -1); "
              "test \"$blocks\" -gt 12000 -a \"$blocks\" -lt 15000"
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
          machine.succeed("systemctl restart media-namespace.service")
          machine.succeed("test \"$(stat -c '%u:%g:%a' /srv/media/data/library/tv)\" = 0:0:751")

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
              "set -eu; branch=; matches=0; "
              "for candidate in /srv/b0 /srv/b1; do "
              "if test -e \"$candidate/downloads/usenet/complete/src\"; then "
              "matches=$((matches + 1)); branch=$candidate; fi; "
              "done; test \"$matches\" -eq 1; "
              "test \"$(stat -c '%d:%i' \"$branch/downloads/usenet/complete/src\")\" "
              "= \"$(stat -c '%d:%i' \"$branch/library/movies/dst)\""
          )

          # Losing a required mount stops the pool and its dependent layout while
          # the host and unrelated mounts remain operational.
          machine.succeed("systemctl stop srv-b1.mount")
          machine.wait_until_fails("systemctl is-active mergerfs-mnt-srv-media-data.service")
          machine.wait_until_fails("systemctl is-active media-namespace.service")
          machine.fail("mountpoint -q /srv/media/data")
          machine.fail(
              "setpriv --reuid 6100 --regid 6100 --groups 505 -- "
              "touch /srv/media/data/unavailable"
          )
          machine.succeed("systemctl is-active multi-user.target")
          machine.succeed("mountpoint -q /srv/b0")

          # Restoring the required mount restores the pool and its layout without
          # a separate operator action.
          machine.succeed("systemctl start srv-b1.mount")
          machine.wait_until_succeeds(
              "systemctl is-active mergerfs-mnt-srv-media-data.service", timeout=30
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
