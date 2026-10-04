"""Negative cases against the real offline gate; each must fail for its boundary."""

import argparse
import copy
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

import yaml
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", yaml.SafeLoader.construct_scalar)



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifests", type=Path, required=True)
    parser.add_argument("--schemas", type=Path, required=True)
    parser.add_argument("--converter", type=Path, required=True)
    parser.add_argument("--kubeconform", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    args = parser.parse_args()

    def load(relative):
        # Mutation inputs are copied, never written into the canonical corpus.
        with (args.manifests / relative).open() as stream:
            return yaml.safe_load(stream)

    def rejected(name, content, boundary, *, missing=None, skipped=False, collision=False):
        with tempfile.TemporaryDirectory(prefix="schema-mutation-") as temporary:
            work = Path(temporary)
            manifests = work / "manifests"
            manifests.mkdir()
            if content is not None:
                (manifests / "case.yaml").write_text(content if isinstance(content, str) else yaml.safe_dump(content))
            schemas = args.schemas
            tool = args.kubeconform
            if missing:
                schemas = work / "schemas"
                shutil.copytree(args.schemas, schemas)
                schemas.chmod(0o700)
                (schemas / missing).unlink()
            if skipped:
                # Exercise the real tool's -skip behavior, not a synthetic report.
                tool = work / "skip-deployment"
                tool.write_text("#!/bin/sh\nexec " + shlex.quote(str(args.kubeconform)) + ' -skip Deployment "$@"\n')
                tool.chmod(0o700)
            if collision:
                (manifests / "duplicate.yaml").write_text(yaml.safe_dump(content))
                schemas = work / "schemas"
                command = [sys.executable, str(args.helper), "derive", "--converter", str(args.converter)]
            else:
                command = [sys.executable, str(args.helper), "validate", "--kubeconform", str(tool),
                           "--report", str(work / "report.json")]
            command += ["--manifests", str(manifests), "--schemas", str(schemas)]
            result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            output = result.stdout + result.stderr
            if result.returncode == 0 or boundary not in output:
                raise AssertionError(f"{name}: expected rejection containing {boundary!r}, "
                                     f"exit={result.returncode}\n{output}")
            print(f"rejected {name}: {boundary}")

    deployment = load("identity/Deployment-kanidm.yaml")
    broken = copy.deepcopy(deployment)
    broken["spec"]["template"]["spec"]["securityContext"]["runAsNonRooot"] = True
    rejected("built-in nested unknown field", broken, "runAsNonRooot")
    route = load("gateway/HTTPRoute-idm.yaml")
    broken = copy.deepcopy(route)
    broken["spec"]["rules"][0]["backendRefs"][0]["porrt"] = 443
    rejected("custom nested unknown field", broken, "porrt")
    crd = load("gateway-crds/CustomResourceDefinition-httproutes-gateway-networking-k8s-io.yaml")
    broken = copy.deepcopy(crd)
    del broken["spec"]["group"]
    rejected("CRD envelope required group", broken, "group")
    custom = json.loads((args.schemas / "custom-gvks.json").read_text())
    route_schema = next(entry["schema"] for entry in custom if entry["kind"] == "HTTPRoute"
                        and entry["apiVersion"] == route["apiVersion"])
    rejected("missing served custom schema", route, "missing served custom schema", missing=route_schema)
    rejected("duplicate original YAML key", "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: first\n  name: second\n", "duplicate YAML key")
    rejected("empty directory", None, "zero effective deployment documents")
    rejected("empty YAML", "", "zero effective deployment documents")
    rejected("comment-only YAML", "# no resources\n---\n# still empty\n", "zero effective deployment documents")
    rejected("empty List selection", {"apiVersion": "v1", "kind": "List", "items": []}, "zero effective deployment documents")
    rejected("all-skipped actual tool", deployment, "statusSkipped", skipped=True)
    rejected("colliding served schema output", crd, "colliding served-GVK schema", collision=True)

    # Representative generic field classes permit removing type-only assertions,
    # not metadata, positive limits, nonempty names or authority/ownership rules.
    application = load("apps/Application-argocd.yaml")
    project = load("apps/AppProject-prod-home.yaml")
    cases = [
        ("Application destination mapping", application, ("spec", "destination"), []),
        ("Application syncPolicy mapping", application, ("spec", "syncPolicy"), []),
        ("Application syncOptions list", application, ("spec", "syncPolicy", "syncOptions"), {}),
        ("Application automated mapping", application, ("spec", "syncPolicy", "automated"), []),
        ("Application source mapping", application, ("spec", "source"), []),
        ("Application directory mapping", application, ("spec", "source", "directory"), []),
        ("Application recurse boolean", application, ("spec", "source", "directory", "recurse"), "true"),
        ("Application retry mapping", application, ("spec", "syncPolicy", "retry"), []),
        ("Application retry integer", application, ("spec", "syncPolicy", "retry", "limit"), "5"),
        ("AppProject spec mapping", project, ("spec",), []),
        ("AppProject destinations list", project, ("spec", "destinations"), {}),
        ("AppProject destination entry mapping", project, ("spec", "destinations", 0), []),
        ("AppProject cluster whitelist list", project, ("spec", "clusterResourceWhitelist"), {}),
        ("AppProject cluster entry mapping", project, ("spec", "clusterResourceWhitelist", 0), []),
    ]
    for name, original, path, value in cases:
        broken = copy.deepcopy(original)
        parent = broken
        for part in path[:-1]:
            if isinstance(parent, dict):
                parent = parent.setdefault(part, {})
            else:
                parent = parent[part]
        parent[path[-1]] = value
        rejected(name, broken, "statusInvalid")


if __name__ == "__main__":
    main()
