{
  config,
  lib,
  rootPath,
  self,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    let
      manifests = rootPath + "/generated/manifests/prod-home";
      # Match the API fixture's selected Linux guest package, even on Darwin.
      configurations = import ./_compute-configurations.nix {
        inherit self lib;
        system = "x86_64-linux";
        hostName = config.den.clusters.prod-home.hostName;
      };
      k3sPackage = configurations.guest.config.services.k3s.package;
      kubernetesVersion = lib.head (lib.splitString "+" k3sPackage.version);
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      helper = ./_kubernetes-schema.py;
      registryRevision = "a6f9a32d2ccb64b6e4f5b41419b9c2e8ee0cce18";
      schemaInputs = builtins.fromJSON (builtins.readFile ./_kubernetes-schema-inputs.json);
      converter = pkgs.fetchurl {
        # The commit behind upstream v0.8.0, not a moving tag or local fork.
        url = "https://raw.githubusercontent.com/yannh/kubeconform/02374e583d700721f57300fae78e11acd27ee539/scripts/openapi2jsonschema.py";
        hash = "sha256-0UW6v7t2UAQDB2ThtOUYv7ekvX8RFpGgj6V5g7gYgfM=";
      };
      copyInput =
        input:
        let
          source =
            assert lib.assertMsg (lib.hasPrefix "v${kubernetesVersion}-" input.path)
              "Pinned Kubernetes schemas must match the selected K3s package.";
            pkgs.fetchurl {
              url = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${registryRevision}/${input.path}";
              inherit (input) hash;
            };
          apiParts = lib.splitString "/" (input.apiVersion or "");
          filename =
            if input ? kind then
              "${builtins.head apiParts}__${lib.toLower input.kind}__${lib.last apiParts}.json"
            else
              "_definitions.json";
        in
        "cp ${source} \"$out/${filename}\"";
      schemas =
        pkgs.runCommand "prod-home-kubernetes-schemas-${kubernetesVersion}"
          {
            nativeBuildInputs = [ python ];
          }
          ''
            mkdir -p "$out"
            printf '%s\n' ${lib.escapeShellArg kubernetesVersion} > "$out/kubernetes-version"
            ${lib.concatMapStringsSep "\n" copyInput schemaInputs}
            ${python}/bin/python ${helper} derive \
              --manifests ${manifests} --schemas "$out" --converter ${converter}
          '';
      # Strict built-ins, but the official recursive CRD envelope permits extra
      # fields. Converted CRDs also do not prove ObjectMeta, CEL, admission,
      # pruning/defaulting, immutable updates or controller behavior. Preserve
      # metadata and semantic joins in prod-home-manifests-policy and API checks.
      runner = pkgs.writeShellApplication {
        name = "check-prod-home-manifests-schema";
        runtimeInputs = [
          python
          pkgs.kubeconform
        ];
        text = ''
          if [ "$#" -gt 3 ]; then
            echo "usage: check-prod-home-manifests-schema [manifest-root [schema-root [report.json]]]" >&2
            exit 2
          fi
          ${python}/bin/python ${helper} validate \
            --manifests "''${1:-${manifests}}" \
            --schemas "''${2:-${schemas}}" \
            --report "''${3:-schema-report.json}" \
            --kubeconform ${lib.getExe pkgs.kubeconform}
        '';
      };
    in
    {
      checks.prod-home-manifests-schema = pkgs.runCommandLocal "prod-home-manifests-schema" { } ''
        mkdir -p "$out"
        ${lib.getExe runner} ${manifests} ${schemas} "$out/report.json"
        ${python}/bin/python ${./_kubernetes-schema-mutations.py} \
          --helper ${helper} --manifests ${manifests} --schemas ${schemas} \
          --converter ${converter} --kubeconform ${lib.getExe pkgs.kubeconform}
      '';
      packages.prod-home-manifests-schema = runner;
      packages.prod-home-kubernetes-schemas = schemas;
    };
}
