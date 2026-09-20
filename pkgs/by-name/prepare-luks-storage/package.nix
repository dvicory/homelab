{
  lib,
  writeShellApplication,
  coreutils,
  cryptsetup,
  gptfdisk,
  util-linux,
  udev,
}:
writeShellApplication {
  name = "prepare-luks-storage";
  meta = {
    description = "Read-only declared-disk preflight and explicitly approved LUKS2 formatter";
    platforms = lib.platforms.linux;
  };
  runtimeInputs = [
    coreutils
    cryptsetup
    gptfdisk
    util-linux
    udev
  ];
  text = builtins.readFile ./prepare-luks-storage.sh;
}
