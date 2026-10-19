"""Join Nix's full hosted plan with successful builds, execution and report bytes."""

import copy
import hashlib
import json
import os
from pathlib import Path
import sys

SYSTEMS = {"x86_64-linux", "aarch64-linux", "aarch64-darwin"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def key(receipt):
    return tuple(receipt[field] for field in ("role", "system", "group", "check"))


def account(plan, inventories, receipts, reports, artifacts):
    require(set(plan) == SYSTEMS, "full CI requires all three planned platforms")
    require(set(inventories) == SYSTEMS, "full CI requires all three evaluated platform inventories")
    expected = {}
    for system, platform in plan.items():
        inventory = inventories[system]
        lazy = {part: [{k: v for k, v in entry.items() if k != "drvPath"} for entry in entries]
                for part, entries in inventory.items()}
        require(lazy == platform["inventory"], "evaluated inventory differs from planned registrations/capabilities")
        names = [entry["name"] for entry in inventory["inventory"]]
        partitions = inventory["fast"] + inventory["runtime"] + inventory["unsupported"]
        require(len(names) == len(set(names)) and sorted(names) == sorted(entry["name"] for entry in partitions),
                "missing/duplicate/misclassified check registration")
        require(sorted(partitions, key=lambda entry: entry["name"]) == sorted(inventory["inventory"], key=lambda entry: entry["name"]),
                "partition replaced a registered check derivation/capability")
        groups = platform["groups"]
        require(len(groups) == len(set(groups)) and "checks" in groups, "missing/duplicate standard output group")
        for group in groups:
            checks = inventory["fast"] if group == "checks" else []
            expected[("build", system, group, "")] = checks
        for entry in inventory["runtime"]:
            require(entry["hosted"] and entry["runtime"], "invalid hosted runtime classification")
            expected[("build", system, "runtime", entry["name"])] = [entry]
        for entry in inventory["fast"]:
            require(entry["hosted"] and not entry["runtime"], "invalid fast classification")
        for entry in inventory["unsupported"]:
            require(not entry["hosted"] and entry["drvPath"] is None and entry["reason"], "unsupported check lacks refusal")
        for application in platform["nativeApplications"]:
            identity = ("native", system, application["name"], "")
            require(identity not in expected, "duplicate native registration")
            expected[identity] = application | {"system": system}
    expected[("bootstrap", "aarch64-linux", "darwinLinuxBuilder", "")] = []
    actual = {}
    for receipt in receipts:
        identity = key(receipt)
        require(identity not in actual, "duplicate execution receipt")
        actual[identity] = receipt
    require(set(actual) == set(expected), "missing/unexpected CI group, runtime, native or bootstrap execution")
    declared_artifacts = {}
    for declaration in artifacts:
        identity = key(declaration)
        require(identity not in declared_artifacts, "duplicate evaluated artifact declaration")
        declared_artifacts[identity] = declaration["artifact"]
    require(set(declared_artifacts) == set(expected), "missing/unexpected evaluated executor artifact")
    expected_reports = set()
    for identity, declared in expected.items():
        receipt = actual[identity]
        build = receipt["build"]
        require(isinstance(build, list) and len(build) == 1, "execution must record its exact successful build")
        result = build[0]
        require(isinstance(result["drvPath"], str) and result["drvPath"].startswith("/nix/store/")
                and result["drvPath"].endswith(".drv"), "invalid successful build derivation")
        outputs = result["outputs"]
        require(isinstance(outputs, dict) and outputs and all(isinstance(path, str) and path.startswith("/nix/store/")
                for path in outputs.values()), "missing/invalid successful build outputs")
        artifact = declared_artifacts[identity]
        require(result["drvPath"] == artifact["drvPath"] and outputs == artifact["outputs"],
                "execution built an artifact other than its Nix declaration")
        if identity[0] == "native":
            require(receipt["application"] == declared and receipt["checks"] == [], "omitted/replaced native execution")
            require(receipt["program"] == artifact["program"], "native program differs from its Nix declaration")
            require(any(receipt["program"].startswith(path + "/") for path in outputs.values()),
                    "native program was not from the built package")
            filename = declared.get("reportFile")
            if filename:
                report_key = (identity[1], identity[2], filename)
                expected_reports.add(report_key)
                require(report_key in reports, "missing persisted native report")
                require(hashlib.sha256(reports[report_key]).hexdigest() == receipt["reportSha256"],
                        "persisted report bytes differ from packaged checker acceptance")
            else:
                require(receipt["reportSha256"] == "", "unexpected native report acceptance")
        else:
            checks = [{"name": entry["name"], "drvPath": entry["drvPath"]} for entry in declared]
            require(receipt["checks"] == checks, "omitted/replaced check derivation execution")
            if identity[2] == "runtime":
                require(result["drvPath"] == checks[0]["drvPath"], "runtime receipt built a replacement derivation")
    require(set(reports) == expected_reports, "missing/unexpected approved native report")


def load(root, run_id):
    plan = json.loads((root / "required-plan/check-inventory.json").read_text())
    inventories = {}
    for path in (root / "required-inventories").glob("*/check-inventory.json"):
        system = path.parent.name.removeprefix("check-inventory-").removesuffix(f"-checks-{run_id}")
        require(system in SYSTEMS and system not in inventories, "unexpected/duplicate platform inventory")
        inventories[system] = json.loads(path.read_text())
    receipts = [json.loads(path.read_text()) for path in (root / "required-receipts").glob("*/ci-receipt.json")]
    artifacts = [json.loads(path.read_text()) for path in (root / "required-receipts").glob("*/ci-artifact.json")]
    reports = {}
    for system, platform in plan.items():
        for application in platform["nativeApplications"]:
            filename = application.get("reportFile")
            if filename:
                path = root / "required-native" / f"native-{system}-{application['name']}-{run_id}" / filename
                if path.is_file():
                    reports[(system, application["name"], filename)] = path.read_bytes()
    return plan, inventories, receipts, reports, artifacts


def self_test():
    # One runnable accounting check; real report semantics belong to the packaged app.
    def build(name):
        return {"drvPath": f"/nix/store/{name}.drv", "outputs": {"out": f"/nix/store/{name}"}}

    plan, inventories, receipts, artifacts = {}, {}, [], []

    def execution(role, system, group, check, result, **fields):
        identity = {"role": role, "system": system, "group": group, "check": check}
        artifact = result | ({"program": fields["program"]} if role == "native" else {})
        artifacts.append(identity | {"artifact": copy.deepcopy(artifact)})
        receipts.append(identity | {"build": [copy.deepcopy(result)]} | fields)

    for system in sorted(SYSTEMS):
        result = build(f"{system}-contract")
        fast = {"name": "contract", "drvPath": result["drvPath"], "hosted": True, "runtime": False, "reason": ""}
        runtime_result = build(f"{system}-runtime")
        runtime = fast | {"name": "runtime-proof", "drvPath": runtime_result["drvPath"], "runtime": True}
        unsupported = fast | {"name": "unsupported-proof", "drvPath": None, "hosted": False, "reason": "unsupported feature"}
        inventory = {"inventory": [fast, runtime, unsupported], "fast": [fast], "runtime": [runtime], "unsupported": [unsupported]}
        inventories[system] = inventory
        plan[system] = {"inventory": {part: [{k: v for k, v in entry.items() if k != "drvPath"} for entry in entries]
                                             for part, entries in inventory.items()},
                        "groups": ["checks", "packages", "darwinConfigurations", "futureOutputGroup"], "nativeApplications": []}
        for group in plan[system]["groups"]:
            execution("build", system, group, "", build(f"{system}-{group}"),
                      checks=[{"name": "contract", "drvPath": result["drvPath"]}] if group == "checks" else [])
        execution("build", system, "runtime", "runtime-proof", runtime_result,
                  checks=[{"name": "runtime-proof", "drvPath": runtime_result["drvPath"]}])
    application = {"name": "native-proof", "reportFile": "proof.json", "reportCheckArguments": ["--check-report", "proof.json"]}
    plan["x86_64-linux"]["nativeApplications"] = [application]
    report_key = ("x86_64-linux", "native-proof", "proof.json")
    reports = {report_key: b'{"actual": "bytes"}\n'}
    execution("native", "x86_64-linux", "native-proof", "", build("native-proof"),
              checks=[], application=application | {"system": "x86_64-linux"}, program="/nix/store/native-proof/bin/native-proof",
              reportSha256=hashlib.sha256(reports[report_key]).hexdigest())
    execution("bootstrap", "aarch64-linux", "darwinLinuxBuilder", "", build("darwin-linux-builder"), checks=[])
    account(plan, inventories, receipts, reports, artifacts)
    def refuses(p=plan, i=inventories, r=receipts, b=reports, a=artifacts):
        try:
            account(p, i, r, b, a)
        except (ValueError, KeyError, TypeError):
            return
        raise AssertionError("invalid full CI accounting was accepted")
    for index in range(len(receipts)):
        refuses(r=receipts[:index] + receipts[index + 1:])
    refuses(r=receipts + [receipts[0]])
    refuses(a=artifacts[:-1])
    refuses(a=artifacts + [artifacts[0]])
    # Every declared executor rejects a different successful build, even when a
    # native replacement supplies a program inside that unrelated output.
    unrelated = build("unrelated-successful-build")
    for index, receipt in enumerate(receipts):
        replacement = copy.deepcopy(receipts)
        replacement[index]["build"] = [unrelated]
        if receipt["role"] == "native":
            replacement[index]["program"] = "/nix/store/unrelated-successful-build/bin/native-proof"
        refuses(r=replacement)
    replacement = copy.deepcopy(receipts)
    replacement[-2]["program"] = "/nix/store/native-proof/bin/other-program"
    refuses(r=replacement)
    replacement = copy.deepcopy(receipts)
    replacement[0]["build"][0]["outputs"]["out"] = "/nix/store/unrelated-output"
    refuses(r=replacement)
    refuses(p={s: p for s, p in plan.items() if s != "aarch64-linux"})
    refuses(i={s: i for s, i in inventories.items() if s != "aarch64-darwin"})
    replacement = copy.deepcopy(receipts)
    replacement[0]["checks"][0]["drvPath"] = "/nix/store/replacement.drv"
    refuses(r=replacement)
    replacement = copy.deepcopy(receipts)
    replacement[-2]["program"] = "/nix/store/unbuilt/bin/native-proof"
    refuses(r=replacement)
    replacement = copy.deepcopy(receipts)
    replacement[-2]["application"]["reportCheckArguments"] = ["--scoped"]
    refuses(r=replacement)
    refuses(b={})
    refuses(b={report_key: b"changed bytes"})
    print("full CI accounting accepts the union and refuses omissions, replacements, scope and changed report bytes")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        account(*load(Path(sys.argv[1]), os.environ["RUN_ID"]))
        print("all required platforms, output groups, runtime/native executions, bootstrap and checked report bytes accounted for")
