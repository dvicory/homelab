import ./_arr.nix {
  kind = "sonarr";
  port = 8989;
  # LinuxServer supports an explicit PUID; this is a guest-local identity.
  uid = 753;
  image = {
    repository = "ghcr.io/linuxserver/sonarr";
    tag = "latest";
    digest = "sha256:4d9df314875e1249ab7d6170c2b9b3dc1d8e6383f168ceb10dc9a5ad9b324739";
  };
}
