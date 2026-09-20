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
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            ];
          }
          ''
            export MANIFEST_ROOT="$src"
            ${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python - <<'PY'
            from pathlib import Path
            import os
            import yaml
            # CRD enums may contain bare "="; PyYAML tags it but supplies no scalar constructor.
            yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", yaml.SafeLoader.construct_scalar)

            def check(condition, path, message):
                if not condition:
                    print(f"{path}: {message}")
                    raise SystemExit(f"unexpected {path}")
            expected_application_namespace = "argocd"
            expected_project = "default"
            expected_destination = "https://kubernetes.default.svc"
            application_ids = set()

            def check_application(resource, path, allow_retained):
                check(resource.get("kind") == "Application", path, "expected an Application")
                metadata = resource.get("metadata", {})
                check(isinstance(metadata, dict), path, "Application metadata must be a mapping")
                identity = (metadata.get("namespace"), metadata.get("name"))
                check(identity[0] == expected_application_namespace, path, f"unexpected Application namespace {identity[0]}")
                check(isinstance(identity[1], str) and identity[1], path, "Application lacks metadata.name")
                check(identity not in application_ids, path, f"duplicate Application identity {identity}")
                application_ids.add(identity)
                spec = resource.get("spec", {})
                check(isinstance(spec, dict), path, "Application spec must be a mapping")
                destination = spec.get("destination", {})
                check(isinstance(destination, dict), path, "Application destination must be a mapping")
                check(destination.get("server") == expected_destination, path, f"unexpected destination server {destination.get('server')}")
                check(spec.get("project") == expected_project, path, f"unexpected Argo project {spec.get('project')}")
                finalizers = metadata.get("finalizers", [])
                check(isinstance(finalizers, list), path, "Application finalizers must be a list")
                sync_policy = spec.get("syncPolicy", {})
                check(isinstance(sync_policy, dict), path, "Application syncPolicy must be a mapping")
                automated = sync_policy.get("automated", {})
                check(isinstance(automated, dict), path, "Application automated sync policy must be a mapping")
                prune = automated.get("prune")
                if allow_retained and not finalizers:
                    check(prune is False, path, "retained Application must disable pruning")
                else:
                    check(finalizers == ["resources-finalizer.argocd.argoproj.io"], path, f"unexpected finalizers {finalizers}")
                    check(prune is True, path, "cascading Application must enable pruning")
                source = spec.get("source", {})
                check(isinstance(source, dict), path, "Application source must be a mapping")
                return source, finalizers, prune

            root = Path(os.environ["MANIFEST_ROOT"])

            apps_root = root / "apps"
            expected_repository = "https://github.com/dvicory/homelab.git"
            expected_revision = "main"
            expected_prefix = "./generated/manifests/prod-home/"
            app_entries = sorted(apps_root.iterdir())
            check(
                all(
                    entry.is_file()
                    and entry.name.startswith("Application-")
                    and entry.suffix == ".yaml"
                    for entry in app_entries
                ),
                apps_root,
                "apps directory contains an unsupported effective manifest",
            )
            files = sorted(path for path in app_entries if path.name.startswith("Application-") and path.suffix == ".yaml")
            check(bool(files), root, "no generated Argo applications found")
            check({path.name for path in files} == {path.name for path in app_entries}, apps_root, "apps directory has unchecked files")


            seen = set()
            owners = {}
            for path in files:
                with path.open() as handle:
                    resource = yaml.safe_load(handle)
                source, finalizers, prune = check_application(resource, path, allow_retained=True)
                for marker in ("helm", "kustomize", "jsonnet", "plugin"):
                    check(marker not in source, path, f"unsupported source renderer {marker}")
                directory = source.get("directory") or {}
                check(isinstance(directory, dict), path, "source.directory must be a mapping")
                check(set(directory) <= {"recurse"}, path, "source.directory has unsupported options")
                check(
                    "recurse" not in directory or isinstance(directory["recurse"], bool),
                    path,
                    "source.directory.recurse must be boolean",
                )
                check(source["repoURL"] == expected_repository, path, f"unexpected repository {source['repoURL']}")
                check(source["targetRevision"] == expected_revision, path, f"unexpected revision {source['targetRevision']}")
                check(source["path"].startswith(expected_prefix), path, f"unexpected path {source['path']}")
                relative = source["path"][len(expected_prefix):]
                check(bool(relative) and not Path(relative).is_absolute()
                      and ".." not in Path(relative).parts and relative != "."
                      and Path(relative).as_posix() == relative, path, f"unsafe path {source['path']}")
                check(relative not in seen, path, f"multiple Applications own source directory {relative}")
                check((root / relative).is_dir(), path, f"missing directory {relative}")
                recurse = directory.get("recurse", False) is True
                object_count = 0
                manifest_paths = (
                    (root / relative).rglob("*") if recurse else (root / relative).glob("*")
                )
                for manifest in sorted(path for path in manifest_paths if path.is_file()):
                    check(
                        not (
                            manifest.name in {"Chart.yaml", "kustomization.yaml", "kustomization.yml", "Kustomization"}
                            or manifest.suffix.lower() == ".jsonnet"
                        ),
                        manifest,
                        "source contains an unsupported renderer marker",
                    )
                    if manifest.suffix.lower() not in {".yaml", ".yml", ".json"}:
                        continue
                    for obj in yaml.safe_load_all(manifest.read_text()):
                        if obj is None:
                            continue
                        check(isinstance(obj, dict), manifest, "expected a Kubernetes object")
                        metadata = obj.get("metadata", {})
                        check(isinstance(metadata, dict), manifest, "object metadata is not a mapping")
                        identity = (
                            obj.get("apiVersion"),
                            obj.get("kind"),
                            metadata.get("namespace", ""),
                            metadata.get("name"),
                        )
                        check(
                            all(isinstance(part, str) and part for part in (identity[0], identity[1], identity[3])),
                            manifest,
                            "object lacks apiVersion, kind or metadata.name",
                        )
                        object_count += 1
                        check(
                            identity not in owners,
                            manifest,
                            f"duplicate object {identity}; already owned by {owners.get(identity)}",
                        )
                        owners[identity] = path.name
                        options = metadata.get("annotations", {}).get(
                            "argocd.argoproj.io/sync-options", ""
                        ).split(",")
                        if "Delete=false" in options:
                            check(
                                not finalizers and prune is False,
                                manifest,
                                "Delete=false resource requires a retained Application",
                            )
                        if not finalizers:
                            check(
                                "Delete=false" in options,
                                manifest,
                                "non-cascading resource must be protected from deletion",
                            )
                if finalizers or prune is not False:
                    check(object_count > 0, path, "Application source directory has no valid Kubernetes objects")
                seen.add(relative)

            bootstrap = yaml.safe_load((root / "bootstrap.yaml").read_text())
            bootstrapSource, _, _ = check_application(bootstrap, root / "bootstrap.yaml", allow_retained=False)
            for marker in ("helm", "kustomize", "jsonnet", "plugin"):
                check(marker not in bootstrapSource, root / "bootstrap.yaml", f"unsupported source renderer {marker}")
            bootstrapDirectory = bootstrapSource.get("directory") or {}
            check(isinstance(bootstrapDirectory, dict), root / "bootstrap.yaml", "bootstrap source.directory must be a mapping")
            check(set(bootstrapDirectory) <= {"recurse"}, root / "bootstrap.yaml", "bootstrap source.directory has unsupported options")
            check(
                "recurse" not in bootstrapDirectory or isinstance(bootstrapDirectory["recurse"], bool),
                root / "bootstrap.yaml",
                "bootstrap source.directory.recurse must be boolean",
            )
            check(
                bootstrapDirectory.get("recurse", False) is False,
                root / "bootstrap.yaml",
                "bootstrap Application source must be nonrecursive",
            )
            check(bootstrap["spec"]["source"]["path"] == expected_prefix + "apps", root / "bootstrap.yaml", "bootstrap must reconcile the apps directory")
            check(bootstrap["spec"]["source"]["repoURL"] == expected_repository, root / "bootstrap.yaml", "unexpected repository")
            check(bootstrap["spec"]["source"]["targetRevision"] == expected_revision, root / "bootstrap.yaml", "unexpected revision")
            covered = {path.name for path in root.iterdir() if path.is_dir() and path.name != "apps"}
            check(seen == covered, root, f"unreferenced directories: {sorted(covered - seen)}")
            print(f"checked {len(files)} generated Argo applications")
            PY
            touch $out
          '';
    };
}
