{ config, inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      environment = ../../generated/manifests/prod-home;
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      providerContract =
        let
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
        in pkgs.writeText "media-provider-contract.json" (
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
      charts = inputs.nixhelm.chartsDerivations.${system};
      instance =
        {
          state,
          routeKey,
          apiSecretKey,
          root,
          category,
          profile,
        }:
        {
          inherit
            state
            routeKey
            apiSecretKey
            root
            category
            profile
            ;
          sharedWritablePaths = [ "/data" ];
        };
      fixtureInstances = {
        radarr = {
          radarr = instance {
            state = "radarr-hd";
            routeKey = "radarr";
            apiSecretKey = "RADARR_HD_API_KEY";
            root = "/data/library/movies/hd";
            category = "movies-hd";
            profile = "WEB-1080p";
          };
          uhd = instance {
            state = "radarr-uhd";
            routeKey = null;
            apiSecretKey = "RADARR_UHD_API_KEY";
            root = "/data/library/movies/uhd";
            category = "movies-uhd";
            profile = "WEB-2160p";
          };
        };
        sonarr = {
          sonarr = instance {
            state = "sonarr-hd";
            routeKey = "sonarr";
            apiSecretKey = "SONARR_HD_API_KEY";
            root = "/data/library/tv/hd";
            category = "tv-hd";
            profile = "WEB-1080p";
          };
          anime = instance {
            state = "sonarr-anime";
            routeKey = null;
            apiSecretKey = "SONARR_ANIME_API_KEY";
            root = "/data/library/tv/anime";
            category = "tv-anime";
            profile = "WEB-2160p";
          };
        };
      };
      fixtureMutatedInstances =
        fixtureInstances
        // {
          radarr = fixtureInstances.radarr // {
            uhd = fixtureInstances.radarr.uhd // {
              root = "/data/library/movies/uhd-remux";
              category = "movies-uhd-remux";
              profile = "WEB-1080p";
            };
          };
        };
      fixtureCluster =
        cluster
        // {
          settings = lib.recursiveUpdate cluster.settings {
            kubernetes.services.media = fixtureInstances;
          };
        };
      fixtureCompute =
        compute
        // {
          retainedPaths = compute.retainedPaths // (
            lib.mapAttrs (
              state: uid: {
                path = "/var/lib/homelab/compute-1/platform/media/${state}";
                guestPath = "/srv/platform/media/${state}";
                inherit uid;
                gid = uid;
                mode = "0700";
                readOnly = false;
              }
            ) {
              radarr-hd = 752;
              radarr-uhd = 752;
              sonarr-hd = 753;
              sonarr-anime = 753;
            }
          );
        };
      renderApplications =
        targetCluster:
        targetCompute:
        kind:
        let
          rendered = config.den.aspects.kubernetes.services.${kind}."k8s-manifests" {
            cluster = targetCluster;
            compute = targetCompute;
            inherit charts;
          };
        in
        rendered.applications;
      projectApplications =
        applications:
        lib.mapAttrs (
          name: application:
          {
            namespace = application.namespace;
            objects = application.objects or [ ];
          }
          // lib.optionalAttrs (application ? helm) {
            values = application.helm.releases.${name}.values;
          }
        ) applications;
      fixtureApplications =
        projectApplications (
          renderApplications fixtureCluster fixtureCompute "radarr"
          // renderApplications fixtureCluster fixtureCompute "sonarr"
        );
      fixtureMutatedCluster =
        cluster
        // {
          settings = lib.recursiveUpdate cluster.settings {
            kubernetes.services.media = fixtureMutatedInstances;
          };
        };
      fixtureMutatedApplications =
        projectApplications (
          renderApplications fixtureMutatedCluster fixtureCompute "radarr"
          // renderApplications fixtureMutatedCluster fixtureCompute "sonarr"
        );
      mediaManifests =
        targetCluster:
        (config.den.aspects.kubernetes.services.media."k8s-manifests" {
          cluster = targetCluster;
        });
      mediaBase = builtins.tryEval (mediaManifests fixtureCluster);
      mediaNoSharing = builtins.tryEval (
        mediaManifests (
          fixtureCluster
          // {
            settings = lib.recursiveUpdate fixtureCluster.settings {
              kubernetes.services.media.radarr.uhd.sharedWritablePaths = [ ];
            };
          }
        )
      );
      mediaStateCollision = builtins.tryEval (
        mediaManifests (
          fixtureCluster
          // {
            settings = lib.recursiveUpdate fixtureCluster.settings {
              kubernetes.services.media.sonarr.anime.state = "radarr-hd";
            };
          }
        )
      );
      fixtureRuntimeSecrets =
        let
          resources =
            kind:
            (config.den.aspects.kubernetes.services.${kind}."compute-resources" {
              cluster = fixtureCluster;
              config = config;
            }).runtimeSecrets;
        in
        resources "radarr" // resources "sonarr";
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
      fixture = pkgs.writeText "media-instance-fixtures.json" (
        builtins.toJSON {
          instances = fixtureInstances;
          mutatedInstances = fixtureMutatedInstances;
          applications = fixtureApplications;
          mutatedApplications = fixtureMutatedApplications;
          runtimeSecrets = fixtureRuntimeSecrets;
          positive = mediaBase.success;
          noSharingRejected = !mediaNoSharing.success;
          stateCollisionRejected = !mediaStateCollision.success;
        }
      );
      python = pkgs.python3.withPackages (ps: [ ps.configobj ps.pyyaml ]);
    in
    {
      checks.media-contracts =
        pkgs.runCommand "media-contracts"
          {
            nativeBuildInputs = [
              python
              pkgs.git
              pkgs.dash
              pkgs.nodejs
            ];
          }
          ''
            python - ${environment} ${storage} ${./prowlarr-reconciliation.mjs} ${providerContract} ${fixture} <<'PY'
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
            prowlarr_fixture = pathlib.Path(sys.argv[3])
            provider = json.loads(pathlib.Path(sys.argv[4]).read_text())
            fixture = json.loads(pathlib.Path(sys.argv[5]).read_text())
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

            fixture_instances = fixture["instances"]
            fixture_apps = fixture["applications"]
            expected_services = {"radarr", "radarr-uhd", "sonarr", "sonarr-anime"}
            assert set(fixture_apps) == expected_services | {"radarr-storage", "sonarr-storage"}
            assert fixture["positive"]
            assert fixture["noSharingRejected"]
            assert fixture["stateCollisionRejected"]
            assert storage["mediaInstances"] == {"radarr": ["radarr"], "sonarr": ["sonarr"]}

            def validate_instance_group(kind, instances):
                expected_names = {"radarr", "uhd"} if kind == "radarr" else {"sonarr", "anime"}
                assert set(instances) == expected_names
                for field in ("state", "apiSecretKey", "root", "category", "profile"):
                    values = [instance[field] for instance in instances.values()]
                    assert len(values) == len(set(values)), (kind, field)
                assert all(instance["sharedWritablePaths"] == ["/data"] for instance in instances.values())

            validate_instance_group("radarr", fixture_instances["radarr"])
            validate_instance_group("sonarr", fixture_instances["sonarr"])
            assert len({instance["state"] for instances in fixture_instances.values()
                        for instance in instances.values()}) == 4
            assert len({instance["apiSecretKey"] for instances in fixture_instances.values()
                        for instance in instances.values()}) == 4

            for name in expected_services:
                kind = "radarr" if name.startswith("radarr") else "sonarr"
                instance_name = kind if name == kind else name.removeprefix(kind + "-")
                cfg = fixture_instances[kind][instance_name]
                values = fixture_apps[name]["values"]
                assert values["fullnameOverride"] == name
                assert values["persistence"]["config"]["existingClaim"] == "media-" + cfg["state"]
                assert values["persistence"]["data"] == {
                    "type": "hostPath",
                    "hostPath": storage["media"],
                    "hostPathType": "Directory",
                    "globalMounts": [{"path": "/data"}],
                }
                container = values["controllers"]["main"]["containers"]["main"]
                assert set(container["image"]) == {"repository", "tag", "digest"}
                secret_ref = container["env"][f"{kind.upper()}__AUTH__APIKEY"]
                assert secret_ref["valueFrom"]["secretKeyRef"]["key"] == cfg["apiSecretKey"]

            runtime_keys = {
                value["key"]
                for value in fixture["runtimeSecrets"].values()
            }
            assert runtime_keys == {
                instance["apiSecretKey"]
                for instances in fixture_instances.values()
                for instance in instances.values()
            }
            base_apps = fixture["applications"]
            mutated_apps = fixture["mutatedApplications"]
            for name in expected_services - {"radarr-uhd"}:
                assert base_apps[name] == mutated_apps[name], name
            assert (
                fixture["instances"]["radarr"]["uhd"]
                != fixture["mutatedInstances"]["radarr"]["uhd"]
            )

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
            assert int(sabnzbd_init_security["runAsUser"]) == sabnzbd_identity["uid"]
            assert int(sabnzbd_init_security["runAsGroup"]) == sabnzbd_identity["gid"]
            assert media_gid in jellyfin_pod["securityContext"]["supplementalGroups"]

            script = provider["script"]
            assert provider["rejectsProviderCollision"]
            assert provider["rejectsInvalidProviderName"]
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
            prowlarr_script = None
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
                        prowlarr_script = resource["data"]["prowlarr.mjs"]
                        configarr = yaml.load(resource["data"]["config.yml"], Loader=ConfigarrLoader)
                        for kind, names in storage["mediaInstances"].items():
                            assert set(configarr[kind]) == set(names), (kind, configarr[kind])
                            assert all(isinstance(instance, dict) and "base_url" in instance
                                       for instance in configarr[kind].values())
            assert configarr is not None and prowlarr_script is not None, "Missing media configuration"
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
            with tempfile.TemporaryDirectory() as directory:
                rendered_script = pathlib.Path(directory) / "prowlarr.mjs"
                rendered_script.write_text(prowlarr_script)
                subprocess.run(["node", str(prowlarr_fixture), str(rendered_script)], check=True)
            PY
            touch "$out"
          '';
    };
}
