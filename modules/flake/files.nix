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
            runtimeInputs = [
              pkgs.gitMinimal
              pkgs.jujutsu
            ];
            text = ''
              # The nearest checkout owns the destination, not inherited Git state
              # or a different VCS's enclosing repository.
              unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
              root=$(pwd -P)
              while true; do
                if [[ -e "$root/.git" || -L "$root/.git" ]]; then
                  GIT_DIR=$(git --git-dir="$root/.git" rev-parse --absolute-git-dir)
                  break
                elif [[ -e "$root/.jj" || -L "$root/.jj" ]]; then
                  GIT_DIR=$(jj --ignore-working-copy --repository "$root" git root)
                  break
                elif [[ "$root" == / ]]; then
                  printf '%s\n' '${exeFilename}: no Git or JJ checkout found' >&2
                  exit 1
                fi
                root=''${root%/*}
                root=''${root:-/}
              done
              export GIT_DIR GIT_WORK_TREE="$root"
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
