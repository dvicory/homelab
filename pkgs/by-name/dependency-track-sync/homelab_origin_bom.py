"""Project verified, selected-option inclusion evidence onto an unchanged native BOM.

Paths are store-output references, not the coarser derivation dependency graph.
Source URLs describe declaration/aspect inclusion sites, never exclusive ownership,
execution, deployment or vulnerability applicability. All failures are ValueError.
"""
from collections import deque
from copy import deepcopy
import json
import re
from urllib.parse import unquote, urlsplit


REFERENCE_PREFIX = "homelab:origin:v1 "
OWNED_PROPERTIES = frozenset({"homelab:included-through", "homelab:declarations", "homelab:origin-status"})
_STORE = re.compile(r"/nix/store/[0-9a-z]{32}-[^/\s]+\Z")
_REVISION = re.compile(r"[0-9a-f]{40}\Z")


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _text(value):
    return isinstance(value, str) and bool(value) and not any(ord(c) < 32 or ord(c) == 127 for c in value)


def _store(value, drv=False):
    _require(_text(value) and _STORE.fullmatch(value) is not None,
             "malformed Nix store path")
    _require(value.endswith(".drv") == drv, "unexpected derivation/output path")
    return value


def _paths(values):
    _require(isinstance(values, list), "store paths must be a list")
    for value in values:
        _store(value)
    _require(len(values) == len(set(values)), "duplicate output/reference path")
    return set(values)




def _shortest(graph, start):
    """Sorted breadth-first traversal chooses a stable shortest path through cycles."""
    parents = {start: None}
    pending = deque([start])
    while pending:
        path = pending.popleft()
        for reference in graph[path]:
            if reference not in parents:
                parents[reference] = path
                pending.append(reference)
    return parents


def _path(parents, end):
    result = [end]
    while parents[result[-1]] is not None:
        result.append(parents[result[-1]])
    return result[::-1]


def _label(path):
    return path.rsplit("/", 1)[-1][33:]


def _validate_origins(origins):
    _require(isinstance(origins, dict) and type(origins.get("schema")) is int
             and origins["schema"] == 1, "unsupported origin schema")
    root = origins.get("root")
    _require(isinstance(root, dict), "origin root absent")
    _store(root.get("drvPath"), drv=True)
    _store(root.get("outPath"))
    _require(_text(origins.get("target")), "origin target absent")
    source = origins.get("source")
    _require(isinstance(source, dict), "origin source absent")
    revision = source.get("revision")
    _require(isinstance(revision, str) and _REVISION.fullmatch(revision) is not None,
             "origin source revision is not pinned")
    _require(source.get("flake") == "github:dvicory/homelab/" + revision,
             "origin source is not the pinned Homelab flake")
    _store(source.get("storePath"))
    _require(_text(source.get("narHash")), "origin source NAR hash absent")
    coverage = origins.get("coverage")
    _require(isinstance(coverage, dict) and type(coverage.get("complete")) is bool
             and isinstance(coverage.get("options"), list), "origin coverage malformed")
    options = coverage["options"]
    _require(all(_text(option) for option in options) and len(options) == len(set(options)),
             "origin coverage options malformed or duplicated")
    records = origins.get("origins")
    _require(isinstance(records, list), "origin records absent")
    identities = set()
    for record in records:
        _require(isinstance(record, dict) and _text(record.get("id")), "origin identity absent")
        _require(record["id"] not in identities, "duplicate origin identity")
        identities.add(record["id"])
        _require(record.get("option") in options and _text(record.get("definition")),
                 "origin option/definition absent from coverage")
        _require(record.get("kind") in ("homelab", "upstream-definition", "unresolved"),
                 "unknown origin kind")
        _require(record.get("aspect") is None or _text(record["aspect"]), "malformed aspect identity")
        package = record.get("package")
        _require(isinstance(package, dict) and _text(package.get("name")), "origin package absent")
        _store(package.get("drvPath"), drv=True)
        _store(package.get("outputPath"))
        source_file, source_url = record.get("sourceFile"), record.get("sourceUrl")
        _require(source_file is None or (_text(source_file) and not source_file.startswith("/")
                 and all(part not in ("", ".", "..") for part in source_file.split("/"))),
                 "origin source file is not repository-relative")
        if source_url is not None:
            _require(_text(source_url), "origin source URL malformed")
            parsed = urlsplit(source_url)
            parts = parsed.path.split("/")
            _require(parsed.scheme == "https" and parsed.netloc == "github.com"
                     and not parsed.query and not parsed.fragment and len(parts) >= 6
                     and parts[1] and parts[2] and parts[3] == "blob"
                     and _REVISION.fullmatch(parts[4]) is not None
                     and source_file is not None and unquote("/".join(parts[5:])) == source_file,
                     "origin source URL is not a pinned repository file")
            _require(record["kind"] != "unresolved", "unresolved origin claims a source URL")
            if record["kind"] == "homelab":
                _require(parts[1:3] == ["dvicory", "homelab"] and parts[4] == revision,
                         "Homelab source URL differs from evaluated revision")
    return root


