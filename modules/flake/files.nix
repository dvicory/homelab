{ inputs, ... }:
{
  flake-file.inputs.files.url = "github:sini/files";
  imports = [ inputs.files.flakeModules.default ];
  perSystem =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      app = { drv, exeFilename, ... }: {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = exeFilename;
            runtimeInputs = [ pkgs.jujutsu ];
            text = ''
              # Upstream discovers the working tree through Git, including in JJ workspaces.
              if root=$(jj root 2>/dev/null); then
                GIT_DIR=$(jj git root)
                export GIT_DIR GIT_WORK_TREE="$root"
              fi
              exec ${lib.getExe drv} "$@"
            '';
          }
        );
      };
    in
    {
      apps.write-files = app config.files.writer;
      apps.diff-files = app config.files.diff;
    };
}
