{
  dockerTools,
  compute-runtime,
}:
let
  # Only the one command, without the lifecycle tools' wrapped dependencies.
  command = compute-runtime.overrideAttrs {
    pname = "retained-directories";
    subPackages = [ "cmd/retained-directories" ];
    postInstall = "";
  };
  image = dockerTools.buildLayeredImage {
    name = "homelab/retained-directories";
    compressor = "none";
    config = {
      Entrypoint = [ "${command}/bin/retained-directories" ];
      User = "0:0";
    };
  };
in
image.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    imageReference = "${image.imageName}:${image.imageTag}";
  };
})
