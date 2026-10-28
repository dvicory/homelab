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
          qualityProfiles ? [ "hd-preferred" "web-1080p" "remux-web-1080p" ],
          defaultQualityProfile ? "hd-preferred",
          role ? null,
        }:
        {
          inherit
            state
            routeKey
            apiSecretKey
            root
            category
            qualityProfiles
            defaultQualityProfile
            role
            ;
          sharedWritablePaths = [ "/data" ];
        };
      fixtureDefinitions = {
        radarr = {
          radarr = instance {
            role = "standard";
            state = "radarr-hd";
            routeKey = "radarr";
            apiSecretKey = "RADARR_HD_API_KEY";
            root = "/data/library/movies/hd";
            category = "movies-hd";
          };
          remux = instance {
            state = "radarr-remux";
            routeKey = null;
            apiSecretKey = "RADARR_REMUX_API_KEY";
            root = "/data/library/movies/remux";
            category = "movies-remux";
            qualityProfiles = [ "remux-web-1080p" ];
            defaultQualityProfile = "remux-web-1080p";
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
          };
          anime = instance {
            state = "sonarr-anime";
            routeKey = null;
            apiSecretKey = "SONARR_ANIME_API_KEY";
            root = "/data/library/tv/anime";
            category = "tv-anime";
            qualityProfiles = [ "web-1080p" ];
            defaultQualityProfile = "web-1080p";
          };
        };
      };
      fixtureClusterWith =
        overrides:
        let
          media = lib.recursiveUpdate (cluster.settings.kubernetes.services.media // fixtureDefinitions) overrides;
          evaluated =
            (lib.evalModules {
              modules = [
                {
                  options = lib.genAttrs [ "radarr" "sonarr" ] (
                    kind: config.den.aspects.kubernetes.services.media.settings.${kind}
                  );
                  config = { inherit (media) radarr sonarr; };
                }
              ];
            }).config;
        in
        cluster // {
          settings = lib.recursiveUpdateUntil (path: _: _: path == [ "kubernetes" "services" "media" ])
            cluster.settings
            { kubernetes.services.media = media // evaluated; };
        };
      fixtureCluster = fixtureClusterWith { };
      fixtureInstances = lib.getAttrs [ "radarr" "sonarr" ] fixtureCluster.settings.kubernetes.services.media;
      fixtureCompute = computeResources // {
        retainedPaths =
          computeResources.retainedPaths
          // (lib.mapAttrs
            (state: uid: {
              path = "${builtins.dirOf computeResources.retainedPaths.radarr.path}/${state}";
              guestPath = "${builtins.dirOf computeResources.retainedPaths.radarr.guestPath}/${state}";
              inherit uid;
              gid = uid;
              mode = "0700";
              readOnly = false;
            })
            {
              radarr-hd = 752;
              radarr-remux = 752;
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
      fixtureApplications = projectApplications (
        renderApplications fixtureCluster fixtureCompute "radarr"
        // renderApplications fixtureCluster fixtureCompute "sonarr"
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
          builtins.deepSeq (mediaManifests (fixtureClusterWith overrides)) true
        );
      configurationWith =
        overrides:
        builtins.tryEval (
          builtins.deepSeq ((config.den.aspects.kubernetes.services.media.configuration."k8s-manifests" {
            cluster = fixtureClusterWith overrides;
            computeResources = fixtureCompute;
          }).applications.media-configuration.objects
          ) true
        );
      mediaBase = mediaWith { };
      # Arr, Prowlarr and SABnzbd have no login of their own, so any route to
      # them, including an extra one, must be an administrator route.
      mediaWithRoutes =
        routes:
        builtins.tryEval (
          builtins.deepSeq (mediaManifests (
            fixtureCluster
            // {
              routes = fixtureCluster.routes // routes;
            }
          )) true
        );
      withAuth = auth: route: route // { inherit auth; };
      nativeRouteRejected =
        lib.all
          (name: !(mediaWithRoutes { ${name} = withAuth "native" fixtureCluster.routes.${name}; }).success)
          [
            "sonarr"
            "prowlarr"
            "sabnzbd"
          ];
      extraRoute =
        auth:
        (mediaWithRoutes {
          radarr-remux-extra = withAuth auth (fixtureCluster.routes.sonarr // { service = "radarr-remux"; });
        }).success;
      extraNativeRouteRejected = !(extraRoute "native");
      extraAdminRouteAccepted = extraRoute "admin";
      # The Gateway policy of such a route must not also admit the whole
      # media namespace.
      namespaceWideRouteRejected =
        lib.all
          (
            name:
            !(mediaWithRoutes {
              ${name} = fixtureCluster.routes.${name} // {
                sameNamespaceIngress = true;
              };
            }).success
          )
          [
            "radarr"
            "sonarr"
            "prowlarr"
            "sabnzbd"
          ];
      # Ingress and client configuration for every instance, including those
      # without a route, and for an instance without a Seerr role.
      ingressFixture =
        overrides:
        let
          target = fixtureClusterWith overrides;
        in
        {
          ingress = (mediaManifests target).applications.media-ingress.objects;
          configuration =
            (config.den.aspects.kubernetes.services.media.configuration."k8s-manifests" {
              cluster = target;
              computeResources = fixtureCompute;
            }).applications.media-configuration.objects;
        };
      ingressFixtures = {
        roles = ingressFixture { };
        animeStandard = ingressFixture {
          sonarr.sonarr.role = null;
          sonarr.anime.role = "standard";
        };
      };
      mediaNoStandard = configurationWith {
        radarr.radarr.role = null;
        sonarr.sonarr.role = null;
      };
      mediaAmbiguousStandard = configurationWith { radarr.remux.role = "standard"; };
      mediaNoSharing = mediaWith { radarr.remux.sharedWritablePaths = [ ]; };
      mediaStateCollision = mediaWith { sonarr.anime.state = "radarr-hd"; };
      mediaSecretCollision = mediaWith { sonarr.anime.apiSecretKey = "RADARR_HD_API_KEY"; };
      mediaFixedSecretCollision = mediaWith { radarr.radarr.apiSecretKey = "PROWLARR_API_KEY"; };
      mediaProviderSecretCollision = mediaWith {
        radarr.radarr.apiSecretKey = "USENET_FIXTURE_PASSWORD";
        sabnzbd.providers.fixture = {
          host = "news.example.test";
          port = 563;
          ssl = true;
          connections = 8;
          priority = 0;
        };
      };
      mediaCategoryCollision = mediaWith { sonarr.anime.category = "movies-hd"; };
      unsafeCategoryRejected =
        kind: category:
        !(builtins.tryEval (
          builtins.deepSeq
            (lib.evalModules {
              modules = [
                {
                  options.${kind} = config.den.aspects.kubernetes.services.media.settings.${kind};
                  config.${kind}.${kind}.category = category;
                }
              ];
            }).config.${kind}.${kind}.category
            true
        )).success;
      unsafeCategoriesRejected =
        lib.all
          (
            kind:
            lib.all (unsafeCategoryRejected kind) [
              "*"
              ""
              "."
              ".."
              "../movies"
              "movies/hd"
              "movies\\hd"
              "movies\nhd"
            ]
          )
          [
            "radarr"
            "sonarr"
          ];
      mediaRootCollision = mediaWith { radarr.remux.root = "/data/library/movies/hd"; };
      mediaNestedRoot = mediaWith { radarr.remux.root = "/data/library/movies/hd/remux"; };
      sharedLibrary = [
        "/data"
        "/data/library/movies/hd"
      ];
      mediaOneSidedSharing = mediaWith {
        radarr.radarr.sharedWritablePaths = sharedLibrary;
        radarr.remux.root = "/data/library/movies/hd";
      };
      mediaSharedRoot = mediaWith {
        radarr.radarr.sharedWritablePaths = sharedLibrary;
        radarr.remux = {
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
      # Seerr phase PodSpec checks are native (media-configuration-state/inventory);
      # the phase matrix remains only for the coordination PersistentVolume.
      configurationPhases = lib.genAttrs [ "initial" "ready" ] (
        phase:
        (config.den.aspects.kubernetes.services.media.configuration."k8s-manifests" {
          cluster = cluster // {
            settings = lib.recursiveUpdate cluster.settings {
              kubernetes.services.seerr.phase = phase;
            };
          };
          inherit computeResources;
        }).applications
      );
      fixture = pkgs.writeText "media-instance-fixtures.json" (
        builtins.toJSON {
          instances = fixtureInstances;
          applications = fixtureApplications;
          runtimeSecrets = fixtureRuntimeSecrets;
          inherit configurationPhases;
          positive = mediaBase.success;
          inherit
            nativeRouteRejected
            extraNativeRouteRejected
            extraAdminRouteAccepted
            namespaceWideRouteRejected
            ingressFixtures
            ;
          seerrRoleAccepted = (configurationWith { }).success;
          noStandardRejected = !mediaNoStandard.success;
          ambiguousStandardRejected = !mediaAmbiguousStandard.success;
          unsupportedFourKRejected = lib.all (
            kind:
            let
              name = if kind == "radarr" then "remux" else "anime";
            in
            lib.all (
              profile:
              let
                selection = {
                  qualityProfiles = [ profile ];
                  defaultQualityProfile = profile;
                };
              in
              (configurationWith { ${kind}.${name} = selection; }).success
              && !(configurationWith {
                ${kind}.${name} = selection // { role = "4k"; };
              }).success
            ) [ "hd-preferred" "web-1080p" "remux-web-1080p" ]
          ) [ "radarr" "sonarr" ];
          emptyQualityProfilesRejected = !(configurationWith {
            radarr.radarr.qualityProfiles = [ ];
          }).success;
          duplicateQualityProfilesRejected = !(configurationWith {
            radarr.radarr.qualityProfiles = [ "hd-preferred" "hd-preferred" ];
          }).success;
          missingDefaultProfileRejected = !(configurationWith {
            radarr.radarr.qualityProfiles = [ "web-1080p" ];
          }).success;
          noSharingRejected = !mediaNoSharing.success;
          stateCollisionRejected = !mediaStateCollision.success;
          secretCollisionRejected = !mediaSecretCollision.success;
          fixedSecretCollisionRejected = !mediaFixedSecretCollision.success;
          providerSecretCollisionRejected = !mediaProviderSecretCollision.success;
          categoryCollisionRejected = !mediaCategoryCollision.success;
          inherit unsafeCategoriesRejected;
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
            # Provenance checks the fetched bytes, not a second inventory of labels.
            # Local policy must match independently fetched, hash-pinned upstream inputs.
            for name, file in source["files"].items():
                actual = pathlib.Path(upstream[name]).read_bytes()
                assert file["sha256"] == "sha256-" + base64.b64encode(hashlib.sha256(actual).digest()).decode()
                assert (policy_dir / name).read_bytes() == actual, name
            for name, metadata in source["localFiles"].items():
                assert metadata["sha256"] == "sha256-" + base64.b64encode(
                    hashlib.sha256((policy_dir / name).read_bytes()).digest()
                ).decode(), name

            # Rendered manifests are read only for facts no native rule covers;
            # see media-private-storage, media-acquisition-* and media-configuration-*.
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

            media_gid = str(storage["mediaGid"])
            sabnzbd_identity = storage["retainedPaths"]["sabnzbd"]

            fixture_instances = fixture["instances"]
            fixture_apps = fixture["applications"]
            expected_services = {"radarr", "radarr-remux", "sonarr", "sonarr-anime"}
            assert set(fixture_apps) == expected_services
            assert fixture["positive"]
            assert fixture["seerrRoleAccepted"]
            coordination = storage["retainedPaths"]["media-seerr-configuration"]
            assert (coordination["uid"], coordination["gid"], coordination["mode"], coordination["readOnly"]) == (1000, 1000, "0700", False)
            assert coordination["guestPath"] != storage["retainedPaths"]["seerr"]["guestPath"]
            for phase, applications in fixture["configurationPhases"].items():
                claim_objects = applications["media-seerr-configuration-storage"]["objects"]
                volume, = [item for item in claim_objects if item["kind"] == "PersistentVolume"]
                assert volume["spec"]["local"]["path"] == coordination["guestPath"]
                assert volume["spec"]["persistentVolumeReclaimPolicy"] == "Retain"
            assert fixture["noStandardRejected"]
            assert fixture["ambiguousStandardRejected"]
            assert fixture["unsupportedFourKRejected"]
            assert fixture["emptyQualityProfilesRejected"]
            assert fixture["duplicateQualityProfilesRejected"]
            assert fixture["missingDefaultProfileRejected"]
            assert fixture["noSharingRejected"]
            assert fixture["stateCollisionRejected"]
            assert fixture["secretCollisionRejected"]
            assert fixture["fixedSecretCollisionRejected"]
            assert fixture["providerSecretCollisionRejected"]
            assert fixture["categoryCollisionRejected"]
            assert fixture["unsafeCategoriesRejected"]
            assert fixture["rootCollisionRejected"]
            assert fixture["nestedRootRejected"]
            assert fixture["oneSidedSharingRejected"]
            assert fixture["explicitRootSharingAccepted"]
            assert fixture["nativeRouteRejected"]
            assert fixture["extraNativeRouteRejected"]
            assert fixture["extraAdminRouteAccepted"]
            assert storage["mediaInstances"] == {"radarr": ["radarr"], "sonarr": ["sonarr"]}

            # Browser sign-in to Arr, Prowlarr and SABnzbd is the Gateway's
            # Kanidm sign-in only: each app sits behind an admin route and
            # asks for no login of its own. The API keys stay.
            routes = {r["metadata"]["name"]: r for r in resources if r["kind"] == "HTTPRoute"}
            policies = {p["spec"]["targetRefs"][0]["name"] for p in resources if p["kind"] == "SecurityPolicy"}
            for app, port in (("radarr", 7878), ("sonarr", 8989), ("prowlarr", 9696), ("sabnzbd", 8080)):
                backend, = routes[app]["spec"]["rules"][0]["backendRefs"]
                assert (backend["namespace"], backend["name"], int(backend["port"])) == ("media", app, port), app
                assert app in policies, app
            for app in ("radarr", "sonarr", "prowlarr"):
                env = {
                    item["name"]: item
                    for item in find("Deployment", app)["spec"]["template"]["spec"]["containers"][0]["env"]
                }
                prefix = app.upper()
                assert env[prefix + "__AUTH__METHOD"]["value"] == "External", app
                assert env[prefix + "__AUTH__REQUIRED"]["value"] == "Enabled", app
                assert env[prefix + "__AUTH__APIKEY"]["valueFrom"]["secretKeyRef"]["key"] == prefix + "_API_KEY", app

            def validate_instance_group(kind, instances):
                expected_names = {"radarr", "remux"} if kind == "radarr" else {"sonarr", "anime"}
                assert set(instances) == expected_names
                for field in ("state", "apiSecretKey", "root", "category"):
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

            # Native media-acquisition-mounts covers the /data hostPath and mounts;
            # the media group membership is not covered natively.
            for name in ("radarr", "sonarr", "sabnzbd"):
                pod = find("Deployment", name)["spec"]["template"]["spec"]
                assert media_gid in pod["securityContext"]["supplementalGroups"], name

            # Native media-acquisition-identity compares SABnzbd PUID/PGID and the
            # initializer uid/gid with the trusted retained identity; this pins that identity.
            assert sabnzbd_identity["uid"] == sabnzbd_identity["gid"] == 757
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

            runtime_values = {
                "SABNZBD_API_KEY": "api-key-fixture",
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
            # Seerr/Configarr state, coordination, hostPath and fsGroup boundaries are
            # native: media-configuration-state, media-configuration-inventory, pod-pvc-no-fsgroup.
            for path in (environment / "media-configuration").rglob("*.yaml"):
                for resource in yaml.safe_load_all(path.read_text()):
                    if resource and resource["kind"] in {"Job", "CronJob"}:
                        spec = resource["spec"]
                        if resource["kind"] == "CronJob":
                            spec = spec["jobTemplate"]["spec"]
                        pod = spec["template"]["spec"]
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
                        for kind, names in storage["mediaInstances"].items():
                            assert set(configarr[kind]) == set(names), (kind, configarr[kind])
                            assert all(isinstance(instance, dict) and "base_url" in instance
                                       for instance in configarr[kind].values())
            # Native media-periodic-inventory/media-periodic-safety cover the inventory,
            # suspend and concurrencyPolicy; the schedules are not covered natively.
            periodic = {
                resource["metadata"]["name"]: resource["spec"]
                for resource in resources
                if resource["kind"] == "CronJob" and resource["metadata"]["namespace"] == "media"
            }
            for name, minute in (("media-configarr", 7), ("media-config-seerr", 37)):
                schedule = periodic[name]
                assert schedule["schedule"] == f"{minute} */6 * * *"
            assert configarr is not None, "Missing media configuration"
            assert configarr_env["LOG_LEVEL"] == "warn"
            assert configarr_env["STOP_ON_ERROR"] == "true"
            assert configarr_env["CONFIGARR_ENFORCE_CONFIG_VALIDATION"] == "true"
            assert configarr_env["CONFIGARR_ENFORCE_EXTERNAL_VALIDATION"] == "true"
            assert configarr["prowlarr"]["main"]["applications"]["delete_unmanaged"]["enabled"] is False
            for kind in ("radarr", "sonarr"):
                for instance in configarr[kind].values():
                    assert len(instance["root_folders"]) == 1
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
                for name, metadata in source["files"].items():
                    if "-cf-" in name:
                        assert (trash_repo / metadata["upstream"]).read_bytes() == pathlib.Path(upstream[name]).read_bytes()

            # Radarr, Sonarr, Prowlarr and SABnzbd have no login of their own,
            # and the Servarr UI hands out the API key. So what reaches their
            # ports must be exactly the Gateway proxy plus the in-cluster
            # clients that the media configuration points at them. Derive who
            # calls whom from the rendered configuration, then compare it with
            # what every NetworkPolicy selecting each app admits.
            from urllib.parse import urlsplit

            def endpoint(url):
                parts = urlsplit(url)
                service, namespace, _ = parts.hostname.split(".", 2)
                assert namespace == "media", url
                return service, int(parts.port)

            def declared_calls(configuration):
                """(client workload, server Service, port) for each in-cluster call."""
                config = yaml.load(configuration["config.yml"], Loader=ConfigarrLoader)
                seerr = json.loads(configuration["seerr.json"])
                calls = set()
                for kind in ("radarr", "sonarr"):
                    for instance in config[kind].values():
                        arr, port = endpoint(instance["base_url"])
                        calls.add(("media-configarr", arr, port))
                        # The Arr instance calls its download client.
                        for client in instance["download_clients"]["data"]:
                            host, namespace, _ = client["fields"]["host"].split(".", 2)
                            assert namespace == "media", client
                            calls.add((arr, host, int(client["fields"]["port"])))
                prowlarr = config["prowlarr"]["main"]
                indexer, port = endpoint(prowlarr["base_url"])
                calls.add(("media-configarr", indexer, port))
                for application in prowlarr["applications"]["data"]:
                    # Prowlarr pushes indexers to the Arr instance, which then
                    # searches through Prowlarr.
                    arr, arr_port = endpoint(application["fields"]["baseUrl"])
                    calls.add((indexer, arr, arr_port))
                    calls.add((arr, *endpoint(application["fields"]["prowlarrUrl"])))
                for kind in ("radarr", "sonarr"):
                    for fact in seerr["arr"][kind].values():
                        # The helper reads the Arr instance and registers it in
                        # Seerr, which then calls it.
                        arr, port = endpoint(fact["url"])
                        calls.add(("media-config-seerr", arr, port))
                        calls.add(("seerr", arr, port))
                return calls

            def pod_templates(objects):
                templates = {}
                for item in objects:
                    if item["metadata"].get("namespace") != "media":
                        continue
                    spec = item.get("spec", {})
                    if item["kind"] == "CronJob":
                        spec = spec["jobTemplate"]["spec"]
                    elif item["kind"] not in ("Deployment", "StatefulSet", "Job"):
                        continue
                    templates.setdefault(item["metadata"]["name"], []).append(spec["template"]["metadata"]["labels"])
                return templates

            def app_labels(name):
                return {"app.kubernetes.io/controller": "main", "app.kubernetes.io/instance": name, "app.kubernetes.io/name": name}

            gateway_peer = {
                "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "gateway"}},
                "podSelector": {"matchLabels": {
                    "gateway.envoyproxy.io/owning-gateway-name": "household",
                    "gateway.envoyproxy.io/owning-gateway-namespace": "gateway",
                }},
            }

            def selects(selector, labels):
                return all(labels.get(key) == value for key, value in selector.items())

            def admitted(server, policies, templates):
                """(workload or "gateway", port or None for every port) that reach the server's pods."""
                selecting = [
                    policy for policy in policies
                    if policy["metadata"]["namespace"] == "media"
                    and any(selects(policy["spec"]["podSelector"]["matchLabels"], labels) for labels in templates[server])
                ]
                assert selecting, f"{server}: no NetworkPolicy selects it, so every pod reaches it"
                result = set()
                for policy in selecting:
                    name = policy["metadata"]["name"]
                    assert set(policy["spec"]["podSelector"]) == {"matchLabels"}, name
                    assert "Ingress" in policy["spec"]["policyTypes"], name
                    for rule in policy["spec"].get("ingress", []):
                        assert "from" in rule, f"{name} admits every source"
                        ports = rule.get("ports")
                        for port in ports or []:
                            assert port.get("protocol", "TCP") == "TCP" and "endPort" not in port, name
                        port_values = [None] if ports is None else [int(port["port"]) for port in ports]
                        for peer in rule["from"]:
                            if peer == gateway_peer:
                                who = {"gateway"}
                            else:
                                assert set(peer) == {"podSelector"} and set(peer["podSelector"]) == {"matchLabels"}, \
                                    f"{name}: {peer} admits more than named media workloads"
                                who = {
                                    workload for workload, labels in templates.items()
                                    if any(selects(peer["podSelector"]["matchLabels"], each) for each in labels)
                                }
                                assert who, f"{name}: {peer} selects no media workload"
                            result |= {(workload, port) for workload in who for port in port_values}
                return result

            # Production: the committed manifests, Gateway policies included.
            templates = pod_templates(resources)
            # The fixtures below rely on this app-template labelling.
            for item in resources:
                if item["kind"] in ("Deployment", "StatefulSet") and item["metadata"].get("namespace") == "media":
                    name = item["metadata"]["name"]
                    assert selects(app_labels(name), item["spec"]["template"]["metadata"]["labels"]), name
            calls = declared_calls(find("ConfigMap", "media-configuration")["data"])
            loginless = {"radarr", "sonarr", "prowlarr", "sabnzbd"}
            assert {server for _, server, _ in calls} == loginless, calls
            media_policies = [r for r in resources if r["kind"] == "NetworkPolicy" and r["metadata"]["namespace"] == "media"]
            routed = {
                backend["name"]
                for route in routes.values()
                for rule in route["spec"]["rules"]
                for backend in rule["backendRefs"]
                if backend.get("namespace") == "media"
            }
            assert loginless <= routed
            matrix = {}
            for server in sorted(loginless):
                expected = {(client, port) for client, target, port in calls if target == server} | {("gateway", None)}
                actual = admitted(server, media_policies, templates)
                assert actual == expected, (server, sorted(actual, key=str), sorted(expected, key=str))
                matrix[server] = sorted(client for client, _ in actual)
            print("media ingress:", json.dumps(matrix, sort_keys=True))

            # Fixtures: instances without a route still admit only their
            # clients, and Seerr reaches only instances with a Seerr role.
            assert fixture["namespaceWideRouteRejected"]
            for case, data in fixture["ingressFixtures"].items():
                configuration = next(
                    item for item in data["configuration"]
                    if item["kind"] == "ConfigMap" and item["metadata"]["name"] == "media-configuration"
                )["data"]
                calls = declared_calls(configuration)
                servers = {"radarr", "radarr-remux", "sonarr", "sonarr-anime", "prowlarr", "sabnzbd"}
                assert {server for _, server, _ in calls} == servers, (case, calls)
                selected_sonarr = "sonarr-anime" if case == "animeStandard" else "sonarr"
                unselected_sonarr = "sonarr" if case == "animeStandard" else "sonarr-anime"
                assert ("seerr", selected_sonarr, 8989) in calls, case
                assert ("seerr", unselected_sonarr, 8989) not in calls, case
                seerr = json.loads(configuration["seerr.json"])
                assert all(set(seerr["arr"][kind]) == {"standard"} for kind in ("radarr", "sonarr")), case
                assert endpoint(seerr["arr"]["sonarr"]["standard"]["url"]) == (selected_sonarr, 8989), case
                templates = pod_templates(data["configuration"])
                assert set(templates) == {"media-configarr", "media-config-seerr"}, case
                for name in servers | {"seerr"}:
                    templates[name] = [app_labels(name)]
                assert {item["kind"] for item in data["ingress"]} == {"NetworkPolicy"}
                for server in sorted(servers):
                    expected = {(client, port) for client, target, port in calls if target == server}
                    actual = admitted(server, data["ingress"], templates)
                    assert actual == expected, (case, server, sorted(actual), sorted(expected))
            PY
            touch "$out"
          '';
      checks.seerr-credential-boundary = pkgs.runCommand "seerr-credential-boundary" { } ''
        ${pkgs.nodejs_22}/bin/node ${./seerr-credential-boundary.mjs} ${../den/aspects/kubernetes/services/seerr.mjs}
        touch "$out"
      '';
    };
}
