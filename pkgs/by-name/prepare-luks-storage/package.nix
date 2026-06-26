{
  lib,
  writeShellApplication,
  coreutils,
  cryptsetup,
  gptfdisk,
  util-linux,
}:
writeShellApplication {
  name = "prepare-luks-storage";
  meta = {
    description = "One-shot provisioner that creates a LUKS container on a fresh disk";
    platforms = lib.platforms.linux;
  };
  runtimeInputs = [
    coreutils
    cryptsetup
    gptfdisk
    util-linux
  ];
  text = builtins.readFile ./prepare-luks-storage.sh;
}
