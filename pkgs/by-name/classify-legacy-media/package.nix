{
  lib,
  callPackage,
  writeShellApplication,
  acl,
  coreutils,
  diffutils,
  findutils,
  gnugrep,
  gnused,
  python3,
  util-linux,
  prepare-luks-storage ? callPackage ../prepare-luks-storage/package.nix { },
}:
writeShellApplication {
  name = "classify-legacy-media";
  meta = {
    description = "Move known media from a verified seed copy into pool/, keeping the rest in migration/";
    platforms = lib.platforms.linux;
  };
  runtimeInputs = [
    acl
    coreutils
    diffutils
    findutils
    gnugrep
    gnused
    python3
    util-linux
  ];
  text = ''
    PREPARE_LUKS_STORAGE=${prepare-luks-storage}/bin/prepare-luks-storage
  ''
  + builtins.readFile ./classify-legacy-media.sh;
}
