"""Offline schema preparation and original-YAML validation; no cluster access."""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

import yaml


class UniqueLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        keys = set()
        for key_node, _ in node.value:
            if key_node.tag == "tag:yaml.org,2002:merge":
                continue
            key = self.construct_object(key_node, deep=deep)
            if not isinstance(key, str):
                raise ValueError(f"{key_node.start_mark}: Kubernetes mapping keys must be strings")
            if key in keys:
                raise ValueError(f"{key_node.start_mark}: duplicate YAML key {key!r}")
            keys.add(key)
        return super().construct_mapping(node, deep=deep)


# CRD enums can contain bare '=' (PyYAML's otherwise unsupported value tag).
UniqueLoader.add_constructor("tag:yaml.org,2002:value", UniqueLoader.construct_scalar)


def documents(root):
    paths = sorted(p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in {".yaml", ".yml", ".json"})
    for path in paths:
        with path.open() as stream:
            for document in yaml.load_all(stream, Loader=UniqueLoader):
                if document is None:
                    continue
                if not isinstance(document, dict):
                    raise ValueError(f"{path}: effective document must be an object")
                # Kubeconform expands the generic List envelope, not typed lists.
                if str(document.get("kind", "")).lower() == "list":
                    items = document.get("items")
                    if not isinstance(items, list):
                        raise ValueError(f"{path}: List.items must be a list")
                    for item in items:
                        if not isinstance(item, dict):
                            raise ValueError(f"{path}: List item must be an object")
                        yield path, item
                else:
                    yield path, document


def schema_name(api, kind):
    group, version = (api.split("/", 1) if "/" in api else (api, api))
    parts = (group, kind.lower(), version)
    if not all(re.fullmatch(r"[a-zA-Z0-9.-]+", part) for part in parts):
        raise ValueError(f"unsafe schema GVK {api}/{kind}")
    return "__".join(parts) + ".json"


def local_refs(schemas):
    def visit(value):
        if isinstance(value, dict):
            ref = value.get("$ref")
            if isinstance(ref, str):
                filename = ref.split("#", 1)[0]
                if filename and (filename != "_definitions.json" or not (schemas / filename).is_file()):
                    raise ValueError(f"non-local or missing schema reference {ref!r}")
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    for path in schemas.glob("*.json"):
        visit(json.loads(path.read_text()))


def derive(args):
    args.schemas.mkdir(parents=True, exist_ok=True)
    inventory = []
    seen = set()
    crd_count = 0
    for path, crd in documents(args.manifests):
        if crd.get("kind") != "CustomResourceDefinition":
            continue
        crd_count += 1
        spec = crd["spec"]
        group, kind = spec["group"], spec["names"]["kind"]
        served = []
        for version in spec["versions"]:
            if version.get("served") is not True:
                continue
            api = f"{group}/{version['name']}"
            name = schema_name(api, kind)
            if name in seen or (args.schemas / name).exists():
                raise ValueError(f"{path}: colliding served-GVK schema {api}/{kind}")
            seen.add(name)
            if not isinstance(version.get("schema", {}).get("openAPIV3Schema"), dict):
                raise ValueError(f"{path}: missing served-GVK schema {api}/{kind}")
            served.append((api, name))
        if not served:
            raise ValueError(f"{path}: CRD has no served schema")
        # Per-CRD staging prevents the upstream converter silently overwriting
        # another CRD's output. It reads the exact original tracked YAML.
        with tempfile.TemporaryDirectory() as staging:
            subprocess.run(
                [sys.executable, str(args.converter), str(path)],
                cwd=staging,
                env={**os.environ, "FILENAME_FORMAT": "{fullgroup}__{kind}__{version}"},
                check=True,
            )
            for api, name in served:
                generated = Path(staging) / name
                if not generated.is_file():
                    raise ValueError(f"{path}: converter omitted served schema {name}")
                shutil.copyfile(generated, args.schemas / name)
                inventory.append({"apiVersion": api, "kind": kind, "schema": name,
                                  "source": str(path.relative_to(args.manifests))})
    if not inventory:
        raise ValueError("no served custom schemas selected")
    local_refs(args.schemas)
    (args.schemas / "custom-gvks.json").write_text(json.dumps(inventory, indent=2) + "\n")
    print(f"derived {len(inventory)} served custom schemas from {crd_count} exact CRDs")


def validate(args):
    inventory = json.loads((args.schemas / "custom-gvks.json").read_text())
    names = set()
    for entry in inventory:
        name = schema_name(entry["apiVersion"], entry["kind"])
        if name != entry["schema"] or name in names:
            raise ValueError(f"colliding or incorrect custom schema inventory {entry}")
        names.add(name)
        if not (args.schemas / name).is_file():
            raise ValueError(f"missing served custom schema {name}")
    if not inventory:
        raise ValueError("no served custom schemas inventoried")
    local_refs(args.schemas)
    expected = Counter()
    for path, document in documents(args.manifests):
        api, kind = document.get("apiVersion"), document.get("kind")
        if not isinstance(api, str) or not isinstance(kind, str):
            raise ValueError(f"{path}: missing apiVersion/kind")
        schema = args.schemas / schema_name(api, kind)
        if not schema.is_file():
            raise ValueError(f"{path}: missing schema for {api}/{kind}")
        metadata = document.get("metadata", {})
        if not isinstance(metadata, dict):
            raise ValueError(f"{path}: metadata must be an object")
        name = metadata.get("name", "")
        if metadata.get("generateName"):
            name = metadata["generateName"] + "{{ generateName }}"
        expected[(str(path), kind, api, name)] += 1
    count = sum(expected.values())
    if count == 0:
        raise ValueError("zero effective deployment documents selected")
    paths = sorted({entry[0] for entry in expected})
    command = [str(args.kubeconform), "-strict", "-summary", "-verbose", "-output", "json",
               "-kubernetes-version", "1.35.8", "-schema-location",
               str(args.schemas / "{{.Group}}__{{.ResourceKind}}__{{.ResourceAPIVersion}}.json"), *paths]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    args.report.write_text(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    report = json.loads(result.stdout)
    summary = report["summary"]
    actual = Counter()
    for resource in report["resources"]:
        if resource["status"] == "" and not any(resource[key] for key in ("kind", "version", "name")):
            continue  # Original YAML may contain null/comment-only separators.
        if resource["status"] != "statusValid":
            raise ValueError(f"Kubeconform rejected or skipped resource: {resource}")
        actual[(resource["filename"], resource["kind"], resource["version"], resource["name"])] += 1
    if result.returncode or summary != {"valid": count, "invalid": 0, "errors": 0, "skipped": 0} or actual != expected:
        raise ValueError(f"incomplete schema coverage: expected {count}, summary={summary}, "
                         f"missing={expected - actual}, extra={actual - expected}, exit={result.returncode}")
    print(f"validated all {count} independently inventoried effective documents; zero invalid/errors/skips")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="mode", required=True)
    for mode in ("derive", "validate"):
        command = subcommands.add_parser(mode)
        command.add_argument("--manifests", type=Path, required=True)
        command.add_argument("--schemas", type=Path, required=True)
        if mode == "derive":
            command.add_argument("--converter", type=Path, required=True)
        else:
            command.add_argument("--kubeconform", type=Path, required=True)
            command.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not args.manifests.is_dir() or not args.schemas.is_dir() and args.mode == "validate":
        parser.error("manifest/schema root does not exist")
    try:
        (derive if args.mode == "derive" else validate)(args)
    except (ValueError, KeyError, TypeError, yaml.YAMLError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"schema gate: {error}\n")


if __name__ == "__main__":
    main()
