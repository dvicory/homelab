import ./_arr.nix {
  kind = "sonarr";
  port = 8989;
  # Container IDs coincide with host service-account numbers by convention only.
  identity = {
    uid = 753;
    gid = 753;
  };
  image = {
    repository = "ghcr.io/linuxserver/sonarr";
    tag = "latest";
    digest = "sha256:4d9df314875e1249ab7d6170c2b9b3dc1d8e6383f168ceb10dc9a5ad9b324739";
  };
}