def _native(document):
    _require(isinstance(document, dict) and document.get("bomFormat") == "CycloneDX"
             and document.get("specVersion") in ("1.4", "1.5", "1.6")
             and type(document.get("version")) is int and document["version"] >= 1,
             "malformed native CycloneDX document")
    metadata = document.get("metadata")
    _require(isinstance(metadata, dict) and isinstance(metadata.get("component"), dict)
             and isinstance(document.get("components"), list), "native root/components absent")
    components, owners = {}, {}
    for component in [metadata["component"], *document["components"]]:
        _require(isinstance(component, dict) and _text(component.get("name"))
                 and isinstance(component.get("version"), str), "malformed native component")
        ref = component.get("bom-ref")
        _require(_text(ref) and _STORE.fullmatch(ref) is not None,
                 "native identity is not a store path")
        _require(ref not in components, "duplicate native component identity")
        properties = component.get("properties")
        _require(isinstance(properties, list) and all(isinstance(prop, dict)
                 and _text(prop.get("name")) and isinstance(prop.get("value"), str)
                 for prop in properties), "malformed native properties")
        outputs = _paths([p["value"] for p in properties if p["name"] == "nix:output_path"])
        drvs = [p["value"] for p in properties if p["name"] == "nix:drv_path"]
        _require(bool(outputs) and (drvs == [ref] if ref.endswith(".drv") else not drvs and ref in outputs),
                 "native derivation/output identity mismatch")
        for output in outputs:
            _require(output not in owners, "duplicate native output identity")
            owners[output] = ref
        references = component.get("externalReferences", [])
        _require(isinstance(references, list) and all(isinstance(item, dict)
                 and _text(item.get("type")) and _text(item.get("url"))
                 and ("comment" not in item or isinstance(item["comment"], str))
                 for item in references), "malformed native external references")
        _require(not component.get("components"), "nested native components are unsupported")
        components[ref] = (component, outputs)
    dependencies = document.get("dependencies")
    _require(isinstance(dependencies, list), "native dependencies absent")
    seen = set()
    for dependency in dependencies:
        _require(isinstance(dependency, dict) and isinstance(dependency.get("ref"), str)
                 and dependency["ref"] in components and dependency["ref"] not in seen
                 and isinstance(dependency.get("dependsOn", []), list), "malformed native dependency identity")
        targets = dependency.get("dependsOn", [])
        _require(all(isinstance(ref, str) and ref in components for ref in targets)
                 and len(targets) == len(set(targets)), "malformed native dependency targets")
        seen.add(dependency["ref"])
    return components, owners


