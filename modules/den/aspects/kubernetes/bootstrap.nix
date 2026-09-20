{ lib, rootPath, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      manifestSource = rootPath + "/generated/manifests/prod-home";
      environment =
        if builtins.pathExists manifestSource then
          manifestSource
        else
          throw ''
            Canonical production manifests are missing. Generate them with:
              nix run .#sync-prod-home-manifests
            Then review and track generated/manifests/prod-home before building bootstrap artifacts.
          '';
      manifests = pkgs.runCommand "household-static-bootstrap" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
        mkdir -p "$out"
        cp ${environment}/argocd-retained/Namespace-argocd.yaml "$out/namespaces.yaml"
        yq '.' ${environment}/argocd/CustomResourceDefinition-*.yaml > "$out/crds.yaml"
        rm -f "$out/controllers.yaml"
        first=1
        for file in ${environment}/argocd/*.yaml; do
          case "$(basename "$file")" in
            CustomResourceDefinition-*) ;;
            *)
              if [ "$first" -eq 1 ]; then first=0; else printf '\n---\n' >> "$out/controllers.yaml"; fi
              cat "$file" >> "$out/controllers.yaml"
              ;;
          esac
        done
        cp ${environment}/bootstrap.yaml "$out/root.yaml"
        yq 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")' "$out/controllers.yaml" > "$out/readiness.yaml"
        yq 'select(.kind == "Prometheus" or .kind == "Alertmanager")' "$out/controllers.yaml" > "$out/operator-readiness.yaml"
        yq 'select(.kind == "Job")' "$out/controllers.yaml" > "$out/jobs.yaml"
        yq 'select(.kind == "Job" and .spec.ttlSecondsAfterFinished == null)' "$out/controllers.yaml" > "$out/persistent-jobs.yaml"
        yq 'select((.metadata.annotations."helm.sh/hook" // "") | contains("pre-install"))' "$out/controllers.yaml" > "$out/pre-install.yaml"
        yq 'select(.kind == "Job")' "$out/pre-install.yaml" > "$out/pre-install-jobs.yaml"
      '';
      runtime = config.packages.compute-runtime;
      bootstrap = pkgs.runCommand "household-bootstrap" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
        mkdir -p "$out/bin"
        makeWrapper ${runtime}/bin/household-bootstrap "$out/bin/household-bootstrap" \
          --set-default HOUSEHOLD_BOOTSTRAP_MANIFESTS ${manifests}
      '';
    in
    {
      checks.household-bootstrap-crds =
        pkgs.runCommand "household-bootstrap-crds" { nativeBuildInputs = [ pkgs.yq-go ]; }
          ''
            yq ea -e '[select(.kind == "CustomResourceDefinition") | .metadata.name] | sort | join(",") == "applications.argoproj.io,applicationsets.argoproj.io,appprojects.argoproj.io"' \
              ${manifests}/crds.yaml > /dev/null
            touch "$out"
          '';

      packages = {
        household-bootstrap-manifests = manifests;
        household-bootstrap = bootstrap;
      }
      // lib.optionalAttrs (lib.hasSuffix "-linux" system) (
        let
          hostBootstrap =
            pkgs.runCommand "household-bootstrap-host" { nativeBuildInputs = [ pkgs.makeWrapper ]; }
              ''
                mkdir -p "$out/bin"
                makeWrapper ${runtime}/bin/household-bootstrap-host "$out/bin/household-bootstrap-host" \
                  --set-default HOUSEHOLD_BOOTSTRAP_MANIFESTS ${manifests} \
                  --set-default HOUSEHOLD_BOOTSTRAP_BIN ${bootstrap}/bin/household-bootstrap
              '';
        in
        {
          household-bootstrap-host = hostBootstrap;
          household-bootstrap-bundle = pkgs.linkFarm "household-bootstrap-bundle" [
            {
              name = "manifests";
              path = manifests;
            }
            {
              name = "bin/household-bootstrap";
              path = "${bootstrap}/bin/household-bootstrap";
            }
            {
              name = "bin/household-bootstrap-host";
              path = "${hostBootstrap}/bin/household-bootstrap-host";
            }
            {
              name = "operations.md";
              path = config.files.file."docs/operations.md".source;
            }
          ];
        }
      );
    };
}
