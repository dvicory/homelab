{ ... }:
{
  den.aspects.virtualization.i915-native-host.nixos =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      gpu = import ../../../../pkgs/by-name/gpu-native-context/package.nix { inherit pkgs; };
      helpers = pkgs.linkFarm "i915-native-qemu-libexec" [
        {
          name = "bin";
          path = "${gpu.qemu}/libexec";
        }
      ];
    in
    {
      assertions = [
        {
          assertion = config.virtualisation.incus.enable;
          message = "i915-native host userspace requires the host's ordinary Incus service.";
        }
        {
          assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
          message = "i915-native host userspace currently supports x86_64 Linux.";
        }
      ];

      # Select the actual provider before upstream's stock QEMU/helper paths.
      # This changes neither Incus ownership nor its network/security policy.
      systemd.services.incus.path = lib.mkBefore [
        gpu.qemu
        helpers
      ];
      # Only the isolated hypervisor needs this GBM/EGL provider. Guest apps use
      # their normal node-managed driver discovery, without a private recipe.
      systemd.services.incus.environment = {
        GBM_BACKENDS_PATH = "${gpu.mesa}/lib/gbm";
        LIBGL_DRIVERS_PATH = "${gpu.mesa}/lib/dri";
        __EGL_VENDOR_LIBRARY_FILENAMES = "${gpu.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
      };
    };
}