def enrich(document: dict, closure: dict, origins: dict) -> tuple[dict, dict]:
    """Return an owned-metadata projection and full deterministic inclusion report.

    Inputs must already have passed the sealed inventory verifier. In particular,
    its alternative-deriver evidence authorizes native output associations; a Nix
    closure deriver is only a hint for those already-verified native components.
    Selected option outputs come from evaluation of the identical root; retain
    selector/native/closure derivations separately rather than equating hints.
    """
    root = _validate_origins(origins)
    enriched = deepcopy(document)
    components, owners = _native(enriched)
    _require(isinstance(closure, dict) and bool(closure), "native closure absent")
    paths = _paths(list(closure))
    graph = {}
    for output, record in closure.items():
        _require(isinstance(record, dict), "malformed closure record")
        references = _paths(record.get("references"))
        _require(references <= paths, "closure omits a referenced output")
        deriver = record.get("deriver")
        if deriver is not None:
            _store(deriver, drv=True)
        graph[output] = sorted(references)
    root_ref = enriched["metadata"]["component"]["bom-ref"]
    _require(root_ref == root["drvPath"] and root["outPath"] in components[root_ref][1],
             "native metadata root differs from evaluated origin root")
    _require(root["outPath"] in graph, "closure omits the evaluated origin root output")
    root_parents = _shortest(graph, root["outPath"])
    reachable = set(root_parents)
    coverage = deepcopy(origins["coverage"])
    coverage["options"] = sorted(coverage["options"])
    records = sorted(deepcopy(origins["origins"]), key=lambda record: record["id"])
    by_id = {record["id"]: record for record in records}
    grouped = {}
    for record in records:
        package = record["package"]
        key = (record["option"], package["drvPath"], package["outputPath"])
        grouped.setdefault(key, []).append(record["id"])
    routes = {ref: [] for ref in components}
    entrypoints, origin_matches, traversals = [], [], {}
    for (option, drv, output), ids in sorted(grouped.items()):
        native_ref = owners.get(output)
        closure_drv = closure[output].get("deriver") if output in paths else None
        entrypoint = {"option": option, "drvPath": drv, "outputPath": output, "originIds": ids,
                      "nativeBomRef": native_ref, "closureDeriver": closure_drv,
                      "selectorMatchesClosureDeriver": drv == closure_drv,
                      "selectorMatchesNativeDeriver": drv == native_ref}
        if output not in paths:
            status = "not-in-runtime-closure"
        elif output not in reachable:
            status = "unreachable-from-root"
        elif native_ref is None:
            status = "unmapped-native-output"
        else:
            status = "traced"
        entrypoint["status"] = status
        origin_matches.extend({"id": identity, "status": status} for identity in ids)
        if status == "traced":
            prefix = _path(root_parents, output)
            entrypoint["rootPath"] = prefix
            if output not in traversals:
                traversals[output] = _shortest(graph, output)
            parents = traversals[output]
            targets = {}
            for target in parents:
                if target in owners:
                    targets.setdefault(owners[target], []).append(target)
            for ref, matched in targets.items():
                candidates = [_path(parents, target) for target in matched]
                shortest = min(candidates, key=lambda path: (len(path), path))
                routes[ref].append({"option": option, "drvPath": drv, "entrypointOutputPath": output,
                                    "originIds": ids, "outputPaths": sorted(matched),
                                    "entrypointPath": shortest, "rootPath": prefix,
                                    "path": prefix[:-1] + shortest})
            entrypoint["matchedComponentCount"] = len(targets)
        entrypoints.append(entrypoint)
    report_components = []
    for ref, (component, outputs) in sorted(components.items()):
        component_routes = routes[ref]
        ids = sorted({identity for route in component_routes for identity in route["originIds"]})
        matched_origins = [by_id[identity] for identity in ids]
        runtime_outputs = sorted(outputs & reachable)
        status = {"match": "matched" if ids else "unknown", "coverage": coverage,
                  "originIds": ids, "unresolvedOriginIds": [record["id"] for record in matched_origins
                                                            if record["kind"] == "unresolved"],
                  "runtimeOutputPaths": runtime_outputs,
                  "unmatchedOutputPaths": sorted(set(runtime_outputs) - {
                      output for route in component_routes for output in route["outputPaths"]}),
                  "scope": "selected-option inclusion; not exclusive ownership, execution, deployment or exploitability"}
        readable_paths = sorted({" -> ".join(_label(path) for path in route["entrypointPath"])
                                 for route in component_routes})
        declarations = []
        for record in matched_origins:
            site = record.get("aspect") or record.get("sourceFile") or record["definition"]
            declarations.append(record["package"]["name"] + " | " + site + " | "
                                + record["option"] + " | " + record["kind"])
        properties = [prop for prop in component["properties"] if prop["name"] not in OWNED_PROPERTIES]
        properties.extend({"name": "homelab:included-through", "value": path} for path in readable_paths)
        properties.extend({"name": "homelab:declarations", "value": declaration}
                          for declaration in sorted(set(declarations)))
        properties.append({"name": "homelab:origin-status", "value": json.dumps({
            "match": status["match"], "matchedOrigins": len(ids),
            "unresolvedOrigins": len(status["unresolvedOriginIds"]),
            "runtimeOutputs": len(runtime_outputs),
            "unmatchedOutputs": len(status["unmatchedOutputPaths"]),
            "coveredOptions": coverage["options"], "complete": coverage["complete"],
            "attributionRevision": origins["source"]["revision"]}, sort_keys=True)})
        component["properties"] = properties
        references = [item for item in component.get("externalReferences", [])
                      if not item.get("comment", "").startswith(REFERENCE_PREFIX)]
        existing_urls = {item["url"] for item in references}
        source_references = {}
        for record in matched_origins:
            if record.get("sourceUrl") is not None:
                label = (record["kind"] + " " + record["option"] + " " + record["definition"])
                if record.get("aspect") is not None:
                    label += " aspect/inclusion-site " + record["aspect"]
                source_references.setdefault(record["sourceUrl"], set()).add(label)
        for url, labels in sorted(source_references.items()):
            if url not in existing_urls:
                references.append({"type": "vcs", "url": url,
                                   "comment": REFERENCE_PREFIX + "; ".join(sorted(labels))
                                   + "; declaration/aspect inclusion site, not exclusive ownership"})
        if references or "externalReferences" in component:
            component["externalReferences"] = references
        report_components.append({"bomRef": ref, "drvPath": ref if ref.endswith(".drv") else None,
                                  "outputPaths": sorted(outputs), "runtimeOutputPaths": runtime_outputs,
                                  "closureDerivers": {output: closure[output].get("deriver")
                                                      for output in sorted(outputs & paths)},
                                  "originIds": ids, "paths": component_routes, "status": status})
    attributed_outputs = {output for component in report_components for route in component["paths"]
                          for output in route["outputPaths"]}
    report = {"schema": 1, "target": origins["target"], "root": deepcopy(root),
              "source": deepcopy(origins["source"]), "coverage": coverage, "origins": records,
              "originMatches": sorted(origin_matches, key=lambda match: match["id"]),
              "entrypoints": entrypoints, "components": report_components,
              "unreachableClosureOutputs": sorted(paths - reachable),
              "unrepresentedClosureOutputs": sorted(reachable - owners.keys()),
              "unattributedClosureOutputs": sorted(reachable - attributed_outputs),
              "counts": {"origins": len(records), "tracedOrigins": sum(
                  match["status"] == "traced" for match in origin_matches),
                  "untracedOrigins": sum(match["status"] != "traced" for match in origin_matches),
                  "unresolvedOrigins": sum(record["kind"] == "unresolved" for record in records),
                  "components": len(components), "matchedComponents": sum(
                      bool(component["originIds"]) for component in report_components),
                  "unknownComponents": sum(not component["originIds"] for component in report_components),
                  "reachableOutputs": len(reachable), "attributedOutputs": len(attributed_outputs)}}
    return enriched, report
