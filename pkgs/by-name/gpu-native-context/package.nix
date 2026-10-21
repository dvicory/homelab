# Optional userspace only. The root Nixpkgs lock (801bef6) supplies the verified
# LLVM 21, libclc, QEMU, libva/libvpl and OpenVINO dependency recipes.
{ pkgs }:
let
  inherit (pkgs) lib;
  mesaSource = pkgs.fetchFromGitLab {
    domain = "gitlab.freedesktop.org";
    owner = "mesa";
    repo = "mesa";
    rev = "4b0f64ceac6a86af38c1e69cd38cf29f84ba611d";
    hash = "sha256-LkTzaDYiaSBH8gW4RzGSagF/LKFvplz89Kxqb1Ogltg=";
  };
  crateCache = pkgs.runCommand "nativectx-mesa-crate-cache" { } (
    "mkdir -p $out\n"
    + lib.concatMapStringsSep "\n" (
      dep:
      let
        crate = pkgs.fetchCrate (dep // { unpack = false; });
      in
      "ln -s ${crate} $out/${dep.pname}-${dep.version}.tar.gz"
    ) (builtins.fromJSON (builtins.readFile ./mesa-wraps.json))
  );
  headers = pkgs.mesa-gl-headers.overrideAttrs {
    src = mesaSource;
    version = "git-4b0f64ceac6a";
  };
  baseMesa =
    (pkgs.mesa.override {
      galliumDrivers = [ "iris" ];
      vulkanDrivers = [ "intel" ];
      vulkanLayers = [ ];
      mesa-gl-headers = headers;
    }).overrideAttrs
      (old: {
        version = "git-4b0f64ceac6a";
        src = mesaSource;
        outputs = builtins.filter (output: output != "spirv2dxil") old.outputs;
        env = old.env // {
          MESON_PACKAGE_CACHE_DIR = crateCache;
        };
        mesonFlags = old.mesonFlags ++ [
          "-Dintel-virtio-experimental=true"
          "-Dteflon=false"
          "-Dgallium-va=disabled"
        ];
        postInstall = ''
          moveToOutput bin/intel_clc $cross_tools
          moveToOutput bin/mesa_clc $cross_tools
          moveToOutput "lib/lib*OpenCL*" $opencl
          mkdir -p $opencl/etc/OpenCL/vendors
          echo $opencl/lib/libRusticlOpenCL.so > $opencl/etc/OpenCL/vendors/rusticl.icd
        '';
      });

  # Generated against upstream translator v21.1.0 (Nixpkgs source hash
  # sha256-kk8BbPl/UBW1gaO/cuOQ9OsiNTEk0TkvRDLKUAh6exk=).
  # Unsupported Intel assembly must return a library error, not crash Rusticl.
  translator =
    (pkgs.spirv-llvm-translator.override { llvm = pkgs.llvm_21; }).overrideAttrs
      (previous: {
        src = pkgs.applyPatches {
          name = "spirv-llvm-translator-21.1.0-unsupported-inline-asm";
          src = previous.src;
          patches = [ ./unsupported-inline-asm.patch ];
        };
      });
  # Normal compiler linkage and an explicit experimental Iris opt-in, not an
  # addition to upstream's auto policy or an application environment requirement.
  mesa = (baseMesa.override { spirv-llvm-translator = translator; }).overrideAttrs (previous: {
    src = pkgs.applyPatches {
      name = "mesa-i915-native-defaults-4b0f64c";
      src = previous.src;
      patches = [
        ./legacy-mmap-bounds.patch
        ./mesa-gem-semantics.patch
        ./mesa-wait-and-errno.patch
        ./rusticl-iris-opt-in.patch
      ];
    };
    mesonFlags = previous.mesonFlags ++ [ "-Dgallium-rusticl-enable-drivers=iris" ];
  });

  rendererSource = pkgs.applyPatches {
    name = "virglrenderer-i915-v3-source-07a5bc3";
    src = pkgs.fetchFromGitLab {
      domain = "gitlab.freedesktop.org";
      owner = "virgl";
      repo = "virglrenderer";
      rev = "07a5bc398dfffdc36ad20a3476348753aa10a322";
      hash = "sha256-XlgAUQrNSSvqmSf169lD2z64NBpOgPpzYGXWaYYXnWM=";
    };
    # Generated on the exact pin: wire3 separates bounded completion rings from
    # kernel context IDs, retains genuine upstream wire1/2 and checks retirement.
    patches = [
      ./virglrenderer-i915-v3.patch
      ./virglrenderer-gem-semantics.patch
      ./virglrenderer-resource-lifetime.patch
    ];
  };
  renderer = pkgs.virglrenderer.overrideAttrs (old: {
    version = "git-07a5bc398dff-i915-v3";
    src = rendererSource;
    patches = [ ];
    mesonFlags =
      builtins.filter (
        f: !(lib.hasPrefix "-Ddrm-renderers=" f) && !(lib.hasPrefix "-Dvenus=" f)
      ) old.mesonFlags
      ++ [
        "-Ddrm-renderers=i915-experimental"
        "-Dvenus=false"
      ];
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      ${pkgs.coreutils}/bin/timeout --kill-after=2s 30s \
        ${pkgs.meson}/bin/meson test --no-rebuild --print-errorlogs \
          i915-v3-protocol i915-blob-ownership-size i915-blob-ownership-export i915-blob-ownership-success
      runHook postCheck
    '';
  });
  qemu = pkgs.qemu_kvm.override { virglrenderer = renderer; };

  nativeSource = pkgs.applyPatches {
    name = "mesa-i915-media-source-4b0f64c";
    src = mesaSource;
    # Exact-source private media facade reuses Mesa's real i915 client/ABI:
    # fd-local BO namespaces, host errors, PAT capability and wire3 sync files.
    patches = [
      ./mesa-media-native.patch
      ./media-shared-mmap-validation.patch
    ];
  };
  # This target does not use Rusticl. Preserve the verified media-client recipe
  # independently of the corrected OpenCL compiler's dependency rebuild.
  nativeClient = baseMesa.overrideAttrs (previous: {
    pname = "mesa-i915-media-native-client";
    src = nativeSource;
    patches = (previous.patches or [ ]) ++ [
      ./legacy-mmap-bounds.patch
      ./mesa-gem-semantics.patch
      ./mesa-wait-and-errno.patch
    ];
    outputs = [ "out" ];
    buildPhase = ''
      runHook preBuild
      ninja -j"$NIX_BUILD_CORES" src/intel/dev/libintel_media_virtio.so
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 src/intel/dev/libintel_media_virtio.so "$out/lib/libintel_media_virtio.so"
      runHook postInstall
    '';
    postInstall = "";
    postFixup = "";
    doCheck = false;
  });
  pinnedMediaDriver = pkgs.intel-media-driver.overrideAttrs (old: {
    version = "26.4.1-911fe6c";
    src = pkgs.fetchurl {
      url = "https://codeload.github.com/intel/media-driver/tar.gz/911fe6cfab59ea7f2ec17b4e667c5312c9eba0b2";
      name = "media-driver-911fe6cfab59ea7f2ec17b4e667c5312c9eba0b2.tar.gz";
      hash = "sha256-RYJU/Vzs8300dpAG/t4PoI83OUbl9QVzStv8HvBuAtQ=";
    };
    # Nixpkgs compatibility patches target its older revision, not this source.
    patches = [ ];
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];
  });
  mediaSource = pkgs.applyPatches {
    name = "media-driver-i915-native-source-911fe6c";
    src = pinnedMediaDriver.src;
    # Generated on the exact pin: normal MOS buffer-manager callbacks link the
    # Mesa facade; real submit/wait errors propagate, unsupported PAT stays off.
    patches = [ ./media-driver-i915-native.patch ];
  };
  mediaDriver = pinnedMediaDriver.overrideAttrs (old: {
    version = "26.4.1-911fe6c-i915-native";
    src = mediaSource;
    patches = [ ];
    buildInputs = (old.buildInputs or [ ]) ++ [ nativeClient ];
    # DG2 codecs/VPP inherit XeHP shared implementations, gated on XEHP_SDV.
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DENABLE_PRODUCTION_KMD=OFF"
      "-DMEDIA_NATIVE_ERROR_CHECK=ON"
      "-DGEN8=OFF"
      "-DGEN9=OFF"
      "-DGEN11=OFF"
      "-DGEN12=ON"
      "-DGEN12_TGLLP=OFF"
      "-DGEN12_DG1=OFF"
      "-DXe_M=ON"
      "-DDG2=ON"
      "-DXE_HPG=ON"
      "-DXEHP_SDV=ON"
      "-DPVC=OFF"
      "-DMTL=OFF"
      "-DARL=OFF"
      "-DBMG=OFF"
      "-DLNL=OFF"
      "-DNVL=OFF"
      "-DCRI=OFF"
      "-DPTL=OFF"
    ];
    enableParallelBuilding = true;
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      ${pkgs.coreutils}/bin/timeout --kill-after=2s 30s ./media_driver/media-native-error-check
      runHook postCheck
    '';
  });

  vplSource = pkgs.applyPatches {
    name = "vpl-gpu-rt-26.3.0-va-pci-identity-source";
    src = pkgs.fetchurl {
      url = "https://codeload.github.com/intel/vpl-gpu-rt/tar.gz/6582f25d9d800da00a662a53ea4178a82ab69f00";
      name = "vpl-gpu-rt-6582f25d9d800da00a662a53ea4178a82ab69f00.tar.gz";
      hash = "sha256-G5s9ICxF/LhnNmNR5Oa7KGQvL88WHpRERVJH9+DulR0=";
    };
    # Exact deployed 26.3 baseline: reuse GETTABLE VADisplayPCIID rather than
    # rejecting the virtio transport's sysfs vendor before VA initialization.
    patches = [ ./va-pci-identity.patch ];
  };
  vpl = pkgs.vpl-gpu-rt.overrideAttrs (old: {
    version = "26.3.0";
    src = vplSource;
    meta = old.meta // {
      changelog = "https://github.com/intel/vpl-gpu-rt/releases/tag/intel-onevpl-26.3.0";
    };
  });

  # Inherit the locked 2026.3.1 recursive source and normal native/Python ABI:
  # sha256-8oFTHNsxVfgssSFFKO61WoLNnonAcRoNJo8DW2Ec6s0=.
  openvino = pkgs.openvino.overrideAttrs (previous: {
    # Generated on 759c5a6: select CL3 by actual advertised language support,
    # independently of optional work-group collectives; no feature spoofing.
    patches = (previous.patches or [ ]) ++ [ ./openvino-opencl-c-version.patch ];
    # Keep CPU/GPU/Python, ONNX/IR and real GPU kernels; omit unrelated formats.
    cmakeFlags = previous.cmakeFlags ++ [
      "-DENABLE_LTO=OFF"
      "-DENABLE_INTEL_NPU=OFF"
      "-DENABLE_OV_PADDLE_FRONTEND=OFF"
      "-DENABLE_OV_PYTORCH_FRONTEND=OFF"
      "-DENABLE_OV_TF_FRONTEND=OFF"
      "-DENABLE_OV_TF_LITE_FRONTEND=OFF"
    ];
  });
  dispatcher = import ./libvpl-driver-link.nix { inherit pkgs; };
  ffmpeg = pkgs.ffmpeg-full.override { libvpl = dispatcher; };
  driverEnvironment = import ./driver-environment.nix {
    inherit
      pkgs
      mesa
      mediaDriver
      vpl
      ;
  };
  testTools = import ./test-tools.nix {
    inherit
      pkgs
      dispatcher
      ffmpeg
      openvino
      mesaSource
      nativeClient
      ;
  };
  compilerCheck = import ./check-library.nix {
    inherit pkgs;
    compiler = translator;
  };
in
{
  inherit
    qemu
    mesa
    mediaDriver
    vpl
    openvino
    dispatcher
    ffmpeg
    driverEnvironment
    testTools
    ;
  inherit
    renderer
    nativeClient
    translator
    compilerCheck
    ;
  inherit
    mesaSource
    rendererSource
    nativeSource
    mediaSource
    vplSource
    ;
}
