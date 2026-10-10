mediaGid:
{
  # s6-setuidgid rebuilds abc's groups from /etc/group, discarding inherited groups.
  # Use the vendor's pre-service hook; keep private PUID/PGID and volume modes.
  configMaps.media-group.data."10-media-group.sh" = "#!/bin/sh\n" + ''
    set -eu
    getent group ${toString mediaGid} >/dev/null || groupadd --gid ${toString mediaGid} homelab-media
    usermod --append --groups ${toString mediaGid} abc
  '';
  persistence.media-group = {
    type = "configMap";
    identifier = "media-group";
    defaultMode = 365; # 0555, root-owned and executable by the vendor init.
    advancedMounts.main.main = [
      {
        path = "/custom-cont-init.d/10-media-group.sh";
        subPath = "10-media-group.sh";
        readOnly = true;
      }
    ];
  };
}
