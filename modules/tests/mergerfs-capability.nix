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
      # The shape of the migration-era production pool: one creation-eligible
      # XFS disk (media4) and two required no-create legacy disks (media2 and
      # media3). The pool is evaluated through the module's own option, so the
      # test runs the production mount-option defaults rather than a copy.
      pools =
        (lib.evalModules {
          modules = [
            { options.pools = mergerfs.settings.pools; }
            {
              pools."/srv/media/data".branches = [
                # media4 contributes only its pool/ subtree.
                {
                  path = "/srv/b0/pool";
                  mountPoint = "/srv/b0";
                  unit = "srv-b0.mount";
                  required = true;
                  create = true;
                }
                {
                  path = "/srv/b1";
                  unit = "srv-b1.mount";
                  required = true;
                  create = false;
                }
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
            utils,
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
                  utils
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
            boot.supportedFilesystems = [ "xfs" ];
            virtualisation = {
              cores = 2;
              memorySize = 2048;
              diskSize = 4096;
              emptyDiskImages = [ 6144 ];
              fileSystems = {
                "/srv/b0" = {
                  device = "/dev/vdb";
                  fsType = "xfs";
                  autoFormat = true;
                };
                "/srv/b1" = {
                  device = "legacy-b1";
                  fsType = "tmpfs";
                  options = [ "size=7G" ];
                };
                "/srv/b2" = {
                  device = "legacy-b2";
                  fsType = "tmpfs";
                  options = [ "size=20G" ];
                };
              };
            };

            # The disk's pool/ tree and a migration/ holding area beside it.
            systemd.tmpfiles.rules = [
              "d /srv/b0/pool 2770 root media -"
              "d /srv/b0/migration 0700 root root -"
              "f /srv/b0/migration/receipt 0600 root root - evacuated"
            ];
            users.groups.media.gid = 505;
            environment.systemPackages = [ pkgs.acl ];
          };

        # UIDs: 6100 "radarr" and 6200 "sab" both hold the media group (505);
        # 6300 is an unrelated identity.
        testScript = ''
          radarr = "setpriv --reuid 6100 --regid 6100 --groups 505 --"
          sab = "setpriv --reuid 6200 --regid 6200 --groups 505 --"
          stranger = "setpriv --reuid 6300 --regid 6300 --groups 6300 --"
          pool = "/srv/media/data"

          def mode(path):
              return machine.succeed(f"stat -c '%a:%g' {path}").strip()

          def default_acl(path):
              return machine.succeed(f"getfacl -cpd {path}").split()

          shared_default = ["user::rwx", "group::rwx", "mask::rwx", "other::---"]

          start_all()
          machine.wait_until_succeeds("systemctl is-active ${poolUnit}", timeout=60)
          machine.wait_until_succeeds("systemctl is-active media-namespace.service", timeout=30)
          machine.succeed(f"mountpoint -q {pool}")
          machine.succeed("findmnt -no FSTYPE /srv/b0 | grep -qx xfs")

          # Only the disk's pool/ subtree joins the namespace; its migration/
          # holding area does not.
          machine.fail(f"test -e {pool}/migration")
          machine.fail(f"test -e {pool}/pool")

          # The namespace creates its layout on the creation-eligible disk,
          # owned by the media group, setgid, with the group-only default ACL.
          for directory in ["library", "library/movies", "library/tv", "downloads/usenet/complete"]:
              assert mode(f"/srv/b0/pool/{directory}") == "2770:505", directory
              assert default_acl(f"/srv/b0/pool/{directory}") == shared_default, directory

          # Reported capacity is the creation-eligible disk's, even for a
          # directory held only by a no-create branch.
          machine.succeed("install -d -o root -g 505 -m 2770 /srv/b2/archive")
          for path in [pool, f"{pool}/archive"]:
              machine.succeed(
                  f"blocks=$(df --output=avail --block-size=1M {path} | tail -1); "
                  "test \"$blocks\" -gt 5000 -a \"$blocks\" -lt 6300 || { "
                  f"echo \"{path}: reported available blocks: $blocks\"; exit 1; }}"
              )

          # Permission contract, directly on the XFS disk and through the pool:
          # a writer with umask 022 still produces group-writable content, and
          # nested directories keep the group, setgid and default ACL.
          machine.succeed(f"{radarr} sh -c 'umask 022; echo direct > /srv/b0/pool/library/movies/direct.mkv'")
          assert mode("/srv/b0/pool/library/movies/direct.mkv") == "660:505"
          machine.succeed(
              f"{radarr} sh -c 'umask 022; mkdir -p {pool}/library/tv/Show/Season1 && "
              f"echo e1 > {pool}/library/tv/Show/Season1/e1.mkv'"
          )
          assert mode("/srv/b0/pool/library/tv/Show/Season1") == "2770:505"
          assert default_acl("/srv/b0/pool/library/tv/Show/Season1") == shared_default
          assert mode("/srv/b0/pool/library/tv/Show/Season1/e1.mkv") == "660:505"

          # A second capability holder can modify, link, rename and remove what
          # the first created; an identity without the group cannot even read.
          episode = f"{pool}/library/tv/Show/Season1/e1.mkv"
          machine.succeed(
              f"{sab} sh -c 'echo more >> {episode} && ln {episode} {episode}.link && "
              f"mv {episode}.link {episode}.renamed && rm {episode}.renamed'"
          )
          machine.fail(f"{stranger} cat {episode}")
          machine.fail(f"{stranger} sh -c 'echo x >> {episode}'")
          machine.fail(f"{stranger} ls {pool}/library/tv/Show")
          # The group is authorized as a supplemental group, not a primary one.
          machine.fail(f"setpriv --reuid 6100 --regid 6100 --groups 6100 -- touch {pool}/library/without")

          # Known limit of the contract: default ACLs do not override a writer
          # that deliberately restricts a file's mode.
          machine.succeed(f"{radarr} install -m 0600 /dev/null {pool}/library/tv/private.mkv")
          assert mode("/srv/b0/pool/library/tv/private.mkv") == "600:505"
          machine.fail(f"{sab} cat {pool}/library/tv/private.mkv")

          # Radarr's import: Foo's directory exists only on a no-create legacy
          # disk (shared as classify-legacy-media's share step leaves it),
          # SABnzbd completes a download through the pool, and Radarr hardlinks
          # it into Foo.
          machine.succeed(
              "install -d -o root -g 505 -m 2770 /srv/b1/library /srv/b1/library/movies "
              "/srv/b1/library/movies/Foo && "
              "setfacl -m d:u::rwx,d:g::rwx,d:m::rwx,d:o::--- /srv/b1/library/movies/Foo && "
              "echo old > /srv/b1/library/movies/Foo/old.mkv && "
              "chown 6100:505 /srv/b1/library/movies/Foo/old.mkv && chmod 0660 /srv/b1/library/movies/Foo/old.mkv"
          )
          legacy_before = machine.succeed("find /srv/b1 /srv/b2 -printf '%p %i %s\\n' | sort")
          machine.succeed(f"{sab} sh -c 'umask 022; echo movie > {pool}/downloads/usenet/complete/Foo.mkv'")
          machine.succeed("test -f /srv/b0/pool/downloads/usenet/complete/Foo.mkv")
          machine.succeed(f"{radarr} ln {pool}/downloads/usenet/complete/Foo.mkv {pool}/library/movies/Foo/new.mkv")
          machine.succeed(
              "test \"$(stat -c %i /srv/b0/pool/downloads/usenet/complete/Foo.mkv)\" "
              "= \"$(stat -c %i /srv/b0/pool/library/movies/Foo/new.mkv)\""
          )
          machine.succeed("test \"$(stat -c %h /srv/b0/pool/library/movies/Foo/new.mkv)\" -eq 2")
          assert machine.succeed("find /srv/b1 /srv/b2 -printf '%p %i %s\\n' | sort") == legacy_before
          assert mode("/srv/b0/pool/library/movies/Foo") == "2770:505"
          assert default_acl("/srv/b0/pool/library/movies/Foo") == shared_default
          assert mode("/srv/b0/pool/library/movies/Foo/new.mkv") == "660:505"
          # The legacy file stays visible, and modifiable, at the canonical path.
          machine.succeed(f"test \"$(cat {pool}/library/movies/Foo/old.mkv)\" = old")
          machine.succeed(f"{sab} sh -c 'echo edited >> {pool}/library/movies/Foo/old.mkv'")
          machine.succeed("grep -qx edited /srv/b1/library/movies/Foo/old.mkv")
          machine.fail(f"{stranger} cat {pool}/library/movies/Foo/new.mkv")

          # Routine activation must not chmod the live merged root back to its
          # fail-closed bare-directory mode.
          machine.succeed("systemd-tmpfiles --create")
          machine.succeed(f"test \"$(stat -c %a {pool})\" = 2770")

          # Re-running namespace setup creates omissions without rewriting
          # metadata, including ACLs, on existing directories.
          machine.succeed(f"chown root:root {pool}/library/tv && chmod 0751 {pool}/library/tv")
          machine.succeed(f"setfacl -b {pool}/library/tv && setfacl -m u:nobody:rX {pool}/library/tv")
          machine.succeed(
              f"before=$(stat -c '%u:%g:%a' {pool}/library/tv; getfacl -cp {pool}/library/tv); "
              "systemctl restart media-namespace.service; systemd-tmpfiles --create; "
              f"after=$(stat -c '%u:%g:%a' {pool}/library/tv; getfacl -cp {pool}/library/tv); "
              "test \"$after\" = \"$before\" || { echo \"changed: $before -> $after\"; exit 1; }"
          )

          # A read-only bind of the library is the same filesystem and refuses
          # writes.
          machine.succeed(f"mkdir /srv/read-only && mount --bind {pool}/library /srv/read-only")
          machine.succeed("mount -o remount,bind,ro /srv/read-only")
          machine.fail(f"{radarr} touch /srv/read-only/blocked")
          machine.succeed(f"test \"$(stat -c %d /srv/read-only)\" = \"$(stat -c %d {pool}/library)\"")
          machine.succeed("umount /srv/read-only")

          # The same link across separately presented filesystems fails.
          machine.fail(f"ln {pool}/downloads/usenet/complete/Foo.mkv /srv/b2/separate-filesystem-link")

          # Losing a required no-create disk stops the pool and its layout while
          # unrelated mounts keep working; nothing is written in its place.
          machine.succeed("systemctl stop srv-b1.mount")
          machine.wait_until_fails("systemctl is-active ${poolUnit}")
          machine.wait_until_fails("systemctl is-active media-namespace.service")
          machine.fail(f"mountpoint -q {pool}")
          machine.fail(f"{radarr} touch {pool}/unavailable")
          machine.succeed("mountpoint -q /srv/b0")

          # Restoring it restores the pool and its layout without operator action.
          machine.succeed("systemctl start srv-b1.mount")
          machine.wait_until_succeeds("systemctl is-active ${poolUnit}", timeout=30)
          machine.wait_until_succeeds("systemctl is-active media-namespace.service", timeout=30)
          machine.succeed(f"mountpoint -q {pool}")
          machine.succeed(f"test -d {pool}/archive")

          # A subtree branch whose directory is missing, or is a symlink off its
          # mount, refuses the pool even though the disk itself is mounted.
          machine.succeed("systemctl stop ${poolUnit}")
          machine.succeed("mv /srv/b0/pool /srv/b0/pool.away")
          machine.fail("systemctl start ${poolUnit}")
          machine.fail(f"mountpoint -q {pool}")
          machine.fail("test -e /srv/b0/pool")
          machine.succeed("ln -s /srv/b1 /srv/b0/pool")
          machine.fail("systemctl start ${poolUnit}")
          machine.fail(f"mountpoint -q {pool}")
          machine.succeed("rm /srv/b0/pool && mv /srv/b0/pool.away /srv/b0/pool")
          machine.succeed("systemctl start ${poolUnit}")
          machine.succeed(f"test -e {pool}/library/movies/Foo/new.mkv")
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
