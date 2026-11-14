# Disposable guest experiment only; not a NixOS module or a system installation.
# Pass the existing lts-kernel.nix result and its locked pkgs. Patches must be
# generated from the exact source, limited to ABI-preserving fs/fuse changes.
{
  pkgs,
  kernel,
  patches ? [ ],
}:
assert kernel.version == "6.18.62" && kernel.modDirVersion == "6.18.62";
assert kernel.drvPath == "/nix/store/wq6fwwa4vdsj5wvz66sm6fbp35b036wp-linux-6.18.62.drv";
assert kernel.stdenv.buildPlatform.system == "x86_64-linux";
assert kernel.stdenv.hostPlatform.system == "x86_64-linux";
let
  buildTree = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build";
in
kernel.stdenv.mkDerivation {
  pname = "fuse-disposable-guest";
  inherit (kernel) version src;
  inherit patches;
  patchFlags = [
    "-p1"
    "--fuzz=0"
  ];

  nativeBuildInputs = kernel.moduleBuildDependencies;
  hardeningDisable = [
    "pic"
    "format"
  ];
  dontConfigure = true;
  dontStrip = true;

  makeFlags = kernel.commonMakeFlags;
  buildPhase = ''
    runHook preBuild
    test "$(cat ${buildTree}/include/config/kernel.release)" = "${kernel.modDirVersion}"
    test -s ${buildTree}/Module.symvers
    for option in CONFIG_MODULES=y CONFIG_FUSE_FS=m CONFIG_CUSE=m CONFIG_VIRTIO_FS=m; do
      grep -Fx "$option" ${buildTree}/.config
    done
    make -C ${buildTree} "''${makeFlags[@]}" -j"$NIX_BUILD_CORES" M="$PWD/fs/fuse" modules
    runHook postBuild
  '';

  # Deliberately no modules_install/depmod, initrd, activation or autoload change.
  # Keep the three companions together; virtiofs and cuse depend on fuse.
  installPhase = ''
    runHook preInstall
    for module in fuse cuse virtiofs; do
      install -Dm444 "fs/fuse/$module.ko" "$out/lib/modules/${kernel.modDirVersion}/extra/$module.ko"
    done
    runHook postInstall
  '';

  meta = {
    description = "Same-ABI FUSE modules for the disposable Linux 6.18.62 guest";
    license = pkgs.lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
}
