{
  pkgs,
  libvpl ? pkgs.libvpl,
}:
let
  # Generated from intel/libvpl v2.16.0, the root Nixpkgs recipe's source.
  # Keep its existing full-discovery patch and add the same directory to the
  # separate low-latency search, without changing load failures or priorities.
  patch = pkgs.replaceVars ./libvpl-lowlatency-driver-link.patch {
    inherit (pkgs.addDriverRunpath) driverLink;
  };
in
libvpl.overrideAttrs (previous: {
  # The package set and guest overlay may both consume this helper.
  patches = pkgs.lib.unique ((previous.patches or [ ]) ++ [ patch ]);
})
