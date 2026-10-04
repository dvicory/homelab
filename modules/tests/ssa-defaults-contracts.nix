{
  lib,
  self,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    let
      rendered = self.nixidyEnvs.${system}.prod-home.config.build.environmentPackage;
      python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      # Argo CD applies every Application with ServerSideApply=true and owns
      # each rendered atomic list or map as a whole. The API server then adds
      # CRD defaults inside it, but Argo's structured-merge diff does not know
      # CRD defaults, so the resource stays OutOfSync forever. Apply the
      # rendered CRDs' defaults to each rendered custom resource and reject
      # any default that would land inside an atomic structure we render.
      checks.ssa-defaults-contracts =
        pkgs.runCommand "ssa-defaults-contracts" { nativeBuildInputs = [ python ]; }
          ''
            python - ${rendered} <<'PY'
            from pathlib import Path
            import copy
            import os
            import sys
            import yaml
            yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", yaml.SafeLoader.construct_scalar)


            def omitted_defaults(obj, schema, path="", atomic=False):
                """Paths where the API server would add a default inside a rendered atomic structure."""
                found = []
                if isinstance(obj, dict) and isinstance(schema, dict):
                    atomic = atomic or schema.get("x-kubernetes-map-type") == "atomic"
                    for key, sub in (schema.get("properties") or {}).items():
                        if key in obj:
                            found += omitted_defaults(obj[key], sub, f"{path}.{key}", atomic)
                        elif "default" in sub and atomic:
                            # A default added outside atomic structures has no
                            # owner, so it never differs from Argo's prediction.
                            found.append((f"{path}.{key}", sub["default"]))
                    extra = schema.get("additionalProperties")
                    if isinstance(extra, dict):
                        for key, value in obj.items():
                            found += omitted_defaults(value, extra, f"{path}{{{key}}}", atomic)
                elif isinstance(obj, list) and isinstance(schema, dict) and "items" in schema:
                    # Structured merge treats a list without a list type as atomic.
                    atomic = atomic or schema.get("x-kubernetes-list-type", "atomic") == "atomic"
                    for index, item in enumerate(obj):
                        found += omitted_defaults(item, schema["items"], f"{path}[{index}]", atomic)
                return found


            def check(resource, schemas):
                key = (resource.get("apiVersion"), resource.get("kind"))
                if key not in schemas:
                    return []
                body = {k: v for k, v in resource.items() if k not in ("metadata", "status")}
                return omitted_defaults(copy.deepcopy(body), schemas[key])


            # Each application directory is a symlink into its own store path.
            paths = sorted(
                Path(root, name)
                for root, _, names in os.walk(sys.argv[1], followlinks=True)
                for name in names
                if name.endswith(".yaml")
            )
            documents = []
            for path in paths:
                for resource in yaml.safe_load_all(path.read_text()):
                    if isinstance(resource, dict):
                        documents.append((str(path), resource))

            schemas = {}
            for _, resource in documents:
                if resource.get("kind") != "CustomResourceDefinition":
                    continue
                spec = resource["spec"]
                for version in spec["versions"]:
                    schemas[(f"{spec['group']}/{version['name']}", spec["names"]["kind"])] = (
                        version["schema"]["openAPIV3Schema"]
                    )

            # The production HTTPRoute that stayed OutOfSync must be reported
            # field for field, and the same route with explicit defaults must pass.
            bare = {
                "apiVersion": "gateway.networking.k8s.io/v1",
                "kind": "HTTPRoute",
                "spec": {
                    "parentRefs": [{"name": "household"}],
                    "rules": [{
                        "matches": [{"path": {"type": "PathPrefix", "value": "/"}}],
                        "backendRefs": [{"name": "kanidm", "namespace": "identity", "port": 443}],
                    }],
                },
            }
            assert sorted(path for path, _ in check(bare, schemas)) == [
                ".spec.parentRefs[0].group",
                ".spec.parentRefs[0].kind",
                ".spec.rules[0].backendRefs[0].group",
                ".spec.rules[0].backendRefs[0].kind",
                ".spec.rules[0].backendRefs[0].weight",
            ], check(bare, schemas)
            explicit = copy.deepcopy(bare)
            explicit["spec"]["parentRefs"][0].update(group="gateway.networking.k8s.io", kind="Gateway")
            explicit["spec"]["rules"][0]["backendRefs"][0].update(group="", kind="Service", weight=1)
            assert check(explicit, schemas) == [], check(explicit, schemas)

            errors = []
            for path, resource in documents:
                metadata = resource.get("metadata") or {}
                for field, default in check(resource, schemas):
                    errors.append(
                        f"{path}: {resource['kind']} {metadata.get('namespace', '-')}/{metadata.get('name')} "
                        f"omits {field} (CRD default {default!r})"
                    )
            if errors:
                raise SystemExit("\n".join(errors))
            PY
            touch "$out"
          '';
    };
}
