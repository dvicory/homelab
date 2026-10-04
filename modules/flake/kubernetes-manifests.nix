{
  inputs,
  lib,
  self,
  rootPath,
  ...
}:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      environment = self.nixidyEnvs.${system}.prod-home.config.build.environmentPackage;
      manifestSource = rootPath + "/generated/manifests/prod-home";
      generatedManifests =
        if builtins.pathExists manifestSource then
          manifestSource
        else
          throw ''
            Canonical production manifests are missing. Generate them with:
              nix run .#sync-prod-home-manifests
            Then review and track generated/manifests/prod-home before running this check.
          '';
    in
    {
      packages.prod-home-manifests = environment;

      apps.sync-prod-home-manifests = {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = "sync-prod-home-manifests";
            runtimeInputs = [
              pkgs.coreutils
              config.flake-root.package
              pkgs.rsync
            ];
            text = ''
              set -euo pipefail
              source=${environment}
              root="$(${lib.getExe config.flake-root.package})"
              destination="$root/generated/manifests/prod-home"
              rm -rf "$destination"
              mkdir -p "$destination"

              # Copy the store's symlinked tree as ordinary checked-in files and
              # omit nixidy's volatile revision marker. Fresh mtimes let jj
              # notice equal-sized content changes from immutable store files.
              rsync -a --no-times --copy-links --delete --exclude .revision \
                --chmod=Du+rwx,Dg+rx,Do+rx,Fu+rw,Fg+r,Fo+r \
                "$source"/ "$destination"/

              cat <<EOF
              Wrote canonical prod-home manifests from the ${system} renderer.
              Review the tree, then track new YAML before evaluating checks:
                jj file track generated/manifests/prod-home
              EOF
            '';
          }
        );
      };
      apps.media-live-acceptance = {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = "media-live-acceptance";
            runtimeInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
              pkgs.docker
              pkgs.openssl
              pkgs.git
              config.flake-root.package
            ];
            text = ''
              root="$(${lib.getExe config.flake-root.package})"
              exec python "$root/modules/tests/media-live-acceptance.py" "$@"
            '';
          }
        );
      };

      checks.prod-home-manifests-fresh =
        pkgs.runCommandLocal "prod-home-manifests-fresh"
          {
            src = generatedManifests;
            expected = environment;
            nativeBuildInputs = [
              pkgs.diffutils
              pkgs.rsync
            ];
          }
          ''
            work=$(mktemp -d)
            trap 'rm -rf "$work"' EXIT
            cp -aL "$expected"/. "$work"/
            chmod -R u+w "$work"
            if ! diff -qr --exclude=.revision "$src" "$work" > diff-report.txt; then
              cat diff-report.txt
              cat >&2 <<'EOF'
            Canonical prod-home manifests are stale. Regenerate them with:
              nix run .#sync-prod-home-manifests
            EOF
              exit 1
            fi
            touch $out
          '';

      checks.argocd-application-health =
        pkgs.runCommandLocal "argocd-application-health"
          {
            src = environment;
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
              pkgs.lua
            ];
          }
          ''
            export MANIFEST_ROOT="$src"
            python - <<'PY'
            from pathlib import Path
            import os
            import subprocess
            import yaml

            argocd_cm = Path(os.environ["MANIFEST_ROOT"]) / "argocd" / "ConfigMap-argocd-cm.yaml"
            health_lua = yaml.safe_load(argocd_cm.read_text())["data"]["resource.customizations.health.argoproj.io_Application"]
            assert isinstance(health_lua, str) and health_lua.strip(), f"{argocd_cm}: Application health customization is missing"
            subprocess.run(
                ["lua", "-e", """
            local health = assert(load(io.read("*a")))
            local cases = {
              {object = {}, status = "Progressing", message = ""},
              {object = {status = {}}, status = "Progressing", message = ""},
              {object = {status = {health = {status = "Healthy"}}}, status = "Healthy", message = ""},
              {object = {status = {health = {status = "Healthy", message = "ready"}}}, status = "Healthy", message = "ready"},
              {object = {status = {health = {status = "Degraded", message = "child failed"}}}, status = "Degraded", message = "child failed"},
              {object = {status = {sync = {status = "OutOfSync"}, health = {status = "Healthy"}}}, status = "Healthy"},
              {object = {status = {conditions = {{type = "SharedResourceWarning"}}, health = {status = "Healthy"}}}, status = "Healthy"},
              {object = {status = {conditions = {{type = "ComparisonError"}}, health = {status = "Healthy"}}}, status = "Degraded"},
              {object = {status = {conditions = {{type = "ComparisonError"}}}}, status = "Degraded"},
              {object = {status = {conditions = {}, health = {status = "Healthy"}}}, status = "Healthy", message = ""}
            }
            for _, case in ipairs(cases) do
              obj = case.object
              local result = health()
              assert(result.status == case.status, "child health: expected " .. case.status .. ", got " .. tostring(result.status))
              if case.message ~= nil then
                assert(result.message == case.message, "child health message was not preserved")
              end
            end
                """],
                input=health_lua,
                text=True,
                check=True,
            )
            PY
            touch $out
          '';
    };
}
