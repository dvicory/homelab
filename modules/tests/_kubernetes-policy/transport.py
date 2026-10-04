"""Original-resource/context transport and fail-closed native Test report plumbing."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import shutil
import subprocess

import yaml

Loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
Dumper = getattr(yaml, "CSafeDumper", yaml.SafeDumper)
Loader.add_constructor("tag:yaml.org,2002:value", Loader.construct_scalar)
SOURCE = Path(__file__).parent
FAMILIES = ("transport", "gitops", "edge-identity", "workloads")
VARIANTS = ("canonical",) + tuple(
    f"{identity}-{seerr}-{mode}"
    for identity in ("initial", "provisioning", "normal")
    for seerr in ("initial", "ready") for mode in ("direct", "trustedEdges")
)
DEFAULT_VARIANT = "normal-ready-trustedEdges"
ANCHOR = "v1/ConfigMap/verification/verification-bundle"


def load(path):
    return yaml.load(Path(path).read_text(), Loader=Loader)


def dump(path, value):
    Path(path).write_text(yaml.dump(value, Dumper=Dumper, sort_keys=False, width=120))


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
                for index, obj in enumerate(yaml.load_all(content, Loader=Loader)):
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
    return {"apiVersion": "v1", "kind": "Namespace",
            "metadata": {"name": "policy-facts", "annotations": data}}


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
    (output / "resource.json").write_text(json.dumps(
        {"apiVersion": "v1", "kind": "ConfigMap",
         "metadata": {"name": "verification-bundle", "namespace": "verification"}, "bundle": context},
        separators=(",", ":"), allow_nan=False) + "\n")
    # Actual ordinary parameter resources, never fields injected into production objects.
    with (output / "policy-facts.yaml").open("w") as stream:
        yaml.dump_all([{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "verification"}},
                       facts_resource(expected)], stream, Dumper=Dumper, sort_keys=False)
    # Native discovery consumes unchanged production CRDs, not synthesized schemas.
    crds = [entry["object"] for entry in resources
            if entry["object"].get("kind") == "CustomResourceDefinition"]
    with (output / "crds.yaml").open("w") as stream:
        yaml.dump_all(crds, stream, Dumper=Dumper, sort_keys=False)
    namespaces = {obj["metadata"]["name"] for obj in (entry["object"] for entry in resources)
                  if obj.get("apiVersion") == "v1" and obj.get("kind") == "Namespace"}
    required = {entry["object"].get("metadata", {}).get("namespace") or "default" for entry in resources}
    dump(output / "native-discovery.yaml", {
        "apiVersion": "cli.kyverno.io/v1alpha1", "kind": "ClusterResource",
        "metadata": {"name": "original-crd-discovery"},
        "spec": {"crds": [str((output / "crds.yaml").resolve())],
                 "resources": [{"apiVersion": "v1", "kind": "Namespace",
                                "metadata": {"name": name, "labels": {
                                    "verification.homelab/context": "fixture-only",
                                    "kubernetes.io/metadata.name": name}}}
                               for name in sorted(required - namespaces)]}})


def identity(obj):
    meta = obj.get("metadata", {})
    return "/".join((obj["apiVersion"], obj["kind"], meta.get("namespace", ""), meta["name"]))


def resource_spec(ident):
    api, kind, namespace, name = ident.rsplit("/", 3)
    group, _, version = api.rpartition("/")
    return {"group": group, "version": version, "kind": kind, **({"namespace": namespace} if namespace else {}),
            "name": name}


def yq_eval(yq, expression, value, fmt="json"):
    result = subprocess.run([yq, "eval", f"--input-format={fmt}", f"--output-format={fmt}", expression],
                            input=json.dumps(value) if fmt == "json" else value,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout) if fmt == "json" else result.stdout


def rule_names(declaration):
    # Classification only documents possible future admission use; nothing here installs policies.
    return declaration["rules"]["admission-candidates"] + declaration["rules"]["repository-only"]


def applicability(declaration, phase):
    # The genuine complete-population positive: every rule × original identity that must report Pass.
    table = {ident: list(rules) for ident, rules in declaration["positive"]["applies"].items()}
    for block in declaration["positive"].get("when", []):
        if all(phase[key] in values for key, values in block["if"].items()):
            for ident, rules in block["applies"].items():
                table[ident] = table.get(ident, []) + rules
    return table


def expectations(declaration, scenario, table, target):
    """Declared fails plus Pass for every other in-scope applicable rule × identity.

    A single-object scenario asserts every rule that applies to its target. A population scenario
    asserts the rules that apply to the anchor, every rule (scope: population) or exactly `rules`.
    """
    table = dict(table)
    applies = scenario.get("applies", {})
    table.update({target: applies} if isinstance(applies, list) else applies)
    if target is not None and target not in table:
        raise ValueError(f"No genuine or declared applicability for {target}: {scenario['name']}")
    population = [target] if target is not None else list(table)
    fails = [(rule, ident) for entry in scenario.get("fail", [])
             for rule, ident in (entry.items() if isinstance(entry, dict) else [(entry, target or ANCHOR)])]
    if "rules" in scenario:
        scope = set(scenario["rules"])
    elif target is None and scenario.get("scope") == "population":
        scope = set(rule_names(declaration))
    else:
        scope = set(table.get(target or ANCHOR, []))
    # A rule declared to fail is in scope, so its other applicable identities must still pass.
    scope |= {rule for rule, _ in fails}
    outcomes = {(rule, ident): "pass" for ident in population for rule in table[ident] if rule in scope}
    outcomes.update({fail: "fail" for fail in fails})
    return outcomes


def native_results(policy, outcomes, order):
    # Uniform rules report every trigger (resources omitted); mixed rules select exact identities.
    results = []
    for rule in sorted({rule for rule, _ in outcomes}, key=lambda rule: (rule not in order, order.index(rule) if rule in order else rule)):
        wanted = sorted((ident, value) for (name, ident), value in outcomes.items() if name == rule)
        values = sorted({value for _, value in wanted})
        for value in values:
            results.append({"policy": policy, "rule": rule, **({"resources": []} if len(values) > 1 else {}),
                            "resourceSpecs": [resource_spec(ident) for ident, v in wanted if v == value],
                            "result": value})
    return results


def generate(args):
    """Materialize native Tests from the family declarations in fixtures/<family>.yaml.

    `positive.applies` (plus phase-conditional `when` blocks) is the explicit, hand-reviewed rule ×
    identity table that every genuine complete-population positive must report as Pass. Scenario keys:
      variant       render to use; default normal-ready-trustedEdges
      base          identity of a genuine object in that render; its mutated copy is the only resource
      object        synthetic object (a name under `objects`, or inline) with no genuine counterpart
      mutate        yq applied to base/object or, without either, to the complete-population anchor
      fail          rules that must Fail on the target; {rule: identity} for another resource
      applies       applicability for identities the positive does not list; a list means the target
      scope, rules  population assertion scope; see expectations()
      reject        expected fail-closed gate rejection category
      family, params, policyMutate, test   other family's policy, no parameters, policy copy, raw Test fields
    """
    inputs, yq = Path(args.inputs), args.yq
    policies = inputs / "policies"
    declarations = {family: load(policies / "fixtures" / f"{family}.yaml") for family in FAMILIES}
    bundles, registry = {}, []

    def objects(variant):
        if variant not in bundles:
            bundle = json.loads((inputs / variant / "resource.json").read_text())["bundle"]
            bundles[variant] = [[entry["object"] for entry in bundle[key]] for key in ("resources", "bootstrap")]
        return bundles[variant]

    def phase(variant):
        cluster = json.loads((inputs / variant / "expected.json").read_text())["cluster"]
        services = cluster["settings"]["kubernetes"]["services"]
        return {"identity": services["identity"]["phase"], "seerr": services["seerr"]["phase"],
                "mode": cluster["ingress"]["mode"]}

    def base_object(variant, ident):
        for population in objects(variant):
            found = [obj for obj in population if identity(obj) == ident]
            if len(found) > 1:
                raise ValueError(f"Ambiguous genuine base {ident} in {variant}")
            if found:
                return json.loads(json.dumps(found[0]))
        raise ValueError(f"Missing genuine base {ident} in {variant}")

    for family, declaration in declarations.items():
        positives = [{"name": declaration["positive"]["name"].format(variant=variant), "variant": variant,
                      "scope": "population"} for variant in VARIANTS]
        (policies / "fixtures" / family).mkdir()
        if "values" in declaration:
            dump(policies / "fixtures" / family / "values.yaml", declaration["values"])
        for scenario in positives + declaration["scenarios"]:
            variant = scenario.get("variant", DEFAULT_VARIANT)
            owner = declarations[scenario.get("family", family)]
            directory = policies / "fixtures" / family / scenario["name"]
            directory.mkdir(parents=True)
            target = None
            if "base" in scenario or "object" in scenario:
                if "base" in scenario:
                    obj = base_object(variant, scenario["base"])
                elif isinstance(scenario["object"], str):
                    # Synthetic objects have no genuine counterpart, so they declare their own applicability.
                    obj = owner["objects"][scenario["object"]]["object"]
                    scenario = {"applies": owner["objects"][scenario["object"]]["applies"], **scenario}
                else:
                    obj = scenario["object"]
                if "mutate" in scenario:
                    obj = yq_eval(yq, scenario["mutate"], obj)
                target = identity(obj)
                dump(directory / "resources.yaml", obj)
            elif "mutate" in scenario:
                (directory / "mutate.yq").write_text(scenario["mutate"] + "\n")
            outcomes = expectations(owner, scenario, applicability(owner, phase(variant)), target)
            policy = f"../../../{owner['policyFile']}"
            if "policyMutate" in scenario:
                (directory / "policy.yaml").write_text(
                    yq_eval(yq, scenario["policyMutate"], (policies / owner["policyFile"]).read_text(), "yaml"))
                policy = "policy.yaml"
            annotations = {"verification.homelab/variant": variant}
            if "reject" in scenario:
                annotations.update({"verification.homelab/expect-gate": "reject",
                                    "verification.homelab/rejection-category": scenario["reject"]})
            test = {"apiVersion": "cli.kyverno.io/v1alpha1", "kind": "Test",
                    "metadata": {"name": scenario["name"], "annotations": annotations},
                    "policies": [policy], "resources": ["resources.yaml"],
                    "paramResources": ["policy-facts.yaml"] if scenario.get("params", True) else [],
                    **owner.get("test", {}),
                    "results": native_results(owner["policy"], outcomes, rule_names(owner)),
                    **scenario.get("test", {})}
            dump(directory / "kyverno-test.yaml", test)
            registry.append({"directory": f"fixtures/{family}/{scenario['name']}", "name": scenario["name"],
                             "variant": variant, **({"expectGate": "reject", "rejectionCategory": scenario["reject"]}
                                                    if "reject" in scenario else {})})
    (policies / "scenarios.json").write_text(json.dumps({"scenarios": registry}, indent=1) + "\n")


def policy_inventory(policies):
    for family in FAMILIES:
        declaration = load(policies / "fixtures" / f"{family}.yaml")
        policy = load(policies / declaration["policyFile"])
        actual = [rule["name"] for rule in policy["spec"]["rules"]]
        declared = rule_names(declaration)
        if not declared or len(declared) != len(set(declared)) or len(actual) != len(set(actual)) or set(actual) != set(declared):
            raise ValueError(f"Missing/unknown/duplicate required native rules: {family}")
        if policy["metadata"]["name"] != declaration["policy"]:
            raise ValueError(f"Wrong required native policy identity: {family}")


def prepare_tests(inputs, output):
    policies = inputs / "policies"
    policy_inventory(policies)
    inventory = json.loads((policies / "scenarios.json").read_text())
    declared = {scenario["directory"] + "/kyverno-test.yaml" for scenario in inventory["scenarios"]}
    discovered = {path.relative_to(policies).as_posix() for path in policies.rglob("kyverno-test.yaml")}
    if declared != discovered or len(declared) != len(inventory["scenarios"]):
        raise ValueError("Missing/unknown/duplicate declared native scenarios")
    shutil.copytree(policies, output, copy_function=shutil.copyfile)
    for directory, _, _ in os.walk(output):
        Path(directory).chmod(0o755)
    if not inventory["scenarios"] or any(scenario["variant"] not in VARIANTS for scenario in inventory["scenarios"]):
        raise ValueError("Empty/unknown-phase declared native scenario inventory")
    return inventory


def materialize(inputs, contexts, output, scenario, yq):
    directory = output / scenario["directory"]
    test = load(directory / "kyverno-test.yaml")
    if test["metadata"]["name"] != scenario["name"]:
        raise ValueError(f"Changed declared native scenario: {scenario['name']}")
    variant = contexts / scenario["variant"]
    objects = None
    if not (directory / "resources.yaml").exists():
        anchor = directory / "anchor.json"
        shutil.copyfile(variant / "resource.json", anchor)
        if (directory / "mutate.yq").exists():
            subprocess.run([yq, "eval", "--input-format=json", "--output-format=json", "--indent=0",
                            "--inplace", "--from-file", str(directory / "mutate.yq"), str(anchor)], check=True)
        context = json.loads(anchor.read_text())
        objects = [entry["object"] for entry in context["bundle"]["resources"]]
        # The independent seed project is not otherwise in the environment; the root Application already is.
        objects.extend(entry["object"] for entry in context["bundle"]["bootstrap"]
                       if entry["object"].get("kind") == "AppProject")
        objects.append(context)
        with (directory / "resources.yaml").open("w") as stream:
            # JSON documents are valid YAML; no shared-object anchor can be deleted by a mutation.
            for obj in objects:
                stream.write("---\n")
                stream.write(json.dumps(obj, separators=(",", ":"), allow_nan=False) + "\n")
        anchor.unlink()
    if test.get("paramResources"):
        shutil.copyfile(variant / "policy-facts.yaml", directory / "policy-facts.yaml")
        test["paramResources"] = ["policy-facts.yaml"]
    if test.get("clusterResources"):
        if objects is None:
            objects = [obj for path in test.get("resources", [])
                       if (directory / path).exists()
                       for obj in yaml.load_all((directory / path).read_text(), Loader=Loader) if obj is not None]
        parameters = [obj for path in test.get("paramResources", [])
                      if (directory / path).exists()
                      for obj in yaml.load_all((directory / path).read_text(), Loader=Loader) if obj is not None]
        declared = {obj["metadata"]["name"] for obj in objects + parameters
                    if obj.get("apiVersion") == "v1" and obj.get("kind") == "Namespace"}
        required = {obj.get("metadata", {}).get("namespace") or "default" for obj in objects}
        bindings = []
        for index, path in enumerate(test["clusterResources"]):
            if not (directory / path).exists():
                bindings.append(path)
                continue
            api_context = load(directory / path)
            contextual = api_context["spec"].get("resources", [])
            declared.update(obj["metadata"]["name"] for obj in contextual
                            if obj.get("apiVersion") == "v1" and obj.get("kind") == "Namespace")
            contextual.extend({"apiVersion": "v1", "kind": "Namespace",
                               "metadata": {"name": name, "labels": {
                                   "verification.homelab/context": "fixture-only",
                                   "kubernetes.io/metadata.name": name}}}
                              for name in sorted(required - declared))
            api_context["spec"]["resources"] = contextual
            local_path = f"api-context-{index}.yaml"
            dump(directory / local_path, api_context)
            bindings.append(local_path)
        test["clusterResources"] = bindings
    if test.get("paramResources") or test.get("clusterResources"):
        dump(directory / "kyverno-test.yaml", test)


class NativeRejection(ValueError):
    def __init__(self, category, detail):
        self.category = category
        super().__init__(detail)


def native_rows(text):
    decoder = json.JSONDecoder()
    rows, cursor = [], 0
    while (index := text.find("[", cursor)) >= 0:
        cursor = index + 1
        try:
            value, end = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        cursor = index + end
        if isinstance(value, list) and value and all(isinstance(row, dict) and "POLICY" in row for row in value):
            rows.extend(value)
    if not rows:
        raise NativeRejection("incomplete-coverage", "Missing/empty native Kyverno JSON report")
    return rows


def native_outcomes(results):
    # Go nil resources reports every trigger; [] selects only resourceSpecs.
    # Positive scans must report all. Mixed semantic negatives may use native per-object oracles.
    if results and all(result["result"] == "pass" for result in results):
        if any("resources" in result for result in results):
            raise ValueError("Passing native scans must omit per-result resource selection")
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


def execute(directory, scenario, kyverno, report, discovery, contexts, tests):
    test = load(directory / "kyverno-test.yaml")
    if not test.get("results"):
        raise NativeRejection("incomplete-coverage", "Missing/empty required native target outcomes")
    for field, category in (("policies", "missing-policy"), ("resources", "missing-resource"),
                            ("paramResources", "missing-parameters"), ("clusterResources", "missing-api-context"),
                            ("variables", "missing-values")):
        paths = test.get(field, [])
        paths = [paths] if isinstance(paths, str) else paths
        if any(not (directory / path).exists() for path in paths):
            raise NativeRejection(category, f"Missing declared native input: {field}")
    first = load(tests / discovery["directory"] / "kyverno-test.yaml")
    variant = contexts / scenario["variant"]
    # The real transport rule matches only this actual complete-population anchor.
    # Registering its raw CRDs both as standalone unstructured inputs and typed
    # discovery definitions panics in 1.19; the target still receives every original.
    first["resources"] = [str((variant / "resource.json").resolve())]
    first["clusterResources"] = [str((variant / "native-discovery.yaml").resolve())]
    first["paramResources"] = [str((variant / "policy-facts.yaml").resolve())]
    # ponytail: 1.19 Test loads CRDs after resources; remove the genuine transport
    # positive prelude when upstream initializes CRD discovery before resource loading.
    for document, base in ((first, tests / discovery["directory"]), (test, directory)):
        for field in ("policies", "resources", "paramResources", "clusterResources", "targetResources"):
            if document.get(field):
                document[field] = [str((base / path).resolve()) for path in document[field]]
        for field in ("variables", "context", "userinfo"):
            if document.get(field):
                document[field] = os.path.relpath((base / document[field]).resolve(), directory.resolve())
    with (directory / "native-test.yaml").open("w") as stream:
        yaml.dump_all([first, test], stream, Dumper=Dumper, sort_keys=False)
    result = subprocess.run([kyverno, "test", str(directory), "--file-name", "native-test.yaml",
                             "--require-tests", "--remove-color", "--detailed-results",
                             "--output-format", "json"], text=True, capture_output=True)
    report.write_text(result.stdout + result.stderr)
    rows = native_rows(result.stdout)
    # Pinned CLI exposes compiler/CEL failures as diagnostic Message strings, sometimes with RESULT Pass.
    # Interpret those diagnostics here; counterfactual contracts assert only the typed category below.
    diagnostics = ("resulted in error:", "fails to compile:", "fails to evaluate:",
                   "compilation failed:", "error in parameterized resource:")
    if any(marker in row["Message"].lower() for row in rows for marker in diagnostics):
        raise NativeRejection("native-evaluation-error", f"Native evaluation/compiler/parameter error: {scenario['name']}")
    # REASON is the CLI's structured enum/status-template field, not a fixture wording expectation.
    statuses = [row["REASON"].partition(", got ")[2] for row in rows]
    if "error" in statuses or any(row["REASON"] in ("Invalid Policy", "Error") for row in rows):
        raise NativeRejection("native-evaluation-error", f"Native error status: {scenario['name']}")
    expected = expected_identities(native_outcomes(first["results"])) + expected_identities(native_outcomes(test["results"]))
    # Native Test emits Excluded/Pass rows for nonapplicable identities omitted from expectations.
    # Ignore only that exact combination; required exclusions, all errors and applicable extras still reject.
    rows = [row for row in rows if not (
        row["RESULT"] == "Pass" and row["REASON"] == "Excluded" and
        (row["POLICY"], row["RULE"], row["RESOURCE"]) not in expected)]
    if "skip" in statuses or any(row["REASON"] in ("Excluded", "Not found", "Skip") for row in rows):
        raise NativeRejection("scope-not-exercised", f"Native skipped/unmatched scope: {scenario['name']}")
    actual = Counter((r["POLICY"], r["RULE"], r["RESOURCE"]) for r in rows)
    if actual != expected:
        raise NativeRejection("incomplete-coverage", f"Missing/duplicate/unknown native outcomes: {scenario['name']}")
    if result.returncode or any(row["RESULT"] != "Pass" for row in rows):
        raise NativeRejection("native-test-failure", f"Native Kyverno Test failed: {scenario['name']}; see {report}")


def part_scenarios(inventory, family, shard, shards):
    """The scenarios one policy derivation owns: one family, optionally split round-robin."""
    if family not in FAMILIES or not 1 <= shard <= shards:
        raise ValueError(f"Unknown native scenario part: {family} {shard}/{shards}")
    owned = [scenario for scenario in inventory["scenarios"]
             if scenario["directory"].startswith(f"fixtures/{family}/")]
    return [scenario for index, scenario in enumerate(owned) if index % shards == shard - 1]


def check_schemas(inputs, output, args):
    for variant in VARIANTS:
        original = inputs / variant
        subprocess.run([args.schema_runner, str(original / "manifests"), args.schemas,
                        str(output / f"schema--{variant}.json")], check=True)
        crd_provenance(argparse.Namespace(manifests=original / "manifests", reference=args.schema_manifests))


def run(args):
    inputs, output = Path(args.inputs), Path(args.output)
    output.mkdir(parents=True)
    contexts = output / "contexts"
    tests = output / "tests"
    inventory = prepare_tests(inputs, tests)
    if args.family is None:
        # Whole gate in one process: every scenario plus the schema prerequisites.
        selected = inventory["scenarios"]
        check_schemas(inputs, output, args)
    else:
        # One part of the gate; `aggregate` checks schemas and complete coverage once.
        selected = part_scenarios(inventory, args.family, args.shard, args.shards)
        if not selected:
            raise ValueError(f"Empty native scenario part: {args.family} {args.shard}/{args.shards}")
    selected_directories = {scenario["directory"] for scenario in selected}
    executed = []
    for variant in VARIANTS:
        if not any(scenario["variant"] == variant for scenario in selected):
            continue
        original = inputs / variant
        bundle(argparse.Namespace(manifests=original / "manifests", bootstrap=original / "bootstrap",
                                  expected=original / "expected.json", variant=variant, output=contexts / variant))
        discoveries = [scenario for scenario in inventory["scenarios"]
                       if scenario["variant"] == variant and
                       scenario["directory"].startswith("fixtures/transport/transport-positive-")]
        if len(discoveries) != 1:
            raise ValueError(f"Missing/ambiguous independent native transport positive: {variant}")
        discovery = discoveries[0]
        materialize(inputs, contexts, tests, discovery, args.yq)
        for scenario in inventory["scenarios"]:
            if scenario["variant"] != variant or scenario["directory"] not in selected_directories:
                continue
            materialize(inputs, contexts, tests, scenario, args.yq)
            report_name = scenario["directory"].replace("/", "--")
            report = output / f"{report_name}.json"
            rejected = None
            try:
                execute(tests / scenario["directory"], scenario, args.kyverno, report,
                        discovery, contexts, tests)
            except NativeRejection as error:
                rejected = NativeRejection(error.category,
                                           f"{error}; scenario {scenario['directory']}; native report {report}")
            if scenario.get("expectGate", "pass") == "reject":
                if rejected is None:
                    raise ValueError(f"Fail-open required native counterfactual: {scenario['directory']}; report {report}")
                if rejected.category != scenario["rejectionCategory"]:
                    raise ValueError(f"Counterfactual rejection category mismatch: {scenario['directory']}: {rejected.category}; report {report}")
                (output / f"{report_name}.rejected.json").write_text(json.dumps(
                    {"scenario": scenario["directory"], "name": scenario["name"],
                     "report": str(report) if report.exists() else None, "category": rejected.category}) + "\n")
            elif rejected:
                raise rejected
            executed.append(scenario["directory"])
    if sorted(executed) != sorted(selected_directories):
        raise ValueError("Selected native scenarios were not all executed")
    shutil.copyfile(inputs / "policies" / "scenarios.json", output / "required-scenarios.json")
    (output / "executed.json").write_text(json.dumps(
        {"family": args.family, "shard": args.shard, "shards": args.shards,
         "scenarios": sorted(executed)}, indent=1) + "\n")


def aggregate(args):
    """Require every declared scenario to pass in exactly one part, and check schemas once."""
    inputs, output = Path(args.inputs), Path(args.output)
    output.mkdir(parents=True)
    declared = json.loads((inputs / "policies" / "scenarios.json").read_text())
    required = Counter(scenario["directory"] for scenario in declared["scenarios"])
    if not required or any(count != 1 for count in required.values()):
        raise ValueError("Empty or duplicate declared native scenario inventory")
    executed, parts = Counter(), set()
    for report in map(Path, args.parts):
        result = json.loads((report / "executed.json").read_text())
        if json.loads((report / "required-scenarios.json").read_text()) != declared:
            raise ValueError(f"Native policy part used another scenario inventory: {report}")
        part = (result["family"], result["shard"], result["shards"])
        owned = {scenario["directory"] for scenario in part_scenarios(declared, *part)}
        if part in parts or set(result["scenarios"]) != owned:
            raise ValueError(f"Duplicate or incomplete native policy part: {report}")
        parts.add(part)
        executed.update(result["scenarios"])
    if executed != required:
        raise ValueError("Native policy parts do not cover every declared scenario exactly once")
    check_schemas(inputs, output, args)
    shutil.copyfile(inputs / "policies" / "scenarios.json", output / "required-scenarios.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("bundle")
    for key in ("manifests", "bootstrap", "expected", "variant", "output"):
        pack.add_argument(f"--{key}", required=True)
    bind = commands.add_parser("bind-crds")
    for key in ("manifests", "reference"):
        bind.add_argument(f"--{key}", required=True)
    fixtures = commands.add_parser("generate")
    for key in ("inputs", "yq"):
        fixtures.add_argument(f"--{key}", required=True)
    runner = commands.add_parser("run")
    for key in ("inputs", "output", "kyverno", "yq", "schema-runner", "schemas", "schema-manifests"):
        runner.add_argument(f"--{key}", required=True)
    runner.add_argument("--family", choices=FAMILIES)
    runner.add_argument("--shard", type=int, default=1)
    runner.add_argument("--shards", type=int, default=1)
    combine = commands.add_parser("aggregate")
    for key in ("inputs", "output", "schema-runner", "schemas", "schema-manifests"):
        combine.add_argument(f"--{key}", required=True)
    combine.add_argument("parts", nargs="+")
    args = parser.parse_args()
    {"bundle": bundle, "bind-crds": crd_provenance, "generate": generate, "run": run,
     "aggregate": aggregate}[args.command](args)


if __name__ == "__main__":
    main()
