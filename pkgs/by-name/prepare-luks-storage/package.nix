{
  lib,
  writeShellApplication,
  coreutils,
  cryptsetup,
  gptfdisk,
  python3,
  rsync,
  util-linux,
  udev,
  xfsprogs,
}:
writeShellApplication {
  name = "prepare-luks-storage";
  meta = {
    description = "Read-only disk preflight with separately approved LUKS2 format and verified copy";
    platforms = lib.platforms.linux;
  };
  runtimeInputs = [
    coreutils
    cryptsetup
    gptfdisk
    python3
    rsync
    util-linux
    udev
    xfsprogs
  ];
  text = builtins.readFile ./prepare-luks-storage.sh;
}
