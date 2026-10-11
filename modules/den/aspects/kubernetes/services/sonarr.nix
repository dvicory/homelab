{ den, ... }:
{
  # Keep Sonarr independently selectable while its implementation belongs to
  # the media-owned Arr family.
  den.aspects.kubernetes.services.sonarr.includes = [
    den.aspects.kubernetes.services.media.arr.provides.sonarr
  ];
}
