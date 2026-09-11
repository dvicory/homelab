{ config, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      environment = ../../generated/manifests/prod-home;
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      storage = pkgs.writeText "media-storage-contract.json" (
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
    {
      checks.media-contracts =
        pkgs.runCommand "media-contracts"
          {
            nativeBuildInputs = [
              python
              pkgs.git
              pkgs.dash
            ];
          }
          ''
            python - ${environment} ${storage} <<'PY'
            import json
            import pathlib
            import subprocess
            import sys
            import tempfile
            import yaml

            environment = pathlib.Path(sys.argv[1])
            storage = json.loads(pathlib.Path(sys.argv[2]).read_text())
            resources = []
            for path in environment.rglob("*.yaml"):
                resources.extend(
                    resource for resource in yaml.load_all(path.read_text(), Loader=yaml.BaseLoader) if resource
                )

            def find(kind, name):
                return next(
                    resource
                    for resource in resources
                    if resource["kind"] == kind and resource["metadata"]["name"] == name
                )

            local_pvs = {
                resource["metadata"]["name"]: resource
                for resource in resources
                if resource.get("kind") == "PersistentVolume"
                and "local" in resource.get("spec", {})
            }
            media_gid = str(storage["mediaGid"])
            media_root = pathlib.PurePosixPath(storage["media"])

            def under_media(path):
                candidate = pathlib.PurePosixPath(path)
                return candidate == media_root or media_root in candidate.parents

            # Private retained state is distinct from the host-owned media namespace.
            for resource in local_pvs.values():
                assert not under_media(resource["spec"]["local"]["path"]), resource["metadata"]["name"]
            for resource in resources:
                if resource.get("kind") != "PersistentVolumeClaim":
                    continue
                volume_name = resource.get("spec", {}).get("volumeName")
                if volume_name in local_pvs:
                    assert not under_media(
                        local_pvs[volume_name]["spec"]["local"]["path"]
                    ), resource["metadata"]["name"]

            jellyfin = find("Deployment", "jellyfin")
            jellyfin_pod = jellyfin["spec"]["template"]["spec"]
            jellyfin_media = next(
                volume for volume in jellyfin_pod["volumes"] if volume["name"] == "media"
            )
            assert jellyfin_media["hostPath"] == {
                "path": storage["media"] + "/library",
                "type": "Directory",
            }
            for container in jellyfin_pod["containers"] + jellyfin_pod.get("initContainers", []):
                mounts = [mount for mount in container["volumeMounts"] if mount["name"] == "media"]
                assert len(mounts) == 1
                mount = mounts[0]
                assert (
                    mount["mountPath"] == "/media"
                    and mount["readOnly"]
                    and mount["mountPropagation"] == "HostToContainer"
                )

            # Acquisition applications write the host-owned media namespace at /data.
            for name in ("radarr", "sonarr", "sabnzbd"):
                deployment = find("Deployment", name)
                pod = deployment["spec"]["template"]["spec"]
                data = next(volume for volume in pod["volumes"] if volume["name"] == "data")
                assert data["hostPath"] == {
                    "path": storage["media"],
                    "type": "Directory",
                }, name
                assert media_gid in pod["securityContext"]["supplementalGroups"], name
                for container in pod["containers"] + pod.get("initContainers", []):
                    mounts = [mount for mount in container["volumeMounts"] if mount["name"] == "data"]
                    assert len(mounts) == 1
                    mount = mounts[0]
                    assert mount["mountPath"] == "/data" and not mount.get("readOnly", False), name

            assert media_gid in jellyfin_pod["securityContext"]["supplementalGroups"]

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
