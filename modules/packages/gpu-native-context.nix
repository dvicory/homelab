{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      supported = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
      gpu = import ../../pkgs/by-name/gpu-native-context/package.nix { inherit pkgs; };
    in
    {
      # Export userspace artifacts only; no host driver, service or VM enablement.
      packages = lib.optionalAttrs supported {
        i915-native-qemu = gpu.qemu;
        i915-native-drivers = gpu.driverEnvironment;
        i915-native-test-tools = gpu.testTools;
      };
      checks = lib.optionalAttrs supported {
        i915-native-compiler = gpu.compilerCheck;
        i915-native-oracles = pkgs.runCommand "i915-native-cpu-oracles" { } ''
          ${gpu.testTools}/bin/i915-native-check self-test
          touch "$out"
        '';
      };
    };
}
