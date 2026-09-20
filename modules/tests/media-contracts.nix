{
  config,
  inputs,
  lib,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      environment = ../../generated/manifests/prod-home;
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      fixtureProvider = {
        host = "news.example.test";
        port = 563;
        ssl = true;
        connections = 8;
        priority = 0;
      };
      fixtureCluster = cluster // {
        settings = lib.recursiveUpdate cluster.settings {
          kubernetes.services.media.sabnzbd.providers.fixture = fixtureProvider;
        };
      };
      sabnzbdAspect = config.den.aspects.kubernetes.services.sabnzbd;
      fixtureInit =
        (sabnzbdAspect."k8s-manifests" {
          cluster = fixtureCluster;
          inherit compute;
          charts = inputs.nixhelm.chartsDerivations.${system};
        }).applications.sabnzbd.helm.releases.sabnzbd.values.controllers.main.initContainers.config;
      removalInit =
        (sabnzbdAspect."k8s-manifests" {
          inherit cluster compute;
          charts = inputs.nixhelm.chartsDerivations.${system};
        }).applications.sabnzbd.helm.releases.sabnzbd.values.controllers.main.initContainers.config;
      providerChecks =
        let
          collisionCluster = cluster // {
            settings = lib.recursiveUpdate cluster.settings {
              kubernetes.services.media.sabnzbd.providers = {
                "a-b" = fixtureProvider;
                "a_b" = fixtureProvider;
              };
            };
          };
          invalidNameCluster = cluster // {
            settings = lib.recursiveUpdate cluster.settings {
              kubernetes.services.media.sabnzbd.providers = {
                "bad name" = fixtureProvider;
              };
            };
          };
        in
        {
          rejectsProviderCollision = !(
            builtins.tryEval (
              builtins.deepSeq (
                (sabnzbdAspect."compute-resources" { cluster = collisionCluster; }).runtimeSecrets
              ) true
            )
          ).success;
          rejectsInvalidProviderName = !(
            builtins.tryEval (
              builtins.deepSeq (
                (sabnzbdAspect."compute-resources" { cluster = invalidNameCluster; }).runtimeSecrets
              ) true
            )
          ).success;
        };
      fixtureRuntimeSecrets =
        (sabnzbdAspect."compute-resources" { cluster = fixtureCluster; }).runtimeSecrets;
      fixtureSecretKeys = [
        "USENET_FIXTURE_USERNAME"
        "USENET_FIXTURE_PASSWORD"
      ];
      providerContract = pkgs.writeText "media-provider-contract.json" (
        builtins.toJSON {
          script = builtins.elemAt fixtureInit.command 2;
          removalScript = builtins.elemAt removalInit.command 2;
          env = fixtureInit.env;
          runtimeSecrets = fixtureRuntimeSecrets;
          secretName = cluster.settings.kubernetes.services.media.configurationSecret;
          secretKeys = fixtureSecretKeys;
          providerConfig = fixtureProvider;
          inherit (providerChecks) rejectsProviderCollision rejectsInvalidProviderName;
        }
      );
      storage = pkgs.writeText "media-storage-contract.json" (
        builtins.toJSON {
          inherit (compute) instance retainedPaths;
          media = "${compute.devices.media.path}/data";
          mediaGid = config.den.groups.media.gid;
          mediaInstances = {
            radarr = builtins.attrNames cluster.settings.kubernetes.services.media.radarr;
            sonarr = builtins.attrNames cluster.settings.kubernetes.services.media.sonarr;
          };
        }
      );
      python = pkgs.python3.withPackages (ps: [
        ps.configobj
        ps.pyyaml
      ]);
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
            python - ${environment} ${storage} ${providerContract} <<'PY'
            import ast
            import json
            import os
            import pathlib
            import subprocess
            import sys
            import tempfile
            from configobj import ConfigObj
            import yaml

            environment = pathlib.Path(sys.argv[1])
            storage = json.loads(pathlib.Path(sys.argv[2]).read_text())
            provider = json.loads(pathlib.Path(sys.argv[3]).read_text())
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
            sabnzbd_identity = storage["retainedPaths"]["sabnzbd"]

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

            sabnzbd_pod = find("Deployment", "sabnzbd")["spec"]["template"]["spec"]
            sabnzbd_env = {
                item["name"]: item["value"]
                for item in sabnzbd_pod["containers"][0]["env"]
            }
            assert sabnzbd_identity["uid"] == sabnzbd_identity["gid"] == 757
            assert sabnzbd_env["PUID"] == sabnzbd_env["PGID"] == "757"
            sabnzbd_init_security = sabnzbd_pod["initContainers"][0]["securityContext"]
            assert sabnzbd_init_security["runAsUser"] == 757
            assert sabnzbd_init_security["runAsGroup"] == 757
            assert media_gid in jellyfin_pod["securityContext"]["supplementalGroups"]

            script = provider["script"]
            ast.parse(script)
            ast.parse(provider["removalScript"])
            assert set(provider["providerConfig"]) == {
                "host", "port", "ssl", "connections", "priority"
            }
            assert provider["rejectsProviderCollision"]
            assert provider["rejectsInvalidProviderName"]
            for field in (
                "'host'", "'port'", "'ssl'", "'connections'", "'priority'",
                "'username'", "'password'", "'enable': '1'"
            ):
                assert field in script, field
            assert "news.example.test" in script
            assert "USENET_" in script and "_USERNAME" in script and "_PASSWORD" in script
            assert "env_name = name.replace('-', '_').replace('.', '_').upper()" in script
            assert "config.setdefault('servers', {})" in script
            assert "usernameSecretKey" not in script
            assert "passwordSecretKey" not in script
            assert all(value not in script for value in (
                "api-key-fixture", "admin-fixture", "admin-password-fixture",
                "provider-user-fixture", "provider-password-fixture",
            ))
            for key in provider["secretKeys"]:
                assert provider["env"][key] == {
                    "valueFrom": {
                        "secretKeyRef": {"name": provider["secretName"], "key": key}
                    }
                }, key
                source = "media--" + provider["secretName"] + "--" + key
                assert provider["runtimeSecrets"][source] == {
                    "namespace": "media", "name": provider["secretName"],
                    "key": key, "type": "Opaque",
                }, source
            def run_init(init_script, config_path, data_path, values):
                translated = init_script.replace(
                    "path = '/config/sabnzbd.ini'",
                    "path = " + repr(str(config_path)),
                ).replace("/data", str(data_path))
                original = os.environ.copy()
                os.environ.update(values)
                try:
                    exec(compile(translated, "<sabnzbd-init>", "exec"), {"__name__": "__main__"})
                finally:
                    os.environ.clear()
                    os.environ.update(original)

            runtime_values = {
                "SABNZBD_API_KEY": "api-key-fixture",
                "SABNZBD_USERNAME": "admin-fixture",
                "SABNZBD_PASSWORD": "admin-password-fixture",
                "USENET_FIXTURE_USERNAME": "provider-user-fixture",
                "USENET_FIXTURE_PASSWORD": "provider-password-fixture",
            }
            with tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                config_path = root / "sabnzbd.ini"
                data_path = root / "data"
                data_path.mkdir()
                initial = ConfigObj(encoding="utf-8")
                initial["misc"] = {}
                initial["misc"].update({"custom_misc": "keep-misc", "host": "old-host"})
                initial["servers"] = {}
                initial["servers"]["fixture"] = {
                    "displayname": "operator-label",
                    "host": "old.example.test",
                    "port": "119",
                    "ssl": "0",
                    "connections": "1",
                    "priority": "9",
                    "username": "old-user",
                    "password": "old-password",
                    "enable": "0",
                    "notes": "managed-by: homelab",
                    "custom_server": "keep-server",
                }
                initial["servers"]["unmanaged"] = {
                    "host": "untouched.example.test",
                    "enable": "1",
                    "custom_server": "keep-unmanaged",
                }
                initial.filename = str(config_path)
                initial.write()

                run_init(script, config_path, data_path, runtime_values)
                first = ConfigObj(str(config_path), encoding="utf-8")
                managed = first["servers"]["fixture"]
                assert first["misc"]["custom_misc"] == "keep-misc"
                assert managed["displayname"] == "operator-label"
                assert managed["host"] == "news.example.test"
                assert managed["port"] == "563"
                assert managed["ssl"] == "1"
                assert managed["connections"] == "8"
                assert managed["priority"] == "0"
                assert managed["username"] == "provider-user-fixture"
                assert managed["password"] == "provider-password-fixture"
                assert managed["enable"] == "1"
                assert managed["custom_server"] == "keep-server"
                assert first["servers"]["unmanaged"]["custom_server"] == "keep-unmanaged"
                first_bytes = config_path.read_bytes()

                run_init(script, config_path, data_path, runtime_values)
                assert config_path.read_bytes() == first_bytes

                run_init(provider["removalScript"], config_path, data_path, runtime_values)
                removed = ConfigObj(str(config_path), encoding="utf-8")
                assert removed["servers"]["fixture"] == first["servers"]["fixture"]
                assert removed["servers"]["unmanaged"] == first["servers"]["unmanaged"]

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
