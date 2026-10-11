{
  config,
  inputs,
  lib,
  self,
  ...
}:
let
  # Version acceptance: render the real Jellyfin k8s-manifests aspect with the
  # cluster and the compute facts it reads from the cluster-to-nixidy
  # projection, varying only the provisioner package that jellyfin.nix reads
  # from inputs.self.packages.
  releaseCluster = config.den.clusters.prod-home;
  releaseCompute =
    config.den.hosts.${releaseCluster.hostSystem}.${releaseCluster.hostName}.settings.virtualization.compute;
  releaseComputeResources = {
    inherit (releaseCompute) instance retainedPaths;
    inherit (config.flake.clusterResources.prod-home) mediaPaths;
  };
  releaseSystem =
    inputs.self.nixosConfigurations.${releaseComputeResources.instance}.pkgs.stdenv.hostPlatform.system;
  provisionerPackage = inputs.self.packages.${releaseSystem}.jellyfin-provisioner-image;
  renderJellyfin =
    provisioner:
    (import ../den/aspects/kubernetes/services/jellyfin.nix {
      inherit config lib;
      inputs = inputs // {
        self = inputs.self // {
          packages = inputs.self.packages // {
            ${releaseSystem} = inputs.self.packages.${releaseSystem} // {
              jellyfin-provisioner-image = provisioner;
            };
          };
        };
      };
    }).den.aspects.kubernetes.services.jellyfin.k8s-manifests
      {
        cluster = releaseCluster;
        computeResources = releaseComputeResources;
      };
  # One side of the release moves; everything else is the shipped package.
  drift =
    {
      release ? { },
      build ? { },
    }:
    provisionerPackage
    // {
      passthru = provisionerPackage.passthru // {
        release = provisionerPackage.passthru.release // release;
        provisioner =
          provisionerPackage.passthru.provisioner
          // lib.optionalAttrs (build ? version) { inherit (build) version; }
          // lib.optionalAttrs (build ? sourceRev) {
            src = provisionerPackage.passthru.provisioner.src // {
              rev = build.sourceRev;
            };
          };
      };
    };
  laterSourceRev = "0123456789abcdef0123456789abcdef01234567";
  # The evaluation only reaches weak head normal form, which forces the
  # route and release assertions in jellyfin.nix and none of the resource
  # bodies. Every case shares the route, cluster and compute inputs with the
  # conformant render, so a rejected case can only fail a release assertion.
  # tryEval catches only throw/assert; any other error aborts the check.
  rejected = provisioner: !(builtins.tryEval (renderJellyfin provisioner)).success;
  driftCases = {
    # A coherent provisioner-only bump: package version and source move,
    # the stock runtime stays on 12.1.
    provisioner-source-moves-alone = drift {
      release = {
        version = "12.2";
        sourceRev = laterSourceRev;
      };
      build = {
        version = "12.2";
        sourceRev = laterSourceRev;
      };
    };
    # An image-only updater moves the stock runtime digest.
    runtime-digest-moves-alone = drift {
      release.runtimeDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    };
    # The stock runtime tag moves while the provisioner stays on 12.1.
    runtime-release-moves-alone = drift {
      release.runtimeImage = "docker.io/jellyfin/jellyfin:12.2";
    };
    # The provisioner build changes source without its release declaration.
    provisioner-build-leaves-declaration = drift {
      build.sourceRev = laterSourceRev;
    };
    # The PR #17902 patch revision moves without a reviewed release change.
    provision-patch-moves-alone = drift {
      release.provisionPatchRev = laterSourceRev;
    };
  };
  conformant = renderJellyfin provisionerPackage;
  conformantDeployment = lib.findFirst (
    object: object.kind == "Deployment" && object.metadata.name == "jellyfin"
  ) (throw "conformant Jellyfin render has no Deployment") conformant.applications.jellyfin.objects;
  conformantImages = {
    provisioner = (builtins.head conformantDeployment.spec.template.spec.initContainers).image;
    runtime = (builtins.head conformantDeployment.spec.template.spec.containers).image;
  };
  releaseFailures =
    lib.optional (
      !(builtins.tryEval (builtins.deepSeq conformantImages true)).success
    ) "conformant-release-renders"
    ++ lib.attrNames (lib.filterAttrs (_: provisioner: !(rejected provisioner)) driftCases);
  # Administrator names: evaluate the real option declaration on its own, so
  # a rejection can only come from its type check.
  administratorOption =
    (import ../den/aspects/kubernetes/services/jellyfin.nix { inherit config inputs lib; })
    .den.aspects.kubernetes.services.jellyfin.settings.administrator;
  administratorAccepted =
    name:
    (builtins.tryEval
      (lib.evalModules {
        modules = [
          { options.administrator = administratorOption; }
          { administrator = name; }
        ];
      }).config.administrator
    ).success;
  administratorCases = {
    declared = releaseCluster.settings.kubernetes.services.jellyfin.administrator;
    inner-space = "Jellyfin Admin";
  };
  # The first name is the runtime post-preflight fault in
  # prod-home-replacement.py; evaluation must refuse to deliver it.
  rejectedAdministrators = {
    slash = "post-preflight/fault";
    parent = "..";
    leading-space = " daniel";
  };
  administratorFailures =
    lib.attrNames (lib.filterAttrs (_: name: !(administratorAccepted name)) administratorCases)
    ++ lib.attrNames (lib.filterAttrs (_: administratorAccepted) rejectedAdministrators);
