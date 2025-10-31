{ ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      apps = {
        sops = {
          type = "app";
          program = pkgs.writeShellApplication {
            name = "sops";
            text = ''
              FLAKE_ROOT="''$(${lib.getExe config.flake-root.package})"
              export FLAKE_ROOT
              export SOPS_AGE_KEY_FILE="''${FLAKE_ROOT}/sops.key"
              exec ${pkgs.sops}/bin/sops "$@"
            '';
          };
        };

        ssh-to-age = {
          type = "app";
          program = pkgs.ssh-to-age;
        };

        mkpasswd = {
          type = "app";
          program = pkgs.mkpasswd;
        };
      };
    };
}
