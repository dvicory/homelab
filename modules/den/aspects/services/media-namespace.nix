# The media namespace layout.
#
# `/srv/media/data` is the single host-owned media access root and one mergerfs
# filesystem. The directories beneath it are layout rather than separate
# storage roots: they share one access policy, so they are created together by
# one unit instead of becoming four independent roots with four owners.
#
# The unit refuses to run unless the merged filesystem is actually mounted. That
# refusal is the whole point: if the pool is missing, the alternative is a
# plausible-looking directory tree on the root filesystem that applications
# happily fill, and the content silently ends up somewhere nobody is backing up.
{
  den,
  lib,
  pkgs,
  ...
}:
let
  mergerfs = import ./_mergerfs.nix { inherit lib; };
  root = "/srv/media/data";
  layout = [
    "library"
    "library/movies"
    "library/tv"
    "downloads"
    "downloads/usenet"
    "downloads/usenet/incomplete"
    "downloads/usenet/complete"
    "downloads/torrents"
  ];
in
{
  den.aspects.kubernetes.services.media.compute-resources.mediaPaths = {
    data = root;
    library = "${root}/library";
  };

  den.aspects.services.media-namespace = {
    nixos =
      {
        host,
        pkgs,
        ...
      }:
      let
        pools = host.settings.services.mergerfs.pools or { };
        poolUnit = mergerfs.unitNameFor root;
        rootSettings = host.settings.services.storage-roots.roots.media;
      in
      lib.mkIf (pools ? ${root}) {
        systemd.services.media-namespace = {
          description = "Create the media namespace layout on the merged filesystem";
          wantedBy = [ poolUnit ];
          # The pool is a service, not a .mount unit. Depend on the unit that
          # actually mounts it so layout creation never runs on the bare path.
          after = [ poolUnit ];
          bindsTo = [ poolUnit ];
          requires = [ poolUnit ];
          partOf = [ poolUnit ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [
            pkgs.coreutils
            pkgs.util-linux
          ];
          script = ''
            set -eu
            mountpoint=${root}
            if ! findmnt --noheadings --types fuse.mergerfs --mountpoint "$mountpoint" >/dev/null; then
              echo "media namespace: $mountpoint is not a mounted mergerfs filesystem; refusing to create its layout" >&2
              exit 1
            fi
            chown ${lib.escapeShellArg "${rootSettings.user}:${rootSettings.group}"} "$mountpoint"
            chmod ${lib.escapeShellArg rootSettings.mode} "$mountpoint"
            ${lib.concatMapStrings (dir: ''
              target="$mountpoint/${dir}"
              if [ ! -e "$target" ]; then
                install -d -o ${lib.escapeShellArg rootSettings.user} -g ${lib.escapeShellArg rootSettings.group} -m ${lib.escapeShellArg rootSettings.mode} "$target"
              fi
            '') layout}
          '';
        };
      };
  };
}
