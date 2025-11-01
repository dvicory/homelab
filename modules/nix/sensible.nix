{ lib, ... }:
{
  flake.modules.generic.nix-common = {
    nix = {
      settings = {
        # https://jackson.dev/post/nix-reasonable-defaults/
        connect-timeout = 5;
        log-lines = 50;
        min-free = 128000000;
        max-free = 1000000000;

        download-buffer-size = 524288000; # 500 MiB

        trusted-users = [ "@wheel" ];
      };
    };
  };
}
