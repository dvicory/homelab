{
  applyPatches,
  k3s_1_36,
}:
let
  # cAdvisor 0.60.6's 0e107a38 backported to the selected 0.56.2 vendor tree.
  # Keep Nixpkgs' source/vendor hashes; patch the verified vendor output in a
  # separate derivation rather than changing a fixed-output dependency fetch.
  goModules = applyPatches {
    name = "k3s-${k3s_1_36.version}-cadvisor-zfs-vfs-fallback";
    src = k3s_1_36.goModules;
    patches = [ ./cadvisor-zfs-vfs-fallback.patch ];
  };
in
# The kubelet is compiled in k3sBundle (k3s-bin), then embedded in the outer
# runtime wrapper. Patching only the outer derivation leaves kubelet unchanged.
(k3s_1_36.override {
  overrideBundleAttrs = old: {
    inherit goModules;
    preBuild = (old.preBuild or "") + ''
      # Retain and run the released fix's behavioral tests before compiling.
      go test github.com/google/cadvisor/fs/zfs
    '';
  };
}).overrideAttrs
  {
    inherit goModules;
  }
