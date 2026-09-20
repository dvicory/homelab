{
  inputs,
  lib,
  self,
  rootPath,
  ...
}:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      environment = self.nixidyEnvs.${system}.prod-home.config.build.environmentPackage;
      manifestSource = rootPath + "/generated/manifests/prod-home";
      generatedManifests =
        if builtins.pathExists manifestSource then
          manifestSource
        else
          throw ''
            Canonical production manifests are missing. Generate them with:
              nix run .#sync-prod-home-manifests
            Then review and track generated/manifests/prod-home before running this check.
          '';
    in
    {
      packages.prod-home-manifests = environment;

      apps.sync-prod-home-manifests = {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = "sync-prod-home-manifests";
            runtimeInputs = [
              pkgs.coreutils
              config.flake-root.package
              pkgs.rsync
            ];
            text = ''
              set -euo pipefail
              source=${environment}
              root="$(${lib.getExe config.flake-root.package})"
              destination="$root/generated/manifests/prod-home"
              rm -rf "$destination"
              mkdir -p "$destination"

              # Copy the store's symlinked tree as ordinary checked-in files and
              # omit nixidy's volatile revision marker.
              rsync -a --copy-links --delete --exclude .revision \
                --chmod=Du+rwx,Dg+rx,Do+rx,Fu+rw,Fg+r,Fo+r \
                "$source"/ "$destination"/

              cat <<EOF
              Wrote canonical prod-home manifests from the ${system} renderer.
              Review the tree, then track new YAML before evaluating checks:
                jj file track generated/manifests/prod-home
              EOF
            '';
          }
        );
      };

      checks.prod-home-manifests-fresh =
        pkgs.runCommandLocal "prod-home-manifests-fresh"
          {
            src = generatedManifests;
            expected = environment;
            nativeBuildInputs = [
              pkgs.diffutils
              pkgs.rsync
            ];
          }
          ''
            work=$(mktemp -d)
            trap 'rm -rf "$work"' EXIT
            cp -aL "$expected"/. "$work"/
            chmod -R u+w "$work"
            if ! diff -qr --exclude=.revision "$src" "$work" > diff-report.txt; then
              cat diff-report.txt
              cat >&2 <<'EOF'
            Canonical prod-home manifests are stale. Regenerate them with:
              nix run .#sync-prod-home-manifests
            EOF
              exit 1
            fi
            touch $out
          '';

      checks.prod-home-gitops-source =
        pkgs.runCommandLocal "prod-home-gitops-source"
          {
            src = generatedManifests;
            RUNTIME_SECRET_TARGETS = builtins.toJSON (
              map (entry: {
                inherit (entry)
                  namespace
                  name
                  key
                  type
                  ;
              }) (builtins.attrValues self.clusterResources.prod-home.runtimeSecrets)
            );
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            ];
          }
          ''
            export MANIFEST_ROOT="$src"
            ${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python - <<'PY'
            from pathlib import Path
            import json
            import os
            import yaml

            # CRD enums may contain bare "="; PyYAML tags it but supplies no scalar constructor.
            yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", yaml.SafeLoader.construct_scalar)

            def check(condition, path, message):
                if not condition:
                    print(f"{path}: {message}")
                    raise SystemExit(f"unexpected {path}")

            root = Path(os.environ["MANIFEST_ROOT"])
            apps_root = root / "apps"
            expected_repository = "https://github.com/dvicory/homelab.git"
            expected_revision = "main"
            expected_prefix = "./generated/manifests/prod-home/"

            files = sorted((root / "apps").glob("Application-*.yaml"))
            check(bool(files), root, "no generated Argo applications found")
            seen = set()
            owners = {}
            objects = []
            for path in files:
                with path.open() as handle:
                    resource = yaml.safe_load(handle)
                check(resource.get("kind") == "Application", path, "expected an Application")
                source = resource["spec"]["source"]
                check(source["repoURL"] == expected_repository, path, f"unexpected repository {source['repoURL']}")
                check(source["targetRevision"] == expected_revision, path, f"unexpected revision {source['targetRevision']}")
                check(source["path"].startswith(expected_prefix), path, f"unexpected path {source['path']}")
                relative = source["path"][len(expected_prefix):]
                check(bool(relative) and not Path(relative).is_absolute()
                      and ".." not in Path(relative).parts and relative != "."
                      and Path(relative).as_posix() == relative, path, f"unsafe path {source['path']}")
                check(relative not in seen, path, f"multiple Applications own source directory {relative}")
                check((root / relative).is_dir(), path, f"missing directory {relative}")
                finalizers = resource.get("metadata", {}).get("finalizers", [])
                prune = resource["spec"]["syncPolicy"]["automated"]["prune"]
                if finalizers:
                    check(finalizers == ["resources-finalizer.argocd.argoproj.io"], path, f"unexpected finalizers {finalizers}")
                else:
                    check(prune is False, path, "non-cascading application must disable pruning")
                for manifest in sorted((root / relative).glob("*.yaml")):
                    for obj in yaml.safe_load_all(manifest.read_text()):
                        if obj is None:
                            continue
                        check(isinstance(obj, dict), manifest, "expected a Kubernetes object")
                        metadata = obj.get("metadata", {})
                        identity = (obj.get("apiVersion"), obj.get("kind"), metadata.get("namespace", ""), metadata.get("name"))
                        check(all(isinstance(part, str) and part for part in (identity[0], identity[1], identity[3])),
                              manifest, "object lacks apiVersion, kind or metadata.name")
                        check(identity not in owners, manifest, f"duplicate object {identity}; already owned by {owners.get(identity)}")
                        owners[identity] = path.name
                        objects.append((manifest, obj))
                        options = metadata.get("annotations", {}).get("argocd.argoproj.io/sync-options", "").split(",")
                        if "Delete=false" in options:
                            check(not finalizers and prune is False, manifest, "Delete=false resource requires a retained Application")
                        if not finalizers:
                            check("Delete=false" in options, manifest, "non-cascading resource must be protected from deletion")
                seen.add(relative)

            bootstrap = yaml.safe_load((root / "bootstrap.yaml").read_text())
            check(bootstrap["kind"] == "Application", root / "bootstrap.yaml", "expected an Application")
            check(bootstrap["spec"]["source"]["path"] == expected_prefix + "apps", root / "bootstrap.yaml", "bootstrap must reconcile the apps directory")
            check(bootstrap["spec"]["source"]["repoURL"] == expected_repository, root / "bootstrap.yaml", "unexpected repository")
            check(bootstrap["spec"]["source"]["targetRevision"] == expected_revision, root / "bootstrap.yaml", "unexpected revision")
            covered = {path.name for path in root.iterdir() if path.is_dir() and path.name != "apps"}
            check(seen == covered, root, f"unreferenced directories: {sorted(covered - seen)}")

            staged = {}
            staged_types = {}
            for entry in json.loads(os.environ["RUNTIME_SECRET_TARGETS"]):
                target = (entry["namespace"], entry["name"])
                staged.setdefault(target, set()).add(entry["key"])
                check(staged_types.setdefault(target, entry["type"]) == entry["type"],
                      root, f"staged Secret has conflicting types: {target}")
            for target, secret_type in staged_types.items():
                if secret_type == "kubernetes.io/tls":
                    check({"tls.crt", "tls.key"} <= staged[target], root,
                          f"TLS Secret lacks its certificate or private-key producer: {target}")
            supplied = {target: keys.copy() for target, keys in staged.items()}
            identities = {(obj["kind"], obj.get("metadata", {}).get("namespace", "default"),
                           obj["metadata"]["name"]): obj for _, obj in objects}
            for path, obj in objects:
                if obj["kind"] == "Secret":
                    target = (obj["metadata"].get("namespace", "default"), obj["metadata"]["name"])
                    check(target not in supplied, path, f"rendered Secret competes with staged producer {target}")
                    supplied[target] = set(obj.get("data", {})) | set(obj.get("stringData", {}))

            # Existing chart/provisioning Jobs own these Secrets through the API,
            # rather than rendering Secret objects or taking host-staged inputs.
            native_producers = [
                (("argocd", "argocd-redis"), ("Job", "argocd", "argocd-redis-secret-init"), {"auth"}),
                (("gateway", "oidc-client"), ("Job", "identity", "kanidm-provision"), {"client-secret"}),
                (("gateway", "envoy-gateway"), ("Job", "gateway", "envoy-gateway-gateway-helm-certgen"),
                 {"ca.crt", "tls.crt", "tls.key"}),
                (("monitoring", "monitoring-admission"), ("Job", "monitoring", "monitoring-admission-create"),
                 {"ca", "cert", "key"}),
            ]
            for target, owner, keys in native_producers:
                if owner in identities:
                    containers = identities[owner]["spec"]["template"]["spec"]["containers"]
                    if owner == ("Job", "identity", "kanidm-provision"):
                        env = {entry["name"]: entry.get("value") for container in containers for entry in container.get("env", [])}
                        check(env.get("KANIDM_CLIENT_SECRET") == target[1], root,
                              "Kanidm provisioning Job targets a different OIDC Secret")
                    if owner == ("Job", "monitoring", "monitoring-admission-create"):
                        args = [arg for container in containers for arg in container.get("args", [])]
                        check(f"--secret-name={target[1]}" in args and f"--namespace={target[0]}" in args,
                              root, "monitoring certificate Job targets a different Secret")
                    check(target not in supplied, root, f"native Secret producer competes for {target}")
                    supplied[target] = keys

            used = set()
            def secret_reference(ref, namespace, path, keys=()):
                target = (ref.get("namespace", namespace), ref.get("name", ref.get("secretName")))
                if ref.get("optional", False):
                    return
                check(target in supplied, path, f"required Secret has no producer: {target}")
                check(set(keys) <= supplied[target], path,
                      f"required Secret keys have no producer: {target} {sorted(set(keys) - supplied[target])}")
                used.add(target)

            def secret_references(value, namespace, path):
                if isinstance(value, list):
                    for child in value:
                        secret_references(child, namespace, path)
                elif isinstance(value, dict):
                    for key, child in value.items():
                        if key == "secretKeyRef":
                            secret_reference(child, namespace, path, [child["key"]])
                        elif key == "secretRef":
                            secret_reference(child, namespace, path)
                        elif key == "secret" and isinstance(child, dict) and ("name" in child or "secretName" in child):
                            secret_reference(child, namespace, path, [item["key"] for item in child.get("items", [])])
                        elif key == "imagePullSecrets":
                            for ref in child:
                                secret_reference(ref, namespace, path)
                        elif key in ("certificateRefs", "caCertificateRefs"):
                            default_kind = "Secret" if key == "certificateRefs" else "ConfigMap"
                            for ref in child:
                                if ref.get("group", "") == "" and ref.get("kind", default_kind) == "Secret":
                                    required_keys = ("tls.crt", "tls.key") if key == "certificateRefs" else ()
                                    secret_reference(ref, namespace, path, required_keys)
                        elif key == "clientSecret" and isinstance(child, dict):
                            secret_reference(child, namespace, path, ["client-secret"])
                        secret_references(child, namespace, path)

            for path, obj in objects:
                if obj["kind"] != "CustomResourceDefinition":
                    secret_references(obj, obj["metadata"].get("namespace", "default"), path)
            # Argo reads its fixed-name Secret directly through the Kubernetes API.
            if ("Deployment", "argocd", "argocd-server") in identities:
                secret_reference({"name": "argocd-secret"}, "argocd", root,
                                 ["server.secretkey", "admin.password", "admin.passwordMtime"])
            check(not (staged.keys() - used), root,
                  f"staged Secrets without consumers: {sorted(staged.keys() - used)}")
            print(f"checked {len(files)} generated Argo applications")
            PY
            touch $out
          '';
    };
}
