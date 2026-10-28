{
  pkgs,
  mesa,
  mediaDriver,
  vpl,
}:
let
  # This alias belongs only to the explicitly selected i915-native guest profile.
  # iHD still probes the actual native capset and rejects unsupported backends.
  # Keep the canonical filename in mediaDriver for normal explicit iHD selection.
  vaAlias = pkgs.runCommand "i915-native-va-driver-alias" { } ''
    mkdir -p "$out/lib/dri"
    ln -s ${mediaDriver}/lib/dri/iHD_drv_video.so "$out/lib/dri/virtio_gpu_drv_video.so"
  '';
in
pkgs.buildEnv {
  name = "i915-native-guest-drivers";
  paths = [
    mesa
    mesa.opencl
    mediaDriver
    vpl
    vaAlias
  ];
  pathsToLink = [
    "/lib"
    "/share"
    "/etc"
  ];
}
