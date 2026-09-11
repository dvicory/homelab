{ config, self, ... }:
{
  perSystem = { pkgs, system, ... }: {
    checks.jellyfin-contracts =
      let
        environment = ../../generated/manifests/prod-home;
        cluster = config.den.clusters.prod-home;
        compute =
          config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
        storage = pkgs.writeText "application-storage-contract.json" (
          builtins.toJSON {
            inherit (compute) instance retainedPaths;
            media = compute.devices.media.path;
            mediaGid = config.den.groups.media.gid;
            mediaInstances = {
              radarr = builtins.attrNames cluster.settings.kubernetes.services.media.radarr;
              sonarr = builtins.attrNames cluster.settings.kubernetes.services.media.sonarr;
            };
          }
        );
        python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
      in
      pkgs.runCommand "jellyfin-contracts"
        {
          nativeBuildInputs = [
            python
            pkgs.git
            pkgs.dash
          ];
        }
        ''
          python - ${environment} ${storage} <<'PY'
          import pathlib
          import json
          import sys
          import yaml
          import subprocess
          import tempfile

          environment = pathlib.Path(sys.argv[1])
          storage = json.loads(pathlib.Path(sys.argv[2]).read_text())
          retained = storage["retainedPaths"]["jellyfin-config"]
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
          assert pv["local"]["path"] == retained["guestPath"]
          terms = pv["nodeAffinity"]["required"]["nodeSelectorTerms"]
          assert all(any(expression["key"] == "kubernetes.io/hostname"
                         and expression["operator"] == "In" and expression["values"] == [storage["instance"]]
                         for expression in term["matchExpressions"]) for term in terms)
          media = next(volume for volume in pod["volumes"] if volume["name"] == "media")
          assert media["hostPath"] == {"path": storage["media"] + "/library", "type": "Directory"}
          # The layout root is root:media 2770, so a read-only consumer still
          # needs the capability: read-only is the write restriction.
          assert storage["mediaGid"] in pod["securityContext"]["supplementalGroups"]
          for container in pod["containers"] + pod.get("initContainers", []):
              security = pod.get("securityContext", {}) | container.get("securityContext", {})
              assert security["runAsNonRoot"] and security["runAsUser"] > 0 and security["runAsGroup"] > 0
              assert security["runAsUser"] == retained["uid"] and security["runAsGroup"] == retained["gid"]
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
          # A rendered local volume must be backed by the selected host, not an
          # independently spelled path that could create an empty replacement.
          declared_paths = {entry["guestPath"] for entry in storage["retainedPaths"].values()}
          for path in environment.glob("*/*.yaml"):
              for resource in yaml.load_all(path.read_text(), Loader=yaml.BaseLoader):
                  if not resource or resource["kind"] != "PersistentVolume":
                      continue
                  spec = resource["spec"]
                  if "local" in spec:
                      assert spec["local"]["path"] in declared_paths, resource["metadata"]["name"]
                      assert spec.get("persistentVolumeReclaimPolicy", "Retain") == "Retain"
          configarr = None
          seed_program = None
          seed_files = None
          # Configarr consumes nested instance maps, not top-level instance keys.
          class ConfigarrLoader(yaml.SafeLoader):
              pass
          ConfigarrLoader.add_constructor("!env", lambda loader, node: loader.construct_scalar(node))
          for path in (environment / "media-configuration").rglob("*.yaml"):
              for resource in yaml.safe_load_all(path.read_text()):
                  if resource and resource["kind"] in {"Job", "CronJob"}:
                      spec = resource["spec"]
                      if resource["kind"] == "CronJob":
                          spec = spec["jobTemplate"]["spec"]
                      pod = spec["template"]["spec"]
                      # API configuration jobs must not gain filesystem access to application data.
                      assert all("persistentVolumeClaim" not in volume and "hostPath" not in volume
                                 for volume in pod.get("volumes", [])), resource["metadata"]["name"]
                      for container in pod["containers"] + pod.get("initContainers", []):
                          assert isinstance(container["image"], str), resource["metadata"]["name"]
                          assert isinstance(container.get("env", []), list), resource["metadata"]["name"]
                      if resource["kind"] == "Job" and resource["metadata"]["name"] == "media-configarr":
                          seed_program = next(c for c in pod["initContainers"] if c["name"] == "seed-policy")["command"][-1]
                  if resource and resource["kind"] == "ConfigMap" and resource["metadata"]["name"] == "media-configarr-inputs":
                      seed_files = resource["data"]
                  if (resource and resource["kind"] == "ConfigMap"
                          and resource["metadata"]["name"] == "media-configuration"):
                      configarr = yaml.load(resource["data"]["config.yml"], Loader=ConfigarrLoader)
                      for kind, names in storage["mediaInstances"].items():
                          assert set(configarr[kind]) == set(names), (kind, configarr[kind])
                          assert all(isinstance(instance, dict) and "base_url" in instance
                                     for instance in configarr[kind].values())
          assert configarr is not None, "Missing Configarr configuration"
          # Exercise the actual seed script with POSIX sh: brace expansion silently
          # creates the wrong directories, and an empty template repo still needs HEAD.
          assert seed_program is not None and seed_files is not None
          with tempfile.TemporaryDirectory() as directory:
              root = pathlib.Path(directory)
              seed = root / "seed"
              seed.mkdir()
              for name, value in seed_files.items():
                  (seed / name).write_text(value)
              script = seed_program.replace("/app/repos", str(root / "repos")).replace("/seed", str(seed))
              subprocess.run(["dash", "-ec", script], check=True)
              for repo in ("trash-guides", "recyclarr-config"):
                  subprocess.run(["git", "-C", str(root / "repos" / repo), "rev-parse", "--verify", "HEAD"],
                                 check=True, stdout=subprocess.DEVNULL)
          PY
          touch "$out"
        '';
  };
}
