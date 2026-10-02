"""Original-resource/context transport and fail-closed native Test report plumbing."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import shutil
import subprocess

import yaml

yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", yaml.SafeLoader.construct_scalar)
SOURCE = Path(__file__).parent
FAMILIES = ("transport", "gitops", "edge-identity", "workloads")
VARIANTS = ("canonical",) + tuple(
    f"{identity}-{seerr}-{mode}"
    for identity in ("initial", "provisioning", "normal")
    for seerr in ("initial", "ready") for mode in ("direct", "trustedEdges")
)


def load(path):
    return yaml.safe_load(Path(path).read_text())


def dump(path, value):
    Path(path).write_text(yaml.safe_dump(value, sort_keys=False, width=120))


def original_documents(root):
    files, directories, resources, documents = [], [], [], []
    for directory, child_dirs, child_files in os.walk(root, followlinks=True):
        child_dirs.sort()
        directories.extend((Path(directory) / child).relative_to(root).as_posix() for child in child_dirs)
        for child in sorted(child_files):
            path = Path(directory) / child
            relative, content = path.relative_to(root).as_posix(), path.read_text()
            files.append(relative)
            if path.suffix.lower() in (".yaml", ".yml", ".json"):
                for index, obj in enumerate(yaml.safe_load_all(content)):
                    documents.append({"file": relative, "document": index, "object": obj})
                    if obj is not None:
                        resources.append({"file": relative, "document": index, "content": content, "object": obj})
    return files, directories, resources, documents


def crd_provenance(args):
    # Definition equality binds the existing native schema corpus to its actual original inputs.
    def definitions(root):
        return [(r["file"], r["document"], r["object"]) for r in original_documents(Path(root))[2]
                if r["object"].get("kind") == "CustomResourceDefinition"]
    if definitions(args.manifests) != definitions(args.reference):
        raise ValueError("Variant CRD source definitions differ from the pinned canonical schema inputs")


def raw_string(value):
    return value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))


def facts_resource(expected):
    cluster, compute = expected["cluster"], expected["computeResources"]
    data = {key: raw_string(expected[key]) for key in
            ("repository", "revision", "prefix", "project", "destination", "appendNameWithEnv")}
    data.update({
        "jellyfinUid": raw_string(expected["retainedPaths"]["jellyfin-config"]["uid"]),
        "jellyfinGid": raw_string(expected["retainedPaths"]["jellyfin-config"]["gid"]),
        "sabnzbdUid": raw_string(expected["retainedPaths"]["sabnzbd"]["uid"]),
        "sabnzbdGid": raw_string(expected["retainedPaths"]["sabnzbd"]["gid"]),
        "mediaData": compute["mediaPaths"]["data"], "mediaLibrary": compute["mediaPaths"]["library"],
        "jellyfinNamespace": cluster["routes"]["jellyfin"]["namespace"],
        "jellyfinPort": raw_string(cluster["routes"]["jellyfin"]["port"]),
        "identityPhase": cluster["settings"]["kubernetes"]["services"]["identity"]["phase"],
        "seerrPhase": cluster["settings"]["kubernetes"]["services"]["seerr"]["phase"],
        "ingressMode": cluster["ingress"]["mode"],
        "trustedProxyCIDRs": raw_string(cluster["ingress"]["trustedProxyCIDRs"]),
        "nodePort": raw_string(cluster["ingress"]["nodePort"]),
        "identityKanidmGuestPath": compute["retainedPaths"]["identity-kanidm"]["guestPath"],
        "domain": expected["environment"]["domain"], "backupDomain": expected["environment"]["backupDomain"],
    })
    for name, route in cluster["routes"].items():
        data.update({f"route.{name}.{field}": raw_string(value) for field, value in route.items()})
    return {"apiVersion": "v1", "kind": "ConfigMap",
            "metadata": {"name": "policy-facts", "namespace": "verification"}, "data": data}


def bundle(args):
    output = Path(args.output)
    files, directories, resources, documents = original_documents(Path(args.manifests))
    bootstrap_files, _, bootstrap, bootstrap_documents = original_documents(Path(args.bootstrap))
    expected = json.loads(Path(args.expected).read_text())
    context = {"variant": args.variant, "files": files, "directories": directories,
               "resources": resources, "documents": documents, "bootstrap": bootstrap,
               "bootstrapFiles": bootstrap_files, "bootstrapDocuments": bootstrap_documents,
               "expected": expected, "builtinScopes": json.loads((SOURCE / "builtin-scopes.json").read_text())}
    output.mkdir(parents=True, exist_ok=True)
    dump(output / "resource.yaml", {"apiVersion": "v1", "kind": "ConfigMap",
                                  "metadata": {"name": "verification-bundle", "namespace": "verification"},
                                  "bundle": context})
    # Actual ordinary parameter resources, never fields injected into production objects.
    with (output / "policy-facts.yaml").open("w") as stream:
        yaml.safe_dump_all([{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "verification"}},
                            facts_resource(expected)], stream, sort_keys=False)


def policy_inventory(policies):
    for family in FAMILIES:
        mapping = json.loads((policies / f"{family}-map.json").read_text())
        policy = load(policies / mapping.get("policyFile", f"{family}.yaml"))
        actual = [rule["name"] for rule in policy["spec"]["rules"]]
        if not mapping["rules"] or len(actual) != len(set(actual)) or set(actual) != set(mapping["rules"]):
            raise ValueError(f"Missing/unknown/duplicate required native rules: {family}")
        if policy["metadata"]["name"] != mapping["policy"]:
            raise ValueError(f"Wrong required native policy identity: {family}")


def materialize(inputs, contexts, output, yq):
    policies = inputs / "policies"
    policy_inventory(policies)
    inventory = json.loads((policies / "scenario-inventory.json").read_text())
    declared = {scenario["directory"] + "/kyverno-test.yaml" for scenario in inventory["scenarios"]}
    discovered = {path.relative_to(policies).as_posix() for path in policies.rglob("kyverno-test.yaml")}
    if declared != discovered or len(declared) != len(inventory["scenarios"]):
        raise ValueError("Missing/unknown/duplicate independently required native scenarios")
    shutil.copytree(policies, output, copy_function=shutil.copyfile)
    for directory, _, _ in os.walk(output):
        Path(directory).chmod(0o755)
    if not inventory["scenarios"]:
        raise ValueError("Empty independent required native scenario inventory")
    for scenario in inventory["scenarios"]:
        source_test = load(policies / scenario["directory"] / "kyverno-test.yaml")
        annotations = source_test["metadata"].get("annotations", {})
        if annotations.get("verification.homelab/variant", "normal-ready-trustedEdges") != scenario["variant"]:
            raise ValueError(f"Changed required scenario phase: {scenario['name']}")
        directory = output / scenario["directory"]
        test = load(directory / "kyverno-test.yaml")
        if test["metadata"]["name"] != scenario["name"] or native_outcomes(test.get("results", [])) != scenario["outcomes"]:
            raise ValueError(f"Missing/changed required native scenario outcomes: {scenario['name']}")
        variant = contexts / scenario["variant"]
        if not (directory / "resources.yaml").exists():
            anchor = directory / "anchor.yaml"
            shutil.copyfile(variant / "resource.yaml", anchor)
            if (directory / "mutate.yq").exists():
                subprocess.run([yq, "eval", "--inplace", "--from-file", str(directory / "mutate.yq"), str(anchor)], check=True)
            context = load(anchor)
            objects = [entry["object"] for entry in context["bundle"]["resources"]]
            # The independent seed project is not otherwise in the environment; the root Application already is.
            objects.extend(entry["object"] for entry in context["bundle"]["bootstrap"]
                           if entry["object"].get("kind") == "AppProject")
            objects.append(context)
            with (directory / "resources.yaml").open("w") as stream:
                yaml.safe_dump_all(objects, stream, sort_keys=False)
            anchor.unlink()
        if test.get("paramResources"):
            shutil.copyfile(variant / "policy-facts.yaml", directory / "policy-facts.yaml")
            test["paramResources"] = ["policy-facts.yaml"]
            dump(directory / "kyverno-test.yaml", test)
    return inventory


def native_rows(text):
    decoder = json.JSONDecoder()
    for index, char in enumerate(text):
        if char != "[":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, list) and value and all(isinstance(row, dict) and "POLICY" in row for row in value):
            return value
    raise ValueError("Missing/empty native Kyverno JSON report")


def native_outcomes(results):
    outcomes = []
    for result in results:
        if result["result"] not in ("pass", "fail"):
            raise ValueError("Required native outcome cannot be skip/error")
        if not result.get("resourceSpecs"):
            raise ValueError("Required outcome lacks an explicit native resource identity")
        for resource in result["resourceSpecs"]:
            api = f"{resource['group']}/{resource['version']}" if resource.get("group") else resource["version"]
            outcomes.append([result["policy"], result["rule"], api, resource["kind"],
                             resource.get("namespace", ""), resource["name"], result["result"]])
    return sorted(outcomes)


def expected_identities(outcomes):
    return Counter((policy, rule, f"{api}/{kind}/{namespace}/{name}")
                   for policy, rule, api, kind, namespace, name, _ in outcomes)


def execute(directory, scenario, kyverno, report):
    result = subprocess.run([kyverno, "test", str(directory), "--require-tests", "--remove-color",
                             "--detailed-results", "--output-format", "json"], text=True, capture_output=True)
    report.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError(f"Native Kyverno Test failed: {scenario['name']}; see {report}")
    rows = native_rows(result.stdout)
    actual = Counter((r["POLICY"], r["RULE"], r["RESOURCE"]) for r in rows)
    if actual != expected_identities(scenario["outcomes"]):
        raise ValueError(f"Missing/duplicate/unknown required native outcomes: {scenario['name']}")
    if any(row["RESULT"] != "Pass" or row["REASON"] in ("Excluded", "Not found", "Invalid Policy", "Skip", "Error") for row in rows):
        raise ValueError(f"Skipped/error/unmatched required native outcome: {scenario['name']}")


def run(args):
    inputs, output = Path(args.inputs), Path(args.output)
    output.mkdir(parents=True)
    contexts = output / "contexts"
    for variant in VARIANTS:
        original = inputs / variant
        subprocess.run([args.schema_runner, str(original / "manifests"), args.schemas,
                        str(output / f"schema--{variant}.json")], check=True)
        crd_provenance(argparse.Namespace(manifests=original / "manifests", reference=args.schema_manifests))
        bundle(argparse.Namespace(manifests=original / "manifests", bootstrap=original / "bootstrap",
                                  expected=original / "expected.json", variant=variant, output=contexts / variant))
    tests = output / "tests"
    inventory = materialize(inputs, contexts, tests, args.yq)
    for scenario in inventory["scenarios"]:
        report_name = scenario["directory"].replace("/", "--")
        report = output / f"{report_name}.json"
        rejected = None
        try:
            execute(tests / scenario["directory"], scenario, args.kyverno, report)
        except ValueError as error:
            rejected = str(error)
        if scenario.get("expectGate", "pass") == "reject":
            if rejected is None:
                raise ValueError(f"Fail-open required native counterfactual: {scenario['name']}")
            evidence = rejected + "\n" + report.read_text()
            if scenario["rejectionMessage"].lower() not in evidence.lower():
                raise ValueError(f"Counterfactual rejected for an unintended reason: {scenario['name']}")
            (output / f"{report_name}.rejected").write_text(rejected + "\n")
        elif rejected:
            raise ValueError(rejected)
    (output / "required-scenarios.json").write_text(json.dumps(inventory, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("bundle")
    for key in ("manifests", "bootstrap", "expected", "variant", "output"):
        pack.add_argument(f"--{key}", required=True)
    bind = commands.add_parser("bind-crds")
    for key in ("manifests", "reference"):
        bind.add_argument(f"--{key}", required=True)
    runner = commands.add_parser("run")
    for key in ("inputs", "output", "kyverno", "yq", "schema-runner", "schemas", "schema-manifests"):
        runner.add_argument(f"--{key}", required=True)
    args = parser.parse_args()
    {"bundle": bundle, "bind-crds": crd_provenance, "run": run}[args.command](args)


if __name__ == "__main__":
    main()
