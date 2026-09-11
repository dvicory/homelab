{ config, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      environment = ../../generated/manifests/prod-home;
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      storage = pkgs.writeText "retained-storage-contract.json" (
        builtins.toJSON {
          inherit (compute) instance retainedPaths;
        }
      );
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.retained-storage-contracts =
        pkgs.runCommand "retained-storage-contracts"
          {
            nativeBuildInputs = [ python ];
          }
          ''
            python - ${environment} ${storage} <<'PY'
            import json
            import pathlib
            import sys
            import yaml

            environment = pathlib.Path(sys.argv[1])
            storage = json.loads(pathlib.Path(sys.argv[2]).read_text())
            resources = []
            rendered = []
            for path in environment.rglob("*.yaml"):
                documents = [resource for resource in yaml.load_all(path.read_text(), Loader=yaml.BaseLoader) if resource]
                resources.extend(documents)
                rendered.append((path.parent, documents))
            retained_dirs = {
                directory
                for directory, documents in rendered
                if any(
                    resource.get("kind") == "PersistentVolume"
                    and "local" in resource.get("spec", {})
                    for resource in documents
                )
            }
            retained_resources = [
                resource
                for directory, documents in rendered
                if directory in retained_dirs
                for resource in documents
            ]

            pvs = {
                resource["metadata"]["name"]: resource
                for resource in resources
                if resource.get("kind") == "PersistentVolume"
                and "local" in resource.get("spec", {})
            }
            pvcs = [resource for resource in resources if resource.get("kind") == "PersistentVolumeClaim"]
            declared_paths = {
                entry["guestPath"] for entry in storage["retainedPaths"].values()
            }

            assert pvs, "No rendered local PersistentVolumes"
            for name, resource in pvs.items():
                spec = resource["spec"]
                assert spec["local"]["path"] in declared_paths, name
                assert spec.get("persistentVolumeReclaimPolicy", "Retain") == "Retain", name

                terms = spec["nodeAffinity"]["required"]["nodeSelectorTerms"]
                assert terms and all(
                    any(
                        expression["key"] == "kubernetes.io/hostname"
                        and expression["operator"] == "In"
                        and expression["values"] == [storage["instance"]]
                        for expression in term["matchExpressions"]
                    )
                    for term in terms
                ), name

                claims = [
                    claim
                    for claim in pvcs
                    if claim["spec"].get("volumeName") == name
                ]
                assert len(claims) == 1, name
                claim = claims[0]
                assert (
                    claim["spec"]["volumeName"] == name
                    and claim["spec"]["storageClassName"] == spec["storageClassName"]
                ), name

            # Only directories that declare local PVs are retained-manifest inputs;
            # unrelated generated Secrets such as monitoring's alertmanager config
            # are not retained-storage payloads.
            assert not any(
                resource.get("kind") == "Secret"
                and (resource.get("data") or resource.get("stringData"))
                for resource in retained_resources
            ), "Rendered retained-manifest Secret payload"
            PY
            touch "$out"
          '';
    };
}
