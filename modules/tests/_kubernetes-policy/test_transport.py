import argparse
from copy import deepcopy
import json
from pathlib import Path
import re
import shutil
from tempfile import TemporaryDirectory
import yaml

from transport import (
    NativeRejection, aggregate, batch_rows, dump, expected_identities, load, native_rows, run, validate_rows,
)


def check_loader():
    with TemporaryDirectory() as root:
        path = Path(root) / "fixture.yaml"
        for text in (
            "scenario: {fail: [must-remain], fail: [weaker]}\n",
            "scenario: {<<: {fail: [must-remain], fail: [weaker]}}\n",
            "scenario: {<<: [{fail: [must-remain], fail: [weaker]}]}\n",
            "scenario: {<<: {fail: [must-remain]}, <<: {fail: [weaker]}}\n",
        ):
            path.write_text(text)
            try:
                load(path)
            except ValueError:
                pass
            else:
                raise AssertionError("duplicate fixture key discarded a required failure")

        path.write_text(
            "scenario: {<<: &defaults {<<: {fail: [original], keep: retained}, fail: [selected]}}\n"
            "copy: *defaults\n"
        )
        selected = {"fail": ["selected"], "keep": "retained"}
        assert load(path) == {"scenario": selected, "copy": selected}
        path.write_text("scenario: {<<: {fail: [original]}, '<<': retained}\n")
        assert load(path)["scenario"] == {"fail": ["original"], "<<": "retained"}


def rejects(category, operation):
    try:
        operation()
    except NativeRejection as error:
        assert error.category == category, error
    else:
        raise AssertionError(f"accepted required {category} rejection")


