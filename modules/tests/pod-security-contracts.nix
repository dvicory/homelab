{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      environment = ../../generated/manifests/prod-home;
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.pod-security-contracts =
        pkgs.runCommand "pod-security-contracts"
          {
            nativeBuildInputs = [ python ];
          }
          ''
            python - ${environment} <<'PY'
            import pathlib
            import sys
            import yaml

            environment = pathlib.Path(sys.argv[1])
            resources = []
            for path in sorted(environment.rglob("*.yaml")):
                for resource in yaml.safe_load_all(path.read_text()):
                    if resource:
                        resources.append((path.relative_to(environment), resource))

            def pod_template_specs():
                for path, resource in resources:
                    spec = resource.get("spec") or {}
                    template = spec.get("template") or spec.get("jobTemplate", {}).get("spec", {}).get("template")
                    if isinstance(template, dict) and isinstance(template.get("spec"), dict):
                        yield path, resource, template["spec"]

            for path, resource, template_spec in pod_template_specs():
                owner = f"{path}:{resource['kind']}/{resource['metadata']['name']}"
                pod_security = template_spec.get("securityContext", {})
                declared_volumes = {volume["name"]: volume for volume in template_spec.get("volumes", [])}
                assert not (
                    "fsGroup" in pod_security
                    and any("persistentVolumeClaim" in volume for volume in declared_volumes.values())
                ), f"{owner} mounts a PersistentVolumeClaim and must not set fsGroup"
                fs_group = pod_security.get("fsGroup")
                pod_containers = (
                    template_spec.get("containers", [])
                    + template_spec.get("initContainers", [])
                    + template_spec.get("ephemeralContainers", [])
                )
                for container in pod_containers:
                    container_security = container.get("securityContext", {})
                    run_as_user = container_security.get("runAsUser", pod_security.get("runAsUser"))
                    if run_as_user is not None and int(str(run_as_user)) == 0:
                        continue
                    run_as_group = container_security.get("runAsGroup", pod_security.get("runAsGroup"))
                    for volume_mount in container.get("volumeMounts", []):
                        volume = declared_volumes.get(volume_mount["name"])
                        if volume is None:
                            continue
                        for source in ("secret", "projected"):
                            source_spec = volume.get(source)
                            if not source_spec:
                                continue
                            default_mode = source_spec.get("defaultMode", 0o644)
                            entries = source_spec.get("items") or source_spec.get("sources") or [{}]
                            for mode in (int(str(entry.get("mode", default_mode))) for entry in entries):
                                readable = bool(mode & 0o004) or (
                                    bool(mode & 0o040)
                                    and fs_group is not None
                                    and run_as_group is not None
                                    and str(fs_group) == str(run_as_group)
                                )
                                assert readable, (
                                    f"{owner} container {container['name']} mounts {source} volume "
                                    f"{volume['name']} with mode {mode:04o} unreadable by uid {run_as_user}"
                                )
            PY
            touch "$out"
          '';
    };
}
