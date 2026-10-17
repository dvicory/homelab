{
  config,
  lib,
  self,
  ...
}:
let
  domain = builtins.head config.den.clusters."prod-home".routes.idm.hostnames;
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      apps.household-sign-in-runtime = {
        type = "app";
        program = lib.getExe self.packages.${system}.household-sign-in-runtime;
      };
      packages.household-sign-in-runtime = pkgs.writeShellApplication {
        name = "household-sign-in-runtime";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.docker
          pkgs.openssl
          pkgs.openldap
          (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
        ];
        text =
          let
            source = lib.fileset.toSource {
              root = ../..;
              fileset = lib.fileset.unions [
                ./household-sign-in-runtime.py
                ../../generated/manifests/prod-home
              ];
            };
          in
          ''
            if [[ "''${1:-}" == --help ]]; then
              echo 'Run the complete household sign-in suite as root in an exclusive disposable native x86 Docker fixture.'
              echo 'Requires ${domain} resolving to 127.0.0.1; never run on a production host.'
              echo 'Fixture data uses the configured TMPDIR parent, or /root when unset.'
              exit 0
            fi
            test "$#" -eq 0
            test "$(id -u)" -eq 0
            test "$(uname -m)" = x86_64
            export DOCKER_HOST=unix:///var/run/docker.sock
            unset DOCKER_CONTEXT
            case "$(docker info --format '{{.OSType}}/{{.Architecture}}')" in
              linux/x86_64|linux/amd64) ;;
              *) echo 'Native linux/amd64 Docker required' >&2; exit 1 ;;
            esac
            python -c 'import socket; assert socket.gethostbyname("${domain}") == "127.0.0.1", "Canonical directory hostname must resolve to loopback"'
            work="$(realpath -e "''${TMPDIR:-/root}")/household"
            test ! -e "$work"
            test ! -L "$work"
            for name in kanidm jellyfin seerr; do
              if docker container inspect "$name" >/dev/null 2>&1; then
                echo "Refusing existing fixture container $name" >&2
                exit 1
              fi
            done
            if docker network inspect household >/dev/null 2>&1; then
              echo 'Refusing existing fixture network household' >&2
              exit 1
            fi

            cleanup() {
              status=$?
              trap - EXIT
              failed=0
              if ! ids=$(docker container ls --all --quiet); then failed=1; ids=; fi
              for id in $ids; do
                if ! mounts=$(docker container inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$id"); then
                  failed=1
                  continue
                fi
                while IFS= read -r mount; do
                  if [[ "$mount" == "$work/"* ]]; then
                    if ! docker container rm --force "$id"; then failed=1; fi
                    break
                  fi
                done <<< "$mounts"
              done
              if ! networks=$(docker network ls --filter name=^household$ --format '{{.Name}}'); then failed=1; networks=; fi
              if [[ -n "$networks" ]] && ! docker network rm household; then failed=1; fi
              if ! rm -rf "$work"; then failed=1; fi
              printf 'EVIDENCE owned-cleanup {"exit":%s,"cleanup_succeeded":%s}\n' "$status" "$([[ "$failed" == 0 ]] && echo true || echo false)"
              if [[ "$failed" != 0 ]]; then exit 1; fi
              exit "$status"
            }
            trap cleanup EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM
            # Docker pulls the selected digest references from the committed manifests.
            python ${source}/modules/tests/household-sign-in-runtime.py --domain ${domain} --work-dir "$work"
          '';
      };
    };
}
