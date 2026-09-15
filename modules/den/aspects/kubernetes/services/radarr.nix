import ./_arr.nix {
  kind = "radarr";
  port = 7878;
  # Container IDs coincide with host service-account numbers by convention only.
  identity = {
    uid = 752;
    gid = 752;
  };
  image = {
    repository = "ghcr.io/linuxserver/radarr";
    tag = "latest";
    digest = "sha256:95ba0801df4d9d1d79d0d9a3849f656542497dab061d91b87ad4f53a71aff3ef";
  };
}