def check_reports(root):
    # Use actual packaged CLI reports, not a mock executable echoing its inputs.
    reports = sorted(Path(root).glob("batch--*.expected.json"))
    assert reports, "no native batch reports were exercised"
    for binding in reports:
        provenance = json.loads(binding.read_text())
        expected = {entry["path"]: expected_identities(entry["outcomes"]) for entry in provenance}
        assert len(expected) == len(provenance), "duplicate native Test paths in expected evidence"
        for entry in provenance:
            # The file, not the buggy legacy banner field, carries the declared logical name.
            assert load(entry["path"])["metadata"]["name"] == entry["declaredName"]
        text = binding.with_name(binding.name.replace(".expected.json", ".json")).read_text()
        actual = batch_rows(text, expected)
        headers = list(re.finditer(r"^Loading test (.*?) \( (.*?) \) \.\.\.\s*$", text, re.MULTILINE))
        sections = [text[header.start():headers[index + 1].start() if index + 1 < len(headers) else len(text)]
                    for index, header in enumerate(headers)]
        assert len(sections) >= 2, "batch lacks its genuine discovery and target"
        # Whole sections are attributable independently of non-prelude ordering.
        assert batch_rows(sections[0] + "".join(reversed(sections[1:])), expected) == actual
        rejects("incomplete-coverage", lambda: batch_rows("".join(sections[1:] + sections[:1]), expected))
        rejects("incomplete-coverage", lambda: batch_rows("".join(sections[1:]), expected))
        rejects("incomplete-coverage", lambda: batch_rows("".join(sections[:-1]), expected))
        first, second = headers[:2]
        # Prefer different targets, so swapping only their native paths cannot
        # be rejected merely because the discovery prelude moved.
        pair = next(((a, b) for index, a in enumerate(headers[1:]) for b in headers[index + 2:]
                     if expected[a[2]] != expected[b[2]]), None)
        if pair is not None:
            first, second = pair
        replacements = {}
        for destination, source in ((first, second), (second, first)):
            replacements[destination.start()] = (
                f"Loading test {destination[1]} ( {source[2]} ) ...\n")
        exchanged = "".join(replacements.get(header.start(), text[header.start():header.end()]) +
                            text[header.end():headers[index + 1].start() if index + 1 < len(headers) else len(text)]
                            for index, header in enumerate(headers))
        rejects("incomplete-coverage", lambda: batch_rows(exchanged, expected))
        # Start the next Test before finishing the first report, then return to it.
        split = sections[0].index("[")
        interleaved = sections[0][:split] + sections[1] + sections[0][split:] + "".join(sections[2:])
        rejects("incomplete-coverage", lambda: batch_rows(interleaved, expected))
        # Same row counts cannot replace evidence of which scenario ran.
        unknown = dict(expected)
        key = next(iter(unknown))
        unknown[key + ".absent"] = unknown.pop(key)
        rejects("incomplete-coverage", lambda: batch_rows(text, unknown))
        missing = {**expected, "/absent-required-test": expected[key]}
        rejects("incomplete-coverage", lambda: batch_rows(text, missing))
        rejects("incomplete-coverage", lambda: batch_rows(text + text, expected))
        extra_report = json.dumps(next(iter(actual.values())))
        rejects("incomplete-coverage", lambda: batch_rows(extra_report + "\n" + text, expected))
        rejects("incomplete-coverage", lambda: batch_rows(text + "\n" + extra_report, expected))
        for key, rows in actual.items():
            rejects("incomplete-coverage", lambda: validate_rows([], expected[key], key))
            rejects("incomplete-coverage", lambda: validate_rows(rows + rows, expected[key], key))
            required = [row for row in rows if (row["POLICY"], row["RULE"], row["RESOURCE"]) in expected[key]]
            assert required
            mutant = deepcopy(required)
            mutant[0]["RESOURCE"] += "-unknown"
            rejects("incomplete-coverage", lambda: validate_rows(mutant, expected[key], key))
            mutant = deepcopy(required)
            mutant[0]["REASON"] = "Excluded"
            rejects("scope-not-exercised", lambda: validate_rows(mutant, expected[key], key))
            mutant = deepcopy(required)
            mutant[0]["REASON"] = "Error"
            rejects("native-evaluation-error", lambda: validate_rows(mutant, expected[key], key))
            mutant = deepcopy(required)
            mutant[0]["RESULT"] = "Fail"
            rejects("native-test-failure", lambda: validate_rows(mutant, expected[key], key))
    # Real expected-deny compiler/evaluation output must not masquerade as Pass.
    diagnostic = Path(root) / "fixtures--transport--transport-fail-closed-evaluation-error-expected-deny.json"
    execution = Path(root) / "executed.json"
    if execution.exists() and "fixtures/transport/transport-fail-closed-evaluation-error-expected-deny" in json.loads(execution.read_text())["scenarios"]:
        assert diagnostic.is_file(), "required native compiler/evaluation report is missing"
    if diagnostic.exists():
        diagnostic_rows = native_rows(diagnostic.read_text())
        # Attribute the error to this fixture's actual CEL expression and target,
        # independently of validate_rows' diagnostic markers. Prelude success and
        # nonrequired Excluded rows are genuine benign messages, not error evidence.
        target = ("verification-transport", "complete-original-transport",
                  "v1/ConfigMap/verification/verification-bundle")
        errors = [row for row in diagnostic_rows
                  if (row["POLICY"], row["RULE"], row["RESOURCE"]) == target
                  and "object.nonexistent.required == true" in row["Message"]]
        assert len(errors) == 1, "missing/ambiguous native expected-deny evaluation diagnostic"
        assert errors[0]["RESULT"] == "Pass" and errors[0]["REASON"] == "Ok", errors[0]
        messages = {row["Message"] for row in errors}
        benign = {row["Message"] for row in diagnostic_rows} - messages
        assert benign, "native diagnostic report lacks its genuine benign prelude/exclusions"
        key, rows = next(iter(actual.items()))
        for message in messages | benign:
            mutant = deepcopy(rows)
            mutant[0]["Message"] = message
            if message in messages:
                rejects("native-evaluation-error", lambda: validate_rows(mutant, expected[key], key))
            else:
                validate_rows(mutant, expected[key], key)


def writable_source(source, destination):
    shutil.copytree(source, destination, copy_function=shutil.copyfile)
    for directory in [destination, *[path for path in destination.rglob("*") if path.is_dir()]]:
        directory.chmod(0o755)


