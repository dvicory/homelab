{
  config,
  lib,
  self,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  environment = config.den.environments.${cluster.environment};
  rendered = self.nixidyEnvs.x86_64-linux.prod-home.config.build.environmentPackage;
in
{
  perSystem =
    { pkgs, ... }:
    let
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.placement-contracts =
        pkgs.runCommand "placement-contracts"
          {
            nativeBuildInputs = [ python ];
          }
          ''
            python - ${rendered} ${lib.escapeShellArg environment.domain} ${lib.escapeShellArg environment.backupDomain} <<'PY'
            from pathlib import Path
            import sys
            import yaml

            rendered = Path(sys.argv[1])
            domains = tuple(sys.argv[2:])

            def reference_errors(cluster, environments, aspects):
                errors = []
                if cluster["environment"] not in environments:
                    errors.append(
                        f"Cluster {cluster['name']} references unknown environment {cluster['environment']}"
                    )
                if cluster["name"] not in aspects:
                    errors.append(f"Cluster {cluster['name']} has no application aspect")
                return errors

            def port(value):
                if isinstance(value, bool):
                    return None
                if isinstance(value, int):
                    return value
                if isinstance(value, str) and value.isdecimal():
                    return int(value)
                return None

            def in_domain(hostname, domain):
                return hostname == domain or hostname.endswith("." + domain)

            def placement_errors(resources, services, domains):
                errors = []
                for path, resource in resources:
                    if not isinstance(resource, dict):
                        errors.append(f"{path}: manifest document is not an object")
                        continue
                    if resource.get("kind") != "HTTPRoute":
                        continue
                    metadata = resource.get("metadata") or {}
                    spec = resource.get("spec") or {}
                    if not isinstance(metadata, dict) or not isinstance(spec, dict):
                        errors.append(f"{path}: HTTPRoute metadata/spec is not an object")
                        continue
                    namespace = metadata.get("namespace", "default")
                    name = metadata.get("name", "<unnamed>")
                    hostnames = spec.get("hostnames") or []
                    if not isinstance(hostnames, list):
                        errors.append(f"{path}: HTTPRoute {namespace}/{name} hostnames is not a list")
                        hostnames = []
                    if not hostnames:
                        errors.append(f"{path}: HTTPRoute {namespace}/{name} has no hostnames")
                    for hostname in hostnames:
                        if not isinstance(hostname, str) or not any(
                            in_domain(hostname, domain) for domain in domains
                        ):
                            errors.append(
                                f"{path}: HTTPRoute {namespace}/{name} hostname {hostname!r} is outside the declared domains"
                            )
                    rules = spec.get("rules") or []
                    if not isinstance(rules, list):
                        errors.append(f"{path}: HTTPRoute {namespace}/{name} rules is not a list")
                        rules = []
                    if not rules:
                        errors.append(f"{path}: HTTPRoute {namespace}/{name} has no rules")
                    for rule in rules:
                        if not isinstance(rule, dict):
                            errors.append(
                                f"{path}: HTTPRoute {namespace}/{name} has a non-object rule"
                            )
                            continue
                        refs = rule.get("backendRefs") or []
                        if not isinstance(refs, list):
                            errors.append(
                                f"{path}: HTTPRoute {namespace}/{name} backendRefs is not a list"
                            )
                            refs = []
                        if not refs:
                            errors.append(
                                f"{path}: HTTPRoute {namespace}/{name} has no backendRefs"
                            )
                        for ref in refs:
                            if not isinstance(ref, dict):
                                errors.append(
                                    f"{path}: HTTPRoute {namespace}/{name} has a non-object backendRef"
                                )
                                continue
                            if ref.get("group", "") != "" or ref.get("kind", "Service") != "Service":
                                errors.append(
                                    f"{path}: HTTPRoute {namespace}/{name} backendRef must target a core Service"
                                )
                                continue
                            backend_namespace = ref.get("namespace", namespace)
                            backend_name = ref.get("name")
                            backend_port = port(ref.get("port"))
                            if (backend_namespace, backend_name, backend_port) not in services:
                                errors.append(
                                    f"{path}: HTTPRoute {namespace}/{name} backend Service "
                                    f"{backend_namespace}/{backend_name}:{ref.get('port')!r} is absent from rendered manifests"
                                )
                return errors

            # Keep the policy's two trust-boundary failures covered by focused
            # negative fixtures without inventing a second application registry.
            valid_cluster = {"name": "prod-home", "environment": "prod"}
            assert reference_errors(valid_cluster, {"prod": {}}, {"prod-home": {}}) == []
            assert any(
                "unknown environment" in error
                for error in reference_errors(valid_cluster, {}, {"prod-home": {}})
            )
            assert any(
                "no application aspect" in error
                for error in reference_errors(valid_cluster, {"prod": {}}, {})
            )

            valid_route = {
                "kind": "HTTPRoute",
                "metadata": {"name": "demo", "namespace": "gateway"},
                "spec": {
                    "hostnames": ["demo.example.test"],
                    "rules": [
                        {
                            "backendRefs": [
                                {"name": "demo", "namespace": "app", "port": 80}
                            ]
                        }
                    ],
                },
            }
            assert placement_errors(
                [("fixture.yaml", valid_route)], {("app", "demo", 80)}, ("example.test",)
            ) == []
            missing_service = placement_errors(
                [("fixture.yaml", valid_route)], set(), ("example.test",)
            )
            assert any("backend Service app/demo:80" in error for error in missing_service)
            wrong_port = {
                **valid_route,
                "spec": {
                    **valid_route["spec"],
                    "rules": [{"backendRefs": [{"name": "demo", "namespace": "app", "port": 81}]}],
                },
            }
            wrong_port_errors = placement_errors(
                [("fixture.yaml", wrong_port)], {("app", "demo", 80)}, ("example.test",)
            )
            assert any("backend Service app/demo:81" in error for error in wrong_port_errors)
            outside_domain = {
                **valid_route,
                "spec": {**valid_route["spec"], "hostnames": ["demo.other.test"]},
            }
            outside_domain_errors = placement_errors(
                [("fixture.yaml", outside_domain)], {("app", "demo", 80)}, ("example.test",)
            )
            assert any("outside the declared domains" in error for error in outside_domain_errors)

            resources = []
            services = set()
            for path in sorted(rendered.rglob("*.yaml")):
                for resource in yaml.safe_load_all(path.read_text()):
                    if not resource:
                        continue
                    resources.append((str(path), resource))
                    if not isinstance(resource, dict) or resource.get("kind") != "Service":
                        continue
                    metadata = resource.get("metadata") or {}
                    if not isinstance(metadata, dict):
                        continue
                    namespace = metadata.get("namespace", "default")
                    name = metadata.get("name")
                    spec = resource.get("spec") or {}
                    if not isinstance(spec, dict):
                        continue
                    for service_port in spec.get("ports") or []:
                        if not isinstance(service_port, dict):
                            continue
                        service_port = port(service_port.get("port"))
                        if service_port is not None:
                            services.add((namespace, name, service_port))

            errors = placement_errors(resources, services, domains)
            if errors:
                raise SystemExit("\n".join(errors))
            PY
            touch "$out"
          '';
    };
}
