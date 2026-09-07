{ self, ... }:
{
  perSystem = { pkgs, system, ... }: {
    checks.jellyfin-contracts =
      let
        environment = self.nixidyEnvs.${system}.prod-home.config.build.environmentPackage;
        python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      in
      pkgs.runCommand "jellyfin-contracts" { nativeBuildInputs = [ python ]; } ''
        python - ${environment} <<'PY'
        import pathlib
        import sys
        import yaml

        environment = pathlib.Path(sys.argv[1])
        resources = []
        for application in ("jellyfin-retained", "jellyfin"):
            for path in (environment / application).rglob("*.yaml"):
                resources.extend(resource for resource in yaml.safe_load_all(path.read_text()) if resource)

        def find(kind, name):
            return next(resource for resource in resources
                        if resource["kind"] == kind and resource["metadata"]["name"] == name)

        pv = find("PersistentVolume", "jellyfin-config")["spec"]
        pvc = find("PersistentVolumeClaim", "jellyfin-config")["spec"]
        deployment = find("Deployment", "jellyfin")["spec"]
        pod = deployment["template"]["spec"]
        assert pv["persistentVolumeReclaimPolicy"] == "Retain"
        assert pvc["volumeName"] == "jellyfin-config" and pvc["storageClassName"] == pv["storageClassName"]
        assert pv["local"]["path"] == "/srv/jellyfin/config"
        terms = pv["nodeAffinity"]["required"]["nodeSelectorTerms"]
        assert all(any(expression["key"] == "kubernetes.io/hostname"
                       and expression["operator"] == "In" and expression["values"] == ["compute-1"]
                       for expression in term["matchExpressions"]) for term in terms)
        media = next(volume for volume in pod["volumes"] if volume["name"] == "media")
        assert media["hostPath"] == {"path": "/srv/media", "type": "Directory"}
        for container in pod["containers"] + pod.get("initContainers", []):
            security = pod.get("securityContext", {}) | container.get("securityContext", {})
            assert security["runAsNonRoot"] and security["runAsUser"] > 0 and security["runAsGroup"] > 0
            assert not security["allowPrivilegeEscalation"]
            assert "ALL" in security["capabilities"]["drop"] and not security["capabilities"].get("add")
            mount = next(mount for mount in container["volumeMounts"] if mount["name"] == "media")
            assert mount["readOnly"] and mount["mountPropagation"] == "HostToContainer"
            assert "@sha256:" in container["image"]
        assert deployment["strategy"]["type"] == "Recreate"
        service = find("Service", "jellyfin")["spec"]
        assert service.get("type", "ClusterIP") == "ClusterIP"
        assert not service.get("externalIPs") and all("nodePort" not in port for port in service["ports"])
        assert not any(resource["kind"] == "Secret" and (resource.get("data") or resource.get("stringData"))
                       for resource in resources)
        PY
        touch "$out"
      '';
  };
}
