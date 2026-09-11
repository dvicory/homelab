# The media namespace layout.
#
# `/srv/media` is the single host-owned media access root and one mergerfs
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
  root = "/srv/media";
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
      in
      lib.mkIf (pools ? ${root}) {
        systemd.services.media-namespace = {
          description = "Create the media namespace layout on the merged filesystem";
          wantedBy = [ "multi-user.target" ];
          # The pool is a service, not a .mount unit, so RequiresMountsFor would
          # order against nothing. Depend on the unit that actually mounts it.
          after = [ poolUnit ];
          requires = [ poolUnit ];
          unitConfig.RequiresMountsFor = [ root ];
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
            if ! findmnt --noheadings --output FSTYPE --target "$mountpoint" | grep -qx fuse.mergerfs; then
              echo "media namespace: $mountpoint is not a mounted mergerfs filesystem; refusing to create its layout" >&2
              exit 1
            fi
            ${lib.concatMapStrings (dir: ''
              install -d -o root -g media -m 2770 "$mountpoint/${dir}"
            '') layout}
          '';
        };
      };
  };
}
