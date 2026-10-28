# Real application and native API checks. This package launches no VM and grants
# no GPU access. Hardware commands require explicit transport-owner admission.
# Drivers must be registered through the guest's normal graphics paths.
{
  pkgs,
  dispatcher,
  ffmpeg,
  openvino,
  mesaSource,
  nativeClient,
}:
let
  python = pkgs.python3.withPackages (ps: [
    (ps.openvino.override { openvino-native = openvino; })
    ps.numpy
    ps.opencv4
  ]);
  apiChecks = pkgs.runCommandCC "i915-native-api-checks" { } ''
    mkdir -p "$out/bin"
    $CC -std=c11 -Wall -Wextra -I${mesaSource}/include \
      ${./gates/native-errno-check.c} -ldl -o "$out/bin/ioctl-errno"
    $CC -std=c11 -Wall -Wextra -I${pkgs.linuxHeaders}/include/drm \
      ${./gates/vgem-wait-check.c} -ldl -pthread -o "$out/bin/fence-wait"
  '';
  session = pkgs.stdenv.mkDerivation {
    pname = "onevpl-hardware-session-gate";
    version = "20261020";
    src = ./gates/onevpl-session.c;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [
      pkgs.libva
      dispatcher
    ];
    buildPhase = ''
      $CC -std=c11 -D_GNU_SOURCE -Wall -Wextra "$src" -o onevpl-session $(pkg-config --cflags --libs libva libva-drm vpl)
    '';
    installPhase = ''
      install -Dm755 onevpl-session "$out/bin/onevpl-session"
    '';
  };
  # Immutable public application inputs; no local model blobs or derived IR.
  model = pkgs.fetchurl {
    url = "https://media.githubusercontent.com/media/onnx/models/c5cae0f1942c8d7727372c7b1f6b485aa39e4421/validated/vision/classification/squeezenet/model/squeezenet1.0-12.onnx";
    sha256 = "dec81a8684617770b3cf13fadc1d92565d1d453d23935fc6388b792d99c992bd";
  };
  sample = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/openvinotoolkit/openvino/2026.3.1/samples/python/hello_classification/hello_classification.py";
    sha256 = "7fe509f9667008b60ca4bb496fb306503e045e67492bc70cbe9f94d47e89fd1a";
  };
  image = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/pytorch/hub/3b54eaafd931b0c0f3ee2df391bb4be7ba6f1ca3/images/dog.jpg";
    sha256 = "f3f87bb8ab3c26c7ecfd3ac60421d7f32b0503d1d6c5baf8bac42ed93d86351a";
  };
in
pkgs.writeShellApplication {
  name = "i915-native-check";
  runtimeInputs = [
    pkgs.coreutils
    ffmpeg
    pkgs.strace
    session
  ];
  inheritPath = false;
  passthru = {
    inherit
      python
      session
      model
      sample
      image
      apiChecks
      ;
  };
  meta = {
    description = "Native-context GPU test tools and fixtures for FFmpeg, oneVPL and OpenVINO";
    platforms = [ "x86_64-linux" ];
  };
  text = ''
    # Exercise normal discovery, never an inherited private-driver recipe.
    unset LD_PRELOAD LD_LIBRARY_PATH RUSTICL_ENABLE RUSTICL_FEATURES RUSTICL_DEVICE_TYPE \
      OCL_ICD_VENDORS LIBVA_DRIVER_NAME LIBVA_DRIVERS_PATH ONEVPL_SEARCH_PATH ONEVPL_PRIORITY_PATH \
      MESA_LOADER_DRIVER_OVERRIDE GALLIUM_DRIVER GBM_BACKENDS_PATH LIBGL_DRIVERS_PATH \
      __EGL_VENDOR_LIBRARY_FILENAMES
    export PYTHONDONTWRITEBYTECODE=1

    case "''${1:-}" in
      media)
        shift
        # The reviewed media gate distinguishes CPU preparation from hardware
        # gates and requires --transport-ready for every hardware operation.
        exec ${pkgs.python3}/bin/python ${./gates}/media-gate.py "$@"
        ;;
      ffmpeg-opencl|openvino|ioctl-errno|fence-wait)
        gate="$1"
        shift
        if [[ "''${1:-}" != --transport-ready ]]; then
          echo 'Hardware gate requires transport-owner --transport-ready; never run on host' >&2
          exit 2
        fi
        shift
        if [[ "$gate" == ffmpeg-opencl ]]; then
          exec timeout --kill-after=5s 150s ${pkgs.python3}/bin/python \
            ${./gates}/ffmpeg_opencl_checked.py --ffmpeg ${ffmpeg}/bin/ffmpeg "$@"
        elif [[ "$gate" == openvino ]]; then
          exec timeout --kill-after=5s 180s ${python}/bin/python \
            ${./gates}/official_openvino_checked.py \
            --model ${model} --sample ${sample} --image ${image} "$@"
        else
          exec timeout --kill-after=5s 60s ${apiChecks}/bin/"$gate" \
            ${nativeClient}/lib/libintel_media_virtio.so "$@"
        fi
        ;;
      self-test)
        # CPU-only corruption-rejecting oracles; not hardware acceptance.
        ${pkgs.python3}/bin/python ${./gates}/test-media-gate.py
        exec ${python}/bin/python ${./gates}/official_openvino_checked.py --self-test
        ;;
      -h|--help)
        printf '%s\n' \
          'i915-native-check media GATE --out DIR [--transport-ready] [--device NODE]' \
          'i915-native-check ffmpeg-opencl --transport-ready --output-dir NEW_DIR' \
          'i915-native-check openvino --transport-ready --output-dir NEW_DIR' \
          'i915-native-check ioctl-errno --transport-ready RENDER_NODE' \
          'i915-native-check fence-wait --transport-ready RENDER_NODE VGEM_NODE' \
          'i915-native-check self-test  # CPU oracles only' \
          'Requires matching drivers registered normally in the guest; use media --help for gates.'
        ;;
      *)
        echo 'Expected media, ffmpeg-opencl, openvino, ioctl-errno, fence-wait, self-test or --help' >&2
        exit 2
        ;;
    esac
  '';
}