def check_coverage(args):
    with TemporaryDirectory() as root:
        source = Path(root) / "inputs"
        writable_source(args.inputs, source)
        registry = source / "policies" / "scenarios.json"
        inventory = json.loads(registry.read_text())
        scenario = next(entry for entry in inventory["scenarios"]
                        if entry["directory"].startswith("fixtures/workloads/") and "expectGate" not in entry)
        inventory["scenarios"].remove(scenario)
        registry.write_text(json.dumps(inventory))
        shutil.rmtree(source / "policies" / scenario["directory"])
        selected = argparse.Namespace(**vars(args), output=str(Path(root) / "run"),
                                      family="workloads", shard=1, shards=1)
        selected.inputs = str(source)
        rejects("incomplete-coverage", lambda: run(selected))


def check_provenance(args):
    with TemporaryDirectory() as root:
        source = Path(root) / "inputs"
        writable_source(args.inputs, source)
        selected = argparse.Namespace(**vars(args), output=str(Path(root) / "same-source"), parts=args.reports)
        selected.inputs = str(source)
        # Real packaged parts must remain usable with an identical writable copy.
        # Otherwise every mutation below could "pass" through a path-only mismatch.
        aggregate(selected)
        scenario = next(entry for entry in json.loads((source / "policies" / "scenarios.json").read_text())["scenarios"]
                        if entry["directory"].startswith("fixtures/workloads/") and "expectGate" not in entry)
        test = source / "policies" / scenario["directory"] / "kyverno-test.yaml"
        changed = load(test)
        changed["results"] = []
        policy = source / "policies" / "workloads.yaml"
        changed_policy = load(policy)
        changed_policy["spec"]["rules"][0]["validate"]["message"] = "different source policy"
        expected = source / scenario["variant"] / "expected.json"
        changed_expected = json.loads(expected.read_text())
        changed_expected["gpuRenderGid"] += 1
        resource = source / scenario["variant"] / "resource.json"
        changed_resource = json.loads(resource.read_text())
        changed_resource["bundle"]["expected"]["gpuRenderGid"] += 1
        mutations = [(test, changed), (policy, changed_policy), (expected, changed_expected),
                     (resource, changed_resource)]
        for index, (path, value) in enumerate(mutations):
            original = path.read_bytes()
            if path.suffix == ".json":
                path.write_text(json.dumps(value))
            else:
                dump(path, value)
            selected.output = str(Path(root) / f"changed-source-{index}")
            rejects("source-mismatch", lambda: aggregate(selected))
            path.write_bytes(original)
        facts = source / scenario["variant"] / "policy-facts.yaml"
        original = facts.read_bytes()
        documents = list(yaml.safe_load_all(facts.read_text()))
        parameters = next(obj for obj in documents if obj["metadata"]["name"] == "policy-facts")
        parameters["metadata"]["annotations"]["jellyfinGid"] = str(
            int(parameters["metadata"]["annotations"]["jellyfinGid"]) + 1)
        facts.write_text(yaml.safe_dump_all(documents, sort_keys=False))
        selected.output = str(Path(root) / "changed-facts")
        rejects("source-mismatch", lambda: aggregate(selected))
        facts.write_bytes(original)
        # Original manifest and bootstrap populations are inputs, not just cached contexts.
        for population in ("manifests", "bootstrap"):
            directory = source / scenario["variant"] / population
            original = next(obj for path in sorted(directory.rglob("*.yaml"))
                            for obj in yaml.safe_load_all(path.read_text()) if isinstance(obj, dict) and "metadata" in obj)
            changed = deepcopy(original)
            changed["metadata"]["name"] += "-source-counterfactual"
            extra = directory / "source-counterfactual.yaml"
            dump(extra, changed)
            selected.output = str(Path(root) / f"changed-{population}")
            rejects("source-mismatch", lambda: aggregate(selected))
            extra.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", nargs="*")
    for option in ("inputs", "schema-runner", "schemas", "schema-manifests", "prepared-inputs", "kyverno", "yq"):
        parser.add_argument(f"--{option}")
    parser.add_argument("--source-check", choices=("coverage", "provenance", "all"), default="all")
    args = parser.parse_args()
    check_loader()
    for root in args.reports:
        check_reports(root)
    if args.inputs:
        if args.source_check in ("coverage", "all"):
            check_coverage(args)
        if args.source_check in ("provenance", "all"):
            assert args.reports, "source provenance checks require real executed part reports"
            check_provenance(args)
