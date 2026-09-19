{ config, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      environment = ../../generated/manifests/prod-home;
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      storage = pkgs.writeText "jellyfin-storage-contract.json" (
        builtins.toJSON {
          inherit (compute) retainedPaths;
        }
      );
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.jellyfin-contracts =
        pkgs.runCommand "jellyfin-contracts"
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
            for application in ("jellyfin-retained", "jellyfin"):
                for path in (environment / application).rglob("*.yaml"):
                    resources.extend(resource for resource in yaml.safe_load_all(path.read_text()) if resource)

            def find(kind, name):
                return next(
                    resource
                    for resource in resources
                    if resource["kind"] == kind and resource["metadata"]["name"] == name
                )

            retained = storage["retainedPaths"]["jellyfin-config"]
            deployment = find("Deployment", "jellyfin")
            pod = deployment["spec"]["template"]["spec"]
            for container in pod["containers"] + pod.get("initContainers", []):
                security = pod.get("securityContext", {}) | container.get("securityContext", {})
                assert security["runAsNonRoot"] and security["runAsUser"] > 0 and security["runAsGroup"] > 0
                assert security["runAsUser"] == retained["uid"] and security["runAsGroup"] == retained["gid"]
                assert not security["allowPrivilegeEscalation"]
                assert "ALL" in security["capabilities"]["drop"] and not security["capabilities"].get("add")
                assert "@sha256:" in container["image"]
            assert deployment["spec"]["strategy"]["type"] == "Recreate"
            service = find("Service", "jellyfin")["spec"]
            assert service.get("type", "ClusterIP") == "ClusterIP"
            assert not service.get("externalIPs") and all("nodePort" not in port for port in service["ports"])
            PY
            touch "$out"
          '';
    };
}
