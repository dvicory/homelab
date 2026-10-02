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
          inherit (config.flake.clusterResources.prod-home) mediaPaths;
        }
      );
      runtimeSecrets = pkgs.writeText "jellyfin-runtime-secrets-contract.json" (
        builtins.toJSON config.flake.clusterResources.prod-home.runtimeSecrets
      );
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.jellyfin-contracts =
        pkgs.runCommand "jellyfin-contracts"
          {
            nativeBuildInputs = [
              python
              pkgs.nodejs
            ];
          }
          ''
            python - ${environment} ${storage} ${runtimeSecrets} <<'PY'
            import json
            import pathlib
            import sys
            import yaml

            environment = pathlib.Path(sys.argv[1])
            storage = json.loads(pathlib.Path(sys.argv[2]).read_text())
            runtime_secrets = json.loads(pathlib.Path(sys.argv[3]).read_text())
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

            retained = storage["retainedPaths"]["jellyfin-config"]
            deployment = find("Deployment", "jellyfin")
            pod = pod_spec(deployment)
            containers = pod["containers"]
            init_containers = pod.get("initContainers", [])
            runtime = next(container for container in containers if container["name"] == "jellyfin")
            provisioner = next(container for container in init_containers if container["name"] == "provision")
            assert provisioner["image"] != runtime["image"], "patched provisioner bytes cannot become the long-lived runtime"
            assert mount(provisioner, "/config")["name"] == mount(runtime, "/config")["name"]
            assert mount(provisioner, "/run/provision")["name"] != mount(runtime, "/config")["name"]
            assert mount(provisioner, "/run/secrets/password")["readOnly"] is True
            volumes = {volume["name"]: volume for volume in pod.get("volumes", [])}
            provision_volume = volumes[mount(provisioner, "/run/provision")["name"]]
            assert provision_volume["emptyDir"].get("medium") == "Memory"
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
            assert "startup" not in yaml.safe_load(configuration["data"]["config.yml"])

            job = find("Job", "jellyfin-configuration")
            annotations = job["metadata"].get("annotations", {})
            assert annotations.get("argocd.argoproj.io/hook") == "PostSync"
            job_pod = pod_spec(job)
            job_containers = job_pod["containers"]
            job_init = job_pod.get("initContainers", [])
            jellarr = next(container for container in job_containers if container["name"] == "jellarr")
            bootstrap = next(container for container in job_init if container["name"] == "bootstrap")
            assert "jellyfin-admin" in secret_names(job_pod)
            admin_volumes = {
                volume["name"]
                for volume in job_pod["volumes"]
                if volume.get("secret", {}).get("secretName") == "jellyfin-admin"
            }
            assert admin_volumes
            assert admin_volumes <= {
                mount["name"] for mount in bootstrap.get("volumeMounts", [])
            }
            assert not admin_volumes & {
                mount["name"] for mount in jellarr.get("volumeMounts", [])
            }
            jellarr_mount = mount(jellarr, "/run/jellarr")
            assert mount(bootstrap, "/run/jellarr")["name"] == jellarr_mount["name"]
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
                            and set(job_labels.items()) <= set(pod_labels.items())
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

            route = find("HTTPRoute", "jellyfin", "gateway")
            assert route["spec"]["rules"][0]["timeouts"] == {
                "request": "0s",
                "backendRequest": "0s",
            }, "Jellyfin request and backend deadlines remain streaming-safe"

            PY
            node ${./jellyfin-bootstrap.mjs} bootstrap.mjs
            touch "$out"
          '';
    };
}
