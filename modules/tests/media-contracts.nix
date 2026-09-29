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
      policyDirectory = ../../assets/media-policy;
      policySource = builtins.fromJSON (builtins.readFile (policyDirectory + "/source.json"));
      upstreamPolicy = lib.mapAttrs (
        _: file:
        pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/TRaSH-Guides/Guides/${policySource.revision}/${file.upstream}";
          hash = file.sha256;
        }
      ) policySource.files;
      upstreamPolicyPaths = pkgs.writeText "media-policy-upstream-paths.json" (
        builtins.toJSON (lib.mapAttrs (_: path: toString path) upstreamPolicy)
      );
      cluster = config.den.clusters.prod-home;
      compute =
        config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
      computeResources = {
        inherit (compute) instance retainedPaths;
        inherit (config.flake.clusterResources.prod-home) mediaPaths;
      };
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
              inherit computeResources;
              charts = inputs.nixhelm.chartsDerivations.${system};
            }).applications.sabnzbd.helm.releases.sabnzbd.values.controllers.main.initContainers.config;
          removalInit =
            (sabnzbdAspect."k8s-manifests" {
              inherit cluster computeResources;
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
              rejectsProviderCollision =
                !(builtins.tryEval (
                  builtins.deepSeq ((sabnzbdAspect."compute-resources" { cluster = collisionCluster; }).runtimeSecrets
                  ) true
                )).success;
              rejectsInvalidProviderName =
                !(builtins.tryEval (
                  builtins.deepSeq ((sabnzbdAspect."compute-resources" { cluster = invalidNameCluster; })
                    .runtimeSecrets
                  ) true
                )).success;
            };
          fixtureRuntimeSecrets =
            (sabnzbdAspect."compute-resources" { cluster = fixtureCluster; }).runtimeSecrets;
          fixtureSecretKeys = [
            "USENET_FIXTURE_USERNAME"
            "USENET_FIXTURE_PASSWORD"
          ];
        in
        pkgs.writeText "media-provider-contract.json" (
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
          bundle,
          role ? null,
        }:
        {
          inherit
            state
            routeKey
            apiSecretKey
            root
            category
            bundle
            role
            ;
          sharedWritablePaths = [ "/data" ];
        };
      fixtureInstances = {
        radarr = {
          radarr = instance {
            role = "standard";
            state = "radarr-hd";
            routeKey = "radarr";
            apiSecretKey = "RADARR_HD_API_KEY";
            root = "/data/library/movies/hd";
            category = "movies-hd";
            bundle = "web-1080p";
          };
          uhd = instance {
            role = "4k";
            state = "radarr-uhd";
            routeKey = null;
            apiSecretKey = "RADARR_UHD_API_KEY";
            root = "/data/library/movies/uhd";
            category = "movies-uhd";
            bundle = "web-2160p";
          };
        };
        sonarr = {
          sonarr = instance {
            role = "standard";
            state = "sonarr-hd";
            routeKey = "sonarr";
            apiSecretKey = "SONARR_HD_API_KEY";
            root = "/data/library/tv/hd";
            category = "tv-hd";
            bundle = "web-1080p";
          };
          anime = instance {
            role = "4k";
            state = "sonarr-anime";
            routeKey = null;
            apiSecretKey = "SONARR_ANIME_API_KEY";
            root = "/data/library/tv/anime";
            category = "tv-anime";
            bundle = "web-2160p";
          };
        };
      };
      fixtureMutatedInstances = fixtureInstances // {
        radarr = fixtureInstances.radarr // {
          uhd = fixtureInstances.radarr.uhd // {
            root = "/data/library/movies/uhd-remux";
            category = "movies-uhd-remux";
            bundle = "web-1080p";
          };
        };
      };
      fixtureCluster = cluster // {
        settings = lib.recursiveUpdate cluster.settings {
          kubernetes.services.media = fixtureInstances;
        };
      };
      fixtureCompute = computeResources // {
        retainedPaths =
          computeResources.retainedPaths
          // (lib.mapAttrs
            (state: uid: {
              path = "/var/lib/homelab/compute-1/platform/media/${state}";
              guestPath = "/srv/platform/media/${state}";
              inherit uid;
              gid = uid;
              mode = "0700";
              readOnly = false;
            })
            {
              radarr-hd = 752;
              radarr-uhd = 752;
              sonarr-hd = 753;
              sonarr-anime = 753;
            }
          );
      };
      renderApplications =
        targetCluster: targetCompute: kind:
        let
          rendered = config.den.aspects.kubernetes.services.media.arr.provides.${kind}."k8s-manifests" {
            cluster = targetCluster;
            computeResources = targetCompute;
            inherit charts;
          };
        in
        rendered.config.applications;
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
      fixtureSabnzbd =
        (config.den.aspects.kubernetes.services.sabnzbd."k8s-manifests" {
          cluster = fixtureCluster;
          computeResources = fixtureCompute;
          inherit charts;
        }).applications;
      fixtureSabnzbdInit = builtins.elemAt (fixtureSabnzbd.sabnzbd.helm.releases.sabnzbd.values.controllers.main.initContainers.config.command) 2;
      fixtureApplications = projectApplications (
        renderApplications fixtureCluster fixtureCompute "radarr"
        // renderApplications fixtureCluster fixtureCompute "sonarr"
      );
      fixtureMutatedCluster = cluster // {
        settings = lib.recursiveUpdate cluster.settings {
          kubernetes.services.media = fixtureMutatedInstances;
        };
      };
      fixtureMutatedApplications = projectApplications (
        renderApplications fixtureMutatedCluster fixtureCompute "radarr"
        // renderApplications fixtureMutatedCluster fixtureCompute "sonarr"
      );
      mediaManifests =
        targetCluster:
        (config.den.aspects.kubernetes.services.media."k8s-manifests" {
          cluster = targetCluster;
          computeResources = fixtureCompute;
        });
      mediaWith =
        overrides:
        builtins.tryEval (
          builtins.deepSeq (mediaManifests (
            fixtureCluster
            // {
              settings = lib.recursiveUpdate fixtureCluster.settings {
                kubernetes.services.media = overrides;
              };
            }
          )) true
        );
      configurationWith =
        overrides:
        builtins.tryEval (
          builtins.deepSeq ((config.den.aspects.kubernetes.services.media.configuration."k8s-manifests" {
            cluster = fixtureCluster // {
              settings = lib.recursiveUpdate fixtureCluster.settings {
                kubernetes.services.media = overrides;
              };
            };
            computeResources = fixtureCompute;
          }).applications.media-configuration.objects
          ) true
        );
      mediaBase = mediaWith { };
      mediaNoStandard = configurationWith {
        radarr.radarr.role = null;
        sonarr.sonarr.role = null;
      };
      mediaAmbiguousStandard = configurationWith { radarr.uhd.role = "standard"; };
      mediaNoSharing = mediaWith { radarr.uhd.sharedWritablePaths = [ ]; };
      mediaStateCollision = mediaWith { sonarr.anime.state = "radarr-hd"; };
      mediaSecretCollision = mediaWith { sonarr.anime.apiSecretKey = "RADARR_HD_API_KEY"; };
      mediaCategoryCollision = mediaWith { sonarr.anime.category = "movies-hd"; };
      mediaRootCollision = mediaWith { radarr.uhd.root = "/data/library/movies/hd"; };
      mediaNestedRoot = mediaWith { radarr.uhd.root = "/data/library/movies/hd/remux"; };
      sharedLibrary = [
        "/data"
        "/data/library/movies/hd"
      ];
      mediaOneSidedSharing = mediaWith {
        radarr.radarr.sharedWritablePaths = sharedLibrary;
        radarr.uhd.root = "/data/library/movies/hd";
      };
      mediaSharedRoot = mediaWith {
        radarr.radarr.sharedWritablePaths = sharedLibrary;
        radarr.uhd = {
          root = "/data/library/movies/hd";
          sharedWritablePaths = sharedLibrary;
        };
      };
      fixtureRuntimeSecrets =
        let
          resources =
            kind:
            (config.den.aspects.kubernetes.services.media.arr.provides.${kind}."compute-resources" {
              cluster = fixtureCluster;
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
          sabnzbdInit = fixtureSabnzbdInit;
          positive = mediaBase.success;
          seerrRoleAccepted = (configurationWith { }).success;
          noStandardRejected = !mediaNoStandard.success;
          ambiguousStandardRejected = !mediaAmbiguousStandard.success;
          optionalFourKAccepted = (configurationWith { sonarr.anime.role = null; }).success;
          noSharingRejected = !mediaNoSharing.success;
          stateCollisionRejected = !mediaStateCollision.success;
          secretCollisionRejected = !mediaSecretCollision.success;
          categoryCollisionRejected = !mediaCategoryCollision.success;
          rootCollisionRejected = !mediaRootCollision.success;
          nestedRootRejected = !mediaNestedRoot.success;
          oneSidedSharingRejected = !mediaOneSidedSharing.success;
          explicitRootSharingAccepted = mediaSharedRoot.success;
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
            python - ${environment} ${storage} ${providerContract} ${fixture} ${policyDirectory} ${upstreamPolicyPaths} <<'PY'
            import base64
            import hashlib
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
            fixture = json.loads(pathlib.Path(sys.argv[4]).read_text())
            policy_dir = pathlib.Path(sys.argv[5])
            source = json.loads((policy_dir / "source.json").read_text())
            upstream = json.loads(pathlib.Path(sys.argv[6]).read_text())
            assert set(source) == {"repository", "revision", "files", "localFiles"}
            assert source["repository"] == "https://github.com/TRaSH-Guides/Guides"
            assert {name: file["upstream"] for name, file in source["files"].items()
                    if "-cf-" not in name} == {
                "radarr-web-1080p.json": "docs/json/radarr/quality-profiles/web-1080p.json",
                "radarr-web-2160p.json": "docs/json/radarr/quality-profiles/web-2160p.json",
                "sonarr-web-1080p.json": "docs/json/sonarr/quality-profiles/web-1080p.json",
                "sonarr-web-2160p.json": "docs/json/sonarr/quality-profiles/web-2160p.json",
                "radarr-movie.json": "docs/json/radarr/quality-size/movie.json",
                "sonarr-series.json": "docs/json/sonarr/quality-size/series.json",
                "sonarr-anime.json": "docs/json/sonarr/quality-size/anime.json",
            }
            assert set(upstream) == set(source["files"])
            for name, file in source["files"].items():
                assert set(file) == {"upstream", "sha256"}
                actual = pathlib.Path(upstream[name]).read_bytes()
                assert file["sha256"] == "sha256-" + base64.b64encode(hashlib.sha256(actual).digest()).decode()
                assert (policy_dir / name).is_file(), name
                assert json.loads((policy_dir / name).read_bytes()) == json.loads(actual), name
            for kind in ("radarr", "sonarr"):
                cf_ids = {
                    json.loads(pathlib.Path(upstream[name]).read_text())["trash_id"]
                    for name in upstream if name.startswith(kind + "-cf-")
                }
                for bundle in ("web-1080p", "web-2160p"):
                    profile = json.loads(pathlib.Path(upstream[f"{kind}-{bundle}.json"]).read_text())
                    assert set(profile["formatItems"].values()) <= cf_ids
            assert set(source["localFiles"]) == {"conflicts.json"}
            local = source["localFiles"]["conflicts.json"]
            assert set(local) == {"sha256"}
            assert local["sha256"] == "sha256-" + base64.b64encode(
                hashlib.sha256((policy_dir / "conflicts.json").read_bytes()).digest()
            ).decode()

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
            assert set(fixture_apps) == expected_services
            assert fixture["positive"]
            assert fixture["seerrRoleAccepted"]
            assert fixture["noStandardRejected"]
            assert fixture["ambiguousStandardRejected"]
            assert fixture["optionalFourKAccepted"]
            assert fixture["noSharingRejected"]
            assert fixture["stateCollisionRejected"]
            assert fixture["secretCollisionRejected"]
            assert fixture["categoryCollisionRejected"]
            assert fixture["rootCollisionRejected"]
            assert fixture["nestedRootRejected"]
            assert fixture["oneSidedSharingRejected"]
            assert fixture["explicitRootSharingAccepted"]
            assert storage["mediaInstances"] == {"radarr": ["radarr"], "sonarr": ["sonarr"]}

            def validate_instance_group(kind, instances):
                expected_names = {"radarr", "uhd"} if kind == "radarr" else {"sonarr", "anime"}
                assert set(instances) == expected_names
                for field in ("state", "apiSecretKey", "root", "category", "bundle"):
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
            jellyfin_security = find("Deployment", "jellyfin")["spec"]["template"]["spec"]["securityContext"]
            assert media_gid in jellyfin_security["supplementalGroups"]

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

            with tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                config_path = root / "sabnzbd.ini"
                data_path = root / "data"
                data_path.mkdir()
                run_init(fixture["sabnzbdInit"], config_path, data_path, {
                    "SABNZBD_API_KEY": "api-key-fixture",
                    "SABNZBD_USERNAME": "admin-fixture",
                    "SABNZBD_PASSWORD": "admin-password-fixture",
                })
                categories = ConfigObj(str(config_path), encoding="utf-8")["categories"]
                assert set(categories) == {
                    instance["category"]
                    for instances in fixture_instances.values()
                    for instance in instances.values()
                }

            runtime_values = {
                "SABNZBD_API_KEY": "api-key-fixture",
                "SABNZBD_USERNAME": "admin-fixture",
                "SABNZBD_PASSWORD": "admin-password-fixture",
                "USENET_FIXTURE_USERNAME": "provider-user-fixture",
                "USENET_FIXTURE_PASSWORD": "provider-password-fixture",
            }
            staged = {}
            for entry in provider["runtimeSecrets"].values():
                staged.setdefault((entry["namespace"], entry["name"]), {})[entry["key"]] = runtime_values[entry["key"]]
            runtime_values = {
                name: staged[("media", entry["valueFrom"]["secretKeyRef"]["name"])][entry["valueFrom"]["secretKeyRef"]["key"]]
                for name, entry in provider["env"].items()
            }
            with tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                config_path = root / "sabnzbd.ini"
                data_path = root / "data"
                data_path.mkdir()
                initial = ConfigObj(encoding="utf-8")
                initial["misc"] = {}
                initial["misc"].update({"custom_misc": "keep-misc", "host": "old-host"})
                initial["categories"] = {}
                initial["categories"]["movies"] = {
                    "name": "movies",
                    "order": "0",
                    "priority": "9",
                    "pp": "0",
                    "script": "Custom",
                    "dir": "wrong",
                    "newzbin": "",
                    "custom_category": "keep-category",
                }
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
                category = first["categories"]["movies"]
                assert category["dir"] == "movies"
                assert category["pp"] == "3"
                assert category["custom_category"] == "keep-category"
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
                assert "fixture" not in removed["servers"]
                assert removed["servers"]["unmanaged"] == first["servers"]["unmanaged"]

            configarr = None
            configarr_env = None
            seed_files = None
            seed_program = None
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
                        state_mounts = [mount for container in pod["containers"] for mount in container.get("volumeMounts", [])
                                        if mount["name"] == "seerr-state"]
                        state_volumes = [volume for volume in pod.get("volumes", []) if "persistentVolumeClaim" in volume]
                        if resource["metadata"]["name"] == "media-config-seerr":
                            assert state_mounts == [{"name": "seerr-state", "mountPath": "/seerr-state", "readOnly": True}]
                            assert state_volumes == [{"name": "seerr-state", "persistentVolumeClaim": {"claimName": "media-seerr"}}]
                        else:
                            assert not state_mounts and not state_volumes
                        assert all("hostPath" not in volume for volume in pod.get("volumes", []))
                        for container in pod["containers"] + pod.get("initContainers", []):
                            assert isinstance(container["image"], str), resource["metadata"]["name"]
                            assert isinstance(container.get("env", []), list), resource["metadata"]["name"]
                        if resource["kind"] == "Job" and resource["metadata"]["name"] == "media-configarr":
                            seed_program = next(c for c in pod["initContainers"] if c["name"] == "seed-policy")["command"][-1]
                            configarr_container = next(c for c in pod["containers"] if c["name"] == "configarr")
                            configarr_env = {
                                entry["name"]: entry.get("value")
                                for entry in configarr_container["env"]
                            }
                    if resource and resource["kind"] == "ConfigMap" and resource["metadata"]["name"] == "media-configarr-inputs":
                        seed_files = resource["data"]
                    if (resource and resource["kind"] == "ConfigMap"
                            and resource["metadata"]["name"] == "media-configuration"):
                        configarr = yaml.load(resource["data"]["config.yml"], Loader=ConfigarrLoader)
                        assert resource["data"]["trash-guide-revision"] == source["revision"]
                        for kind, names in storage["mediaInstances"].items():
                            assert set(configarr[kind]) == set(names), (kind, configarr[kind])
                            assert all(isinstance(instance, dict) and "base_url" in instance
                                       for instance in configarr[kind].values())
            periodic = {
                resource["metadata"]["name"]: resource["spec"]
                for resource in resources
                if resource["kind"] == "CronJob" and resource["metadata"]["namespace"] == "media"
            }
            assert set(periodic) == {"media-configarr", "media-config-seerr"}
            for name, minute in (("media-configarr", 7), ("media-config-seerr", 37)):
                schedule = periodic[name]
                assert schedule["schedule"] == f"{minute} */6 * * *"
                assert schedule["suspend"] == "false" and schedule["concurrencyPolicy"] == "Forbid"
                assert schedule["jobTemplate"]["spec"] == find("Job", name)["spec"]
            assert configarr is not None, "Missing media configuration"
            assert configarr_env["LOG_LEVEL"] == "warn"
            assert configarr_env["STOP_ON_ERROR"] == "true"
            assert configarr_env["CONFIGARR_ENFORCE_CONFIG_VALIDATION"] == "true"
            assert configarr_env["CONFIGARR_ENFORCE_EXTERNAL_VALIDATION"] == "true"
            assert configarr["prowlarr"]["main"]["applications"]["delete_unmanaged"]["enabled"] is False
            for kind in ("radarr", "sonarr"):
                for instance in configarr[kind].values():
                    assert len(instance["root_folders"]) == 1
                    assert instance["custom_formats"][0]["assign_scores_to"][0]["use_default_score"]
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
                trash_repo = root / "repos" / "trash-guides"
                assert (trash_repo / "TRASH-GUIDES-REVISION").read_text().strip() == source["revision"]
                for name, metadata in source["files"].items():
                    if "-cf-" in name:
                        assert (trash_repo / metadata["upstream"]).read_bytes() == pathlib.Path(upstream[name]).read_bytes()
                synthetic_head = subprocess.check_output(
                    ["git", "-C", str(trash_repo), "rev-parse", "HEAD"], text=True
                ).strip()
                assert synthetic_head != source["revision"]
            PY
            touch "$out"
          '';
      checks.seerr-credential-boundary = pkgs.runCommand "seerr-credential-boundary" { } ''
        ${pkgs.nodejs_22}/bin/node ${./seerr-credential-boundary.mjs} ${../den/aspects/kubernetes/services/seerr.mjs}
        touch "$out"
      '';
    };
}
