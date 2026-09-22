{
  config,
  den,
  inputs,
  lib,
  self,
  withSystem,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  environment = config.den.environments.${cluster.environment};
  retainedStorageRenderer =
    (import ../den/aspects/kubernetes/services/retained-storage.nix { })
    .den.aspects.kubernetes.services.retained-storage.k8s-manifests;
  rendererFixture = {
    instance = "compute-1";
    retainedPaths.kubernetes-volumes = {
      path = "/host-only/state/kubernetes-volumes";
      guestPath = "/srv/state/kubernetes-volumes";
      uid = 0;
      gid = 0;
      mode = "0700";
      readOnly = false;
    };
    storageCapabilities = [ "media" ];
    runtimeSecrets = { };
    images = [ "guest-image" ];
  };
  rendererBoundaryAssertions =
    let
      rendered = builtins.tryEval (retainedStorageRenderer {
        computeResources = rendererFixture // {
          unrelatedProjectedCapability = "ignored";
        };
        inherit lib;
      });
    in
    rendered.success;
  policiesFor =
    declared:
    (import ../den/policies/clusters.nix {
      inherit
        den
        inputs
        lib
        withSystem
        ;
      config = config // {
        den = config.den // {
          clusters.prod-home = declared;
        };
      };
    }).config.den.policies;
  rejected = value: !(builtins.tryEval (builtins.length value)).success;
  policy = policiesFor cluster;
  policyAssertions =
    !rejected (policy.environment-to-clusters { inherit environment; })
    && rejected (
      (policiesFor (cluster // { environment = "missing-placement-environment"; }))
      .environment-to-clusters
        { inherit environment; }
    )
    && rejected (
      (policiesFor (cluster // { hostName = "missing-placement-host"; })).environment-to-clusters {
        inherit environment;
      }
    )
    && rejected (
      policy.cluster-aspect {
        cluster = cluster // {
          name = "missing-placement-aspect";
        };
      }
    );
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      rendered = self.nixidyEnvs.${system}.prod-home.config.build.environmentPackage;
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.placement-contracts =
        assert lib.assertMsg rendererBoundaryAssertions
          "Kubernetes consumers must tolerate unrelated projected capabilities";
        assert lib.assertMsg policyAssertions
          "Cluster policies must reject undeclared environments, hosts and application aspects";
        pkgs.runCommand "placement-contracts"
          {
            nativeBuildInputs = [ python ];
          }
          ''
            python - ${rendered} ${lib.escapeShellArg environment.domain} ${lib.escapeShellArg environment.backupDomain} <<'PY'
            from pathlib import Path
            import sys
            import yaml
            yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", yaml.SafeLoader.construct_scalar)

            rendered = Path(sys.argv[1])
            domains = tuple(sys.argv[2:])


            def port(value):
                return value if type(value) is int and 1 <= value <= 65535 else None

            def in_domain(hostname, domain):
                return hostname == domain or hostname.endswith("." + domain)

            def placement_errors(resources, services, domains):
                errors = []
                grants = [obj for _, obj in resources if isinstance(obj, dict)
                          and obj.get("kind") == "ReferenceGrant"
                          and obj.get("apiVersion", "").split("/")[0] == "gateway.networking.k8s.io"]
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
                            if backend_namespace != namespace and not any(
                                grant.get("metadata", {}).get("namespace") == backend_namespace
                                and any(source.get("group") == "gateway.networking.k8s.io"
                                        and source.get("kind") == "HTTPRoute"
                                        and source.get("namespace") == namespace
                                        for source in grant.get("spec", {}).get("from", []))
                                and any(target.get("group", "") == ""
                                        and target.get("kind") == "Service"
                                        and target.get("name", backend_name) == backend_name
                                        for target in grant.get("spec", {}).get("to", []))
                                for grant in grants
                            ):
                                errors.append(f"{path}: cross-namespace backend {backend_namespace}/{backend_name} has no ReferenceGrant")
                            if (backend_namespace, backend_name, backend_port) not in services:
                                errors.append(
                                    f"{path}: HTTPRoute {namespace}/{name} backend Service "
                                    f"{backend_namespace}/{backend_name}:{ref.get('port')!r} is absent from rendered manifests"
                                )
                return errors


            valid_route = {
                "kind": "HTTPRoute",
                "metadata": {"name": "demo", "namespace": "test"},
                "spec": {
                    "hostnames": ["demo.example.test"],
                    "rules": [{"backendRefs": [{"name": "demo", "namespace": "app", "port": 80}]}],
                },
            }
            valid_grant = {
                "apiVersion": "gateway.networking.k8s.io/v1beta1",
                "kind": "ReferenceGrant",
                "metadata": {"name": "demo", "namespace": "app"},
                "spec": {
                    "from": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "namespace": "test"}],
                    "to": [{"group": "", "kind": "Service", "name": "demo"}],
                },
            }
            assert placement_errors(
                [("fixture.yaml", valid_route), ("grant.yaml", valid_grant)],
                {("app", "demo", 80)},
                ("example.test",),
            ) == []
            missing_grant = placement_errors(
                [("fixture.yaml", valid_route)], {("app", "demo", 80)}, ("example.test",)
            )
            assert any("no ReferenceGrant" in error for error in missing_grant)
            missing_service = placement_errors(
                [("fixture.yaml", valid_route), ("grant.yaml", valid_grant)],
                set(),
                ("example.test",),
            )
            assert any("backend Service app/demo:80" in error for error in missing_service)
            wrong_port = {
                **valid_route,
                "spec": {"hostnames": valid_route["spec"]["hostnames"],
                         "rules": [{"backendRefs": [{"name": "demo", "namespace": "app", "port": 81}]}]},
            }
            assert any(
                "backend Service app/demo:81" in error
                for error in placement_errors(
                    [("fixture.yaml", wrong_port), ("grant.yaml", valid_grant)],
                    {("app", "demo", 80)},
                    ("example.test",),
                )
            )
            outside_domain = {
                **valid_route,
                "spec": {"hostnames": ["demo.other.test"], "rules": valid_route["spec"]["rules"]},
            }
            assert any(
                "outside the declared domains" in error
                for error in placement_errors(
                    [("fixture.yaml", outside_domain), ("grant.yaml", valid_grant)],
                    {("app", "demo", 80)},
                    ("example.test",),
                )
            )
            empty_hostnames = {
                **valid_route,
                "spec": {"hostnames": [], "rules": valid_route["spec"]["rules"]},
            }
            assert any(
                "has no hostnames" in error
                for error in placement_errors(
                    [("fixture.yaml", empty_hostnames), ("grant.yaml", valid_grant)],
                    {("app", "demo", 80)},
                    ("example.test",),
                )
            )

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
