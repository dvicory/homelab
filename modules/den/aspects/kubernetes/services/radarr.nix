{ den, ... }:
{
  # Keep Radarr independently selectable while its implementation belongs to
  # the media-owned Arr family.
  den.aspects.kubernetes.services.radarr.includes = [
    den.aspects.kubernetes.services.media.arr.provides.radarr
  ];
}