in
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
          inherit (config.flake.clusterResources.prod-home) mediaPaths;
        }
      );
      release = pkgs.writeText "jellyfin-release-contract.json" (
        builtins.toJSON self.packages.${cluster.hostSystem}.jellyfin-provisioner-image.passthru.release
      );
      jellarrRelease = pkgs.writeText "jellarr-release-contract.json" (
        builtins.toJSON self.packages.${cluster.hostSystem}.jellarr-image.passthru.release
      );
      contractInputs = pkgs.writeText "jellyfin-contract-inputs.json" (
        builtins.toJSON {
          administrator = cluster.settings.kubernetes.services.jellyfin.administrator;
        }
      );
      runtimeSecrets = pkgs.writeText "jellyfin-runtime-secrets-contract.json" (
        builtins.toJSON config.flake.clusterResources.prod-home.runtimeSecrets
      );
      renderedImages = pkgs.writeText "jellyfin-release-render.json" (
        builtins.unsafeDiscardStringContext (builtins.toJSON conformantImages)
      );
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.jellyfin-contracts =
        assert lib.assertMsg (releaseFailures == [ ])
          "Jellyfin release invariant checks failed: ${lib.concatStringsSep ", " releaseFailures}";
        assert lib.assertMsg (administratorFailures == [ ])
          "Jellyfin administrator name checks failed: ${lib.concatStringsSep ", " administratorFailures}";
        pkgs.runCommand "jellyfin-contracts"
          {
            nativeBuildInputs = [
              python
              pkgs.nodejs
              pkgs.bash
              pkgs.findutils
              pkgs.gnugrep
            ];
          }
          ''
            python - ${environment} ${storage} ${release} ${runtimeSecrets} ${jellarrRelease} ${contractInputs} ${renderedImages} <<'PY'
            import json
            import pathlib
            import sys
            import yaml

            environment = pathlib.Path(sys.argv[1])
            storage = json.loads(pathlib.Path(sys.argv[2]).read_text())
            release = json.loads(pathlib.Path(sys.argv[3]).read_text())
            runtime_secrets = json.loads(pathlib.Path(sys.argv[4]).read_text())
            jellarr_release = json.loads(pathlib.Path(sys.argv[5]).read_text())
            contract_inputs = json.loads(pathlib.Path(sys.argv[6]).read_text())
            release_render = json.loads(pathlib.Path(sys.argv[7]).read_text())
            resources = []
            application_objects = {}
            for application in ("jellyfin-retained", "jellyfin", "jellyfin-configuration", "gateway"):
                objects = [
                    resource
                    for path in (environment / application).rglob("*.yaml")
                    for resource in yaml.safe_load_all(path.read_text())
                    if resource
                ]
                application_objects[application] = objects
                resources.extend(objects)

            def find(kind, name, namespace="jellyfin"):
                return next(
                    resource
                    for resource in resources
                    if resource["kind"] == kind
                    and resource["metadata"]["name"] == name
                    and resource["metadata"].get("namespace", namespace) == namespace
                )

            def pod_spec(resource):
                return resource["spec"]["template"]["spec"]

            def mount(container, path):
                return next(item for item in container.get("volumeMounts", []) if item["mountPath"] == path)

            def secret_names(pod):
                names = {
                    volume["secret"]["secretName"]
                    for volume in pod.get("volumes", [])
                    if "secret" in volume
                }
                for container in pod.get("containers", []) + pod.get("initContainers", []):
                    names.update(
                        env["valueFrom"]["secretKeyRef"]["name"]
                        for env in container.get("env", [])
                        if "valueFrom" in env and "secretKeyRef" in env["valueFrom"]
                    )
                return names

            expected_release = {
                "version": "12.1",
                "sourceRev": "ee91c75e777da41a9c4f4855e70adc604fbf2ef8",
                "runtimeImage": "docker.io/jellyfin/jellyfin:12.1",
                "runtimeDigest": "sha256:78d3ea1207d1322471fcac39a614f004f2ccf7e878f95ab2977d752f07e4dd7e",
                "provisionPatchRev": "8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2",
            }
            assert release == expected_release, "provisioner passthru.release is the coupled Jellyfin identity"
            assert all(
                jellarr_release.get(key) == value
                for key, value in {
                    "version": "0.1.0",
                    "sourceRev": "f94c24f26c0264a7c331b016968d5b6e8d1504b7",
                }.items()
            ), "Jellarr package pin is the reviewed API client release"
            runtime_image = f"{release['runtimeImage']}@{release['runtimeDigest']}"
            retained = storage["retainedPaths"]["jellyfin-config"]
            deployment = find("Deployment", "jellyfin")
            pod = pod_spec(deployment)
            containers = pod["containers"]
            init_containers = pod.get("initContainers", [])
            assert len(containers) == 1 and len(init_containers) == 1, "Jellyfin has one stock container behind one provisioner init"
            runtime = containers[0]
            provisioner = init_containers[0]
            assert runtime["name"] == "jellyfin" and provisioner["name"] == "provision"
            assert runtime["image"] == runtime_image, "long-lived Jellyfin uses the exact stock runtime digest"
            assert runtime["image"].startswith("docker.io/jellyfin/jellyfin:12.1@sha256:")
            assert provisioner["image"] != runtime["image"], "patched provisioner bytes cannot become the long-lived runtime"
            # The release-drift cases in this check render through the same
            # harness; it must reproduce the delivered images exactly.
            assert release_render == {
                "provisioner": provisioner["image"],
                "runtime": runtime["image"],
            }, "the release-drift harness renders the delivered Jellyfin images"
            assert mount(provisioner, "/config")["name"] == mount(runtime, "/config")["name"]
            assert mount(provisioner, "/run/provision")["name"] != mount(runtime, "/config")["name"]
            assert mount(provisioner, "/run/secrets/password")["readOnly"] is True
            volumes = {volume["name"]: volume for volume in pod.get("volumes", [])}
            provision_volume = volumes[mount(provisioner, "/run/provision")["name"]]
            assert provision_volume["emptyDir"].get("medium") == "Memory"
            provisioner_env = {
                e["name"]: e["value"] for e in provisioner.get("env", [])
            }
            assert provisioner_env["JELLYFIN_ADMINISTRATOR"] == contract_inputs["administrator"], (
                "the provisioner creates the declared administrator, not an embedded name"
            )
            assert "readinessProbe" in runtime and "readinessProbe" not in provisioner
            assert "startupProbe" in runtime and "livenessProbe" in runtime
            assert runtime["securityContext"]["allowPrivilegeEscalation"] is False
            assert "ALL" in runtime["securityContext"]["capabilities"]["drop"]
            assert runtime.get("ports", []) == []
            assert provisioner.get("ports", []) == []
            assert pod["securityContext"]["runAsNonRoot"]
            assert pod["securityContext"]["runAsUser"] == retained["uid"]
            assert pod["securityContext"]["runAsGroup"] == retained["gid"]
            media_mount = mount(runtime, "/media")
            assert not any(m["mountPath"] == "/media" for m in provisioner["volumeMounts"]), "provisioner does not access media"
            assert media_mount.get("readOnly") is True
            assert deployment["spec"]["strategy"]["type"] == "Recreate"
            media_volume = volumes[media_mount["name"]]
            assert media_volume["hostPath"] == {
                "path": storage["mediaPaths"]["library"],
                "type": "Directory",
            }, "Jellyfin consumes the semantic media-library projection"
            assert storage["mediaPaths"]["library"] == storage["mediaPaths"]["data"] + "/library"
            assert volumes[mount(runtime, "/cache")["name"]]["emptyDir"]["sizeLimit"] == "4Gi"
            assert runtime["resources"]["limits"]["ephemeral-storage"] == "5Gi"
            assert runtime["resources"]["requests"]["ephemeral-storage"] == "4Gi"
            cache_gib = int(volumes[mount(runtime, "/cache")["name"]]["emptyDir"]["sizeLimit"].removesuffix("Gi"))
            requested_gib = int(runtime["resources"]["requests"]["ephemeral-storage"].removesuffix("Gi"))
            limited_gib = int(runtime["resources"]["limits"]["ephemeral-storage"].removesuffix("Gi"))
            assert cache_gib <= requested_gib < limited_gib, "the scheduler reserves cache capacity with headroom"

            pv = find("PersistentVolume", "jellyfin-config")
            pvc = find("PersistentVolumeClaim", "jellyfin-config")
            assert pv["spec"]["storageClassName"] == ""
            assert pv["spec"]["persistentVolumeReclaimPolicy"] == "Retain"
            assert pv["spec"]["claimRef"] == {
                "namespace": "jellyfin",
                "name": "jellyfin-config",
            }
            assert pvc["spec"]["storageClassName"] == ""
            assert pvc["spec"]["volumeName"] == "jellyfin-config"

            admin_source = runtime_secrets["jellyfin--jellyfin-admin--password"]
            assert admin_source["namespace"] == "jellyfin"
            assert admin_source["name"] == "jellyfin-admin"
            assert admin_source["key"] == "password"
            assert "jellyfin-admin" in secret_names(pod)

            jellyfin_objects = [resource for resource in resources if resource["metadata"].get("namespace") == "jellyfin"]
            assert not any(
                resource["kind"] == "ConfigMap"
                and (
                    resource["metadata"]["name"] == "network"
                    or "network.xml" in resource.get("data", {})
                )
                for resource in jellyfin_objects
            ), "Jellyfin does not own a generated network.xml ConfigMap"
            assert not any(
                volume["name"] == "network"
                for volume in pod.get("volumes", [])
            ), "Jellyfin does not mount a network.xml writer"
            for resource in jellyfin_objects:
                if resource["kind"] == "Secret" and resource["metadata"]["name"] == "jellyfin-admin":
                    assert not resource.get("data") and not resource.get("stringData"), "admin Secret values are runtime-only"

            configuration = find("ConfigMap", "jellarr-configuration")
            assert set(configuration.get("data", {})) == {"config.yml", "bootstrap.mjs"}
            jellarr_config = yaml.safe_load(configuration["data"]["config.yml"])
            # Each library reads one media-class directory of the read-only
            # /media projection; the replacement acceptance proves the
            # libraries in a running Jellyfin.
            library_paths = {
                folder["name"]: [info["path"] for info in folder["libraryOptions"]["pathInfos"]]
                for folder in jellarr_config["library"]["virtualFolders"]
            }
            assert all(
                len(paths) == 1 and paths[0].startswith("/media/") for paths in library_paths.values()
            ), library_paths
            assert len({paths[0] for paths in library_paths.values()}) == len(library_paths), library_paths
            assert "startup" not in jellarr_config

            job = find("Job", "jellyfin-configuration")
            annotations = job["metadata"].get("annotations", {})
            assert annotations.get("argocd.argoproj.io/hook") == "PostSync"
            job_pod = pod_spec(job)
            job_containers = job_pod["containers"]
            job_init = job_pod.get("initContainers", [])
            assert len(job_containers) == 1 and len(job_init) == 1, "Jellarr is one post-health one-shot with one API bootstrap init"
            assert job_containers[0]["name"] == "jellarr" and job_init[0]["name"] == "bootstrap"
            bootstrap_env = {
                e["name"]: e["value"] for e in job_init[0].get("env", [])
            }
            assert bootstrap_env["JELLYFIN_ADMINISTRATOR"] == contract_inputs["administrator"]
            assert "jellyfin-admin" in secret_names(job_pod)
            admin_volumes = {
                volume["name"]
                for volume in job_pod["volumes"]
                if volume.get("secret", {}).get("secretName") == "jellyfin-admin"
            }
            assert admin_volumes
            assert admin_volumes <= {
                mount["name"] for mount in job_init[0].get("volumeMounts", [])
            }
            assert not admin_volumes & {
                mount["name"] for mount in job_containers[0].get("volumeMounts", [])
            }
            jellarr_mount = mount(job_containers[0], "/run/jellarr")
            assert mount(job_init[0], "/run/jellarr")["name"] == jellarr_mount["name"]
            jellarr_volume = next(volume for volume in job_pod["volumes"] if volume["name"] == jellarr_mount["name"])
            assert jellarr_volume["emptyDir"].get("medium") == "Memory"
            assert not any(
                resource["kind"] == "Secret"
                and any(fragment in resource["metadata"]["name"].lower() for fragment in ("jellarr", "api-key", "apikey"))
                for resource in jellyfin_objects
            ), "Jellarr API-key bootstrap has no durable Secret resource"
            pathlib.Path("bootstrap.mjs").write_text(configuration["data"]["bootstrap.mjs"])

            # Once any NetworkPolicy in the jellyfin Application selects the
            # Jellyfin pod, the same Application must admit the Jellarr
            # configuration Job on 8096; another Application's policy cannot
            # cover it where the Jellyfin app is deployed alone.
            deployment_labels = deployment["spec"]["template"]["metadata"]["labels"]
            job_labels = job["spec"]["template"]["metadata"]["labels"]
            jellyfin_policies = [
                resource
                for resource in application_objects["jellyfin"]
                if resource["kind"] == "NetworkPolicy"
            ]
            selecting = [
                policy
                for policy in jellyfin_policies
                if set(policy["spec"].get("podSelector", {}).get("matchLabels", {}).items())
                <= set(deployment_labels.items())
            ]

            def admits_configuration_job(policy):
                for rule in policy["spec"].get("ingress", []):
                    ports = rule.get("ports", [])
                    port_ok = not ports or any(
                        entry.get("port") == 8096 for entry in ports
                    )
                    for source in rule.get("from", []):
                        pod_labels = source.get("podSelector", {}).get("matchLabels", {})
                        namespace = (
                            source.get("namespaceSelector", {})
                            .get("matchLabels", {})
                            .get("kubernetes.io/metadata.name")
                        )
                        if (
                            namespace == "jellyfin"
                            and set(pod_labels.items()) <= set(job_labels.items())
                            and port_ok
                        ):
                            return True
                return False

            if selecting:
                assert any(
                    admits_configuration_job(policy) for policy in jellyfin_policies
                ), "the jellyfin Application admits the jellyfin-configuration Job on 8096"

            service = find("Service", "jellyfin")
            service_spec = service["spec"]
            assert service_spec.get("type", "ClusterIP") == "ClusterIP"
            assert not service_spec.get("externalIPs") and not service_spec.get("loadBalancerIP")
            assert all("nodePort" not in port for port in service_spec["ports"])
            assert service_spec["selector"] == deployment["spec"]["selector"]["matchLabels"]
            assert any(port["port"] == 8096 and port["targetPort"] == 8096 for port in service_spec["ports"])

            route = find("HTTPRoute", "jellyfin", "gateway")
            assert route["spec"]["rules"][0]["timeouts"] == {
                "request": "0s",
                "backendRequest": "0s",
            }, "Jellyfin request and backend deadlines remain streaming-safe"

            PY
            node ${./jellyfin-bootstrap.mjs} bootstrap.mjs

            # Partial-state preflight: run the script the provisioner image runs
            # against empty, initialized and partial /config fixtures.
            preflight() {
              JELLYFIN_DATA_DIR="$1" JELLYFIN_CONFIG_DIR="$1/config" \
                bash -o errexit -o nounset -o pipefail ${../../pkgs/by-name/jellyfin-provisioner-image/preflight.sh} \
                >"$1.out" 2>"$1.err"
            }
            listing() {
              (find "$1" -printf '%P %s %T@\n' 2>/dev/null || true) | sort
            }
            accepts() {
              preflight "$1" || { echo "preflight refused $1: $(cat "$1.err")" >&2; exit 1; }
              grep -qF "$2" "$1.out" || { echo "preflight did not report '$2' for $1" >&2; exit 1; }
            }
            refuses() {
              before=$(listing "$1")
              if preflight "$1"; then echo "preflight accepted $1" >&2; exit 1; fi
              grep -qF "$2" "$1.err" || { echo "preflight refused $1 without '$2': $(cat "$1.err")" >&2; exit 1; }
              [ "$before" = "$(listing "$1")" ] || { echo "preflight changed $1" >&2; exit 1; }
            }
            mkdir -p cases/fresh cases/initialized/config cases/initialized/data
            printf '<?xml version="1.0" encoding="utf-8"?>\n<ServerConfiguration>\n  <IsStartupWizardCompleted>true</IsStartupWizardCompleted>\n</ServerConfiguration>\n' \
              > cases/initialized/config/system.xml
            : > cases/initialized/data/jellyfin.db
            # The state a post-preflight failure leaves: setup flag false, database present.
            mkdir -p cases/partial-setup/config cases/partial-setup/data
            sed 's/>true</>false</' cases/initialized/config/system.xml > cases/partial-setup/config/system.xml
            : > cases/partial-setup/data/jellyfin.db
            mkdir -p cases/partial-log/log cases/hidden-entry
            : > cases/partial-log/log/log_19700101.log
            : > cases/hidden-entry/.compute-recovery-marker
            accepts cases/fresh "provisioning fresh state"
            accepts cases/initialized "is initialized"
            refuses cases/partial-setup "refusing partial provisioning state"
            refuses cases/partial-log "refusing partial provisioning state"
            refuses cases/hidden-entry "refusing partial provisioning state"
            refuses cases/missing "is not a directory"
            touch "$out"
          '';
    };
}
