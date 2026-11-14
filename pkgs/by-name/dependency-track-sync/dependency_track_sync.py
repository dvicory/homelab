"""Sealed PR120 inventories to stock Dependency-Track; originals are the archive."""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

sys.dont_write_bytecode = True
import security_artifacts
import homelab_origins
import homelab_origin_bom

GROUP = "homelab-inventory"
OWNER = "dependency-track-sync-v1"


def now():
    return datetime.now(timezone.utc).isoformat()


def load(path):
    return json.loads(path.read_text())


def save(path, value):
    """A crash must not turn the local lifecycle journal into a partial file."""
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
            descriptor = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        finally:
            temporary.unlink(missing_ok=True)


def identity(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def target_key(provenance):
    declaration = (provenance["target"] if provenance["kind"] == "nix" else
                   [provenance["source"], provenance.get("pointer", "")])
    return identity([provenance["kind"], provenance["system"], declaration])


def project_identity(provenance, revision=None, stream=None):
    return identity([target_key(provenance), revision, stream])


def project_name(provenance, revision=None, stream=None):
    target = provenance.get("target", "")
    label = ("Host: " + target.split(".")[1] if target.startswith("nixosConfigurations.") else
             "Package: " + target.rsplit(".", 1)[-1] if provenance["kind"] == "nix" else
             "Image: " + Path(provenance["source"]).stem.split("-", 1)[-1])
    label = re.sub(r"[\x00-\x1f\x7f]", "?", label)[:70]
    system = {"aarch64-linux": "ARM64", "x86_64-linux": "x86-64"}.get(provenance["system"], provenance["system"])
    # ponytail: display suffixes can collide; full identity fails closed. Lengthen them if one occurs.
    stream_label = {"native": "Nix packages", "language": "Contents scan",
                    "image": "Image contents", "archive-image": "Image contents"}
    title = label + " · " + system + (" · " + stream_label[stream] if revision is not None else "")
    return title + " [" + project_identity(provenance, revision, stream)[:8] + "]"


def content_hash(file):
    document = load(file)
    document.pop("serialNumber", None)
    if "metadata" in document:
        document["metadata"].pop("timestamp", None)
    return identity(document)


def describe(provenance, manifest, inventory):
    """Identity is software plus declaration, never report bytes or collection time."""
    for field in ("id", "kind", "system", "state", "source", "location", "update"):
        if not isinstance(provenance.get(field), str) or not provenance[field]:
            raise ValueError("missing source mapping: " + field)
    if provenance["kind"] not in ("nix", "oci"):
        raise ValueError("unsupported inventory kind")
    if provenance["state"] not in ("desired", "exported", "referenced"):
        raise ValueError("unsupported source scope; deployment observation is not available")
    if provenance["kind"] == "nix":
        security_artifacts.store_paths([provenance["drvPath"], provenance["outPath"]])
        if not provenance["drvPath"].endswith(".drv") or not provenance.get("target"):
            raise ValueError("Nix revision requires actual derivation/root and target")
        revision = [provenance["drvPath"], provenance["outPath"]]
        streams = {"native": "native-identity.cdx.json", "language": "language.cdx.json"}
        if provenance.get("ociArchive"):
            streams["archive-image"] = "archive.cdx.json"
    else:
        image = provenance.get("resolvedImage", "")
        if (not re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", image)
                or provenance.get("ociPlatform") not in ("linux/amd64", "linux/arm64")):
            raise ValueError("image revision requires immutable digest and supported platform")
        revision = [image, provenance["ociPlatform"]]
        streams = {"image": "language.cdx.json"}
    return {"target": target_key(provenance), "revision": revision, "revisionId": identity(revision),
            "streams": streams, "hashes": {name: manifest["files"][file]["sha256"]
                                           for name, file in streams.items()},
            "contentHashes": {name: content_hash(inventory / file) for name, file in streams.items()}}


def archive_inventory(source, root):
    """Snapshot before verifying/using, so mutable admitted input cannot race upload."""
    source = source.resolve(strict=True)
    if not source.is_dir():
        raise ValueError("sealed inventory is not a directory")
    entries = list(source.iterdir())
    if (set(path.name for path in entries) - (security_artifacts.FILES | {"complete.json"})
            or any(not stat.S_ISREG(path.lstat().st_mode) for path in entries)
            or sum(path.stat().st_size for path in entries) > security_artifacts.MAX_EXPANDED + 1024 * 1024):
        raise ValueError("inventory entries must be bounded, regular, allowlisted files")
    if (source / "complete.json").stat().st_size > 1024 * 1024:
        raise ValueError("inventory seal exceeds 1 MiB")
    archive_root = root / "archive"
    archive_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=archive_root) as temporary:
        staged = Path(temporary) / "inventory"
        # Keep symlinks as links for the shared verifier to reject; never read targets.
        shutil.copytree(source, staged, symlinks=True)
        if (staged / "complete.json").is_symlink():
            raise ValueError("inventory seal is a symlink")
        manifest = load(staged / "complete.json")
        security_artifacts.verify(staged, manifest["inventoryKey"])
        provenance = load(staged / "provenance.json")
        description = describe(provenance, manifest, staged)
        seal = security_artifacts.digest(staged / "complete.json")
        destination = archive_root / seal
        if destination.exists():
            security_artifacts.verify(destination, manifest["inventoryKey"])
            if (destination / "complete.json").read_bytes() != (staged / "complete.json").read_bytes():
                raise ValueError("archive seal collision")
        else:
            os.rename(staged, destination)
        return destination, provenance, manifest, description


def credential(path, *, password=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 65536:
            raise ValueError("credential file must be bounded, regular and inaccessible to group/other")
        value = stream.read()
        if not password:
            value = value.strip()
    if not value.strip() or "\n" in value or "\r" in value:
        raise ValueError("credential file must contain one nonempty value")
    return value


@contextmanager
def github_credentials(path):
    """Never consult an operator's gh profile, enterprise token or inherited host."""
    keys = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
            "GH_HOST", "GH_CONFIG_DIR", "GH_PROMPT_DISABLED", "GH_DEBUG")
    previous = {key: os.environ.get(key) for key in keys}
    with tempfile.TemporaryDirectory() as configuration:
        try:
            for key in keys:
                os.environ.pop(key, None)
            os.environ.update(GH_TOKEN=credential(path), GH_HOST="github.com",
                              GH_CONFIG_DIR=configuration, GH_PROMPT_DISABLED="1")
            yield
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None  # Never send an API key to a redirect target, including same-origin.


class ApiError(RuntimeError):
    def __init__(self, status, auth_error=None):
        self.status = status
        self.auth_error = auth_error if auth_error in ("INVALID_CREDENTIALS", "FORCE_PASSWORD_CHANGE") else None
        super().__init__("Dependency-Track HTTP " + str(status))


class Client:
    def __init__(self, url, key_file=None, *, bearer=False, anonymous=False):
        parsed = urlsplit(url)
        if (parsed.scheme not in ("https", "http") or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or parsed.query or parsed.fragment or parsed.path not in ("", "/")):
            raise ValueError("API URL must be an origin without credentials, path, query or fragment")
        if parsed.scheme == "http" and parsed.hostname not in ("127.0.0.1", "::1", "localhost"):
            raise ValueError("unencrypted API is allowed only over loopback")
        self.url = url.rstrip("/")
        self.key = None if anonymous else credential(key_file)
        self.bearer = bearer
        self.opener = build_opener(NoRedirect())
        self.deadline = None

    def request(self, method, path, data=None, *, version=1, form=False, text=False,
                anonymous=False, expected_status=None):
        payload = None if data is None else (urlencode(data) if form else json.dumps(data)).encode()
        auth = {} if anonymous or self.key is None else (
            {"Authorization": "Bearer " + self.key} if self.bearer else {"X-Api-Key": self.key})
        request = Request(self.url + "/api/v" + str(version) + "/" + path, payload, method=method,
                          headers={**auth, "Content-Type": "application/x-www-form-urlencoded" if form
                                   else "application/json"})
        timeout = 30 if self.deadline is None else min(30, self.deadline - time.monotonic())
        if timeout <= 0:
            raise TimeoutError("access-policy deadline elapsed")
        try:
            with self.opener.open(request, timeout=timeout) as response:
                if expected_status is not None and response.status != expected_status:
                    raise ApiError(response.status)
                body = response.read()
                return body.decode("utf-8") if text else json.loads(body) if body else None
        except HTTPError as error:
            # Stock project PATCH returns 304 when the requested state already holds.
            if error.code == 304 and method == "PATCH" and re.fullmatch(r"project/[0-9a-fA-F-]{36}", path):
                return None
            # Retain only these exact stock login outcomes, never arbitrary server text.
            auth_error = None
            if method == "POST" and path == "user/login" and error.code == 401:
                body = error.read(64)
                if body in (b"INVALID_CREDENTIALS", b"FORCE_PASSWORD_CHANGE"):
                    auth_error = body.decode("ascii")
            # Server bodies/redirect locations and request headers may contain secrets.
            raise ApiError(error.code, auth_error) from None
        except URLError:
            raise RuntimeError("Dependency-Track connection failed") from None
        except ValueError:
            # urllib's invalid-header exception can contain the header value.
            raise RuntimeError("invalid API request or response") from None

    def properties(self, project, values):
        path = "project/" + project + "/property"
        existing = {item["propertyName"]: item for item in self.request("GET", path)
                    if item["groupName"] == GROUP}
        for key, value in values.items():
            value = json.dumps(value, sort_keys=True) if not isinstance(value, str) else value
            if key in existing and existing[key]["propertyValue"] == value:
                continue
            self.request("POST" if key in existing else "PUT", path,
                         {"groupName": GROUP, "propertyName": key, "propertyValue": value,
                          "propertyType": "STRING"})

    def project(self, name, version, parent=None, collection=False, cached=None, *, identity):
        marker = OWNER + ":" + identity
        if cached:
            project = self.request("GET", "project/" + cached)
        else:
            try:
                project = self.request("GET", "project/lookup?" + urlencode({"name": name, "version": version}))
            except ApiError as error:
                if error.status != 404:
                    raise
                body = {"name": name, "version": version, "classifier": "APPLICATION",
                        "active": collection, "isLatest": False,
                        "description": "Advisory coverage is partial; zero findings is not a clean scan. Deployment unobserved. " + marker}
                if parent:
                    body["parent"] = {"uuid": parent}
                if collection:
                    body["collectionLogic"] = "AGGREGATE_LATEST_VERSION_CHILDREN"
                project = self.request("PUT", "project", body)
            else:
                # Lookup omits hierarchy; check the full resource before adopting it.
                project = self.request("GET", "project/" + project["uuid"])
        if (project.get("name") != name or project.get("version") != version
                or (cached and project.get("uuid") != cached)
                or (project.get("parent") or {}).get("uuid") != parent
                or project.get("collectionLogic") != ("AGGREGATE_LATEST_VERSION_CHILDREN" if collection else None)
                or not project.get("description", "").endswith(marker)):
            raise ValueError("project identity/ownership/parent/layout mismatch; refusing lifecycle mutation")
        return project["uuid"]

    def upload(self, project, file, timeout):
        result = self.request("PUT", "bom", {"project": project,
                              "bom": base64.b64encode(file.read_bytes()).decode()})
        token = result["token"]
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", token):
            raise ValueError("malformed upload token")
        deadline = time.monotonic() + timeout
        while True:
            result = self.request("GET", "bom/token/" + token)
            if not result.get("processing"):
                if result.get("status") != "COMPLETED":
                    raise RuntimeError("BOM import did not complete successfully (unknown/failed token)")
                return
            if time.monotonic() >= deadline:
                raise TimeoutError("BOM import completion deadline exceeded; previous current retained")
            time.sleep(min(2, max(0, deadline - time.monotonic())))


def set_leaf_state(client, record, snapshot, stream, active):
    project = snapshot["projects"][stream]
    client.project(project_name(record["source"], snapshot["revisionId"], stream), "inventory",
                   record["collection"], cached=project,
                   identity=project_identity(record["source"], snapshot["revisionId"], stream))
    client.request("PATCH", "project/" + project, {"active": active, "isLatest": active})


def promote(client, record, checkpoint):
    """Union-first transition, journaled for resumption; not multi-request atomic."""
    pending = record["pending"]
    if (set(pending["complete"]) != set(pending["hashes"])
            or set(pending["projects"]) != set(pending["hashes"])):
        raise ValueError("cannot promote an incomplete snapshot")
    for stream in pending["projects"]:
        set_leaf_state(client, record, pending, stream, True)
    old = record.get("current")
    record["retiring"] = sorted((set(record.get("retiring", []))
                                 | (set(old["projects"].values()) if old else set()))
                                - set(pending["projects"].values()))
    record["current"] = pending
    record.pop("pending")
    checkpoint()  # New complete current is durable before any old leaf is retired.
    retire_history(client, record, checkpoint)


def retire_history(client, record, checkpoint):
    for project in list(record.get("retiring", [])):
        candidates = [record.get("current"), record.get("pending"), *record["history"]]
        known = next(((snapshot, stream) for snapshot in candidates if snapshot
                      for stream, uuid in snapshot["projects"].items() if uuid == project), None)
        if known is None:
            raise ValueError("retiring project has no journaled software identity")
        set_leaf_state(client, record, *known, False)
        record["retiring"].remove(project)
        checkpoint()


def synchronize(args, database, checkpoint, client, *, expected_target=None):
    archived, provenance, manifest, description = archive_inventory(args.inventory, args.state_dir)
    target = description["target"]
    if expected_target is not None and target != expected_target:
        raise ValueError("admitted archive belongs to another lifecycle target")
    record = database["targets"].setdefault(target, {"source": provenance, "history": [], "receipts": []})
    record["input"] = str(args.inventory)
    if str(archived) not in record["receipts"]:
        record["receipts"].append(str(archived))
    record["lastAttempt"] = {"at": now(), "status": "staging", "archive": str(archived)}
    checkpoint()
    try:
        pending = record.get("pending")
        current = record.get("current")
        if pending and (pending["revision"] != description["revision"] or pending["contentHashes"] != description["contentHashes"]):
            raise ValueError("an interrupted revision is pending; resume the same inventory content first")
        known = next((item for item in [current, *record["history"]]
                      if item and item["revision"] == description["revision"]), None)
        if known and known["contentHashes"] != description["contentHashes"]:
            raise ValueError("same software revision has different inventory content; current retained, archive preserved")
        collection = client.project(project_name(provenance), "collection", collection=True,
                                    cached=record.get("collection"), identity=project_identity(provenance))
        record["collection"] = collection
        client.properties(collection, {"owner": OWNER, "target": target, "deployment": "unobserved"})
        if current and current["revision"] == description["revision"]:
            for stream in current["projects"]:
                set_leaf_state(client, record, current, stream, True)
            retire_history(client, record, checkpoint)
        else:
            if not pending:
                pending = {key: description[key] for key in ("revision", "revisionId", "hashes", "contentHashes")}
                pending.update(projects=dict(known["projects"]) if known else {},
                               complete=list(known["complete"]) if known else [],
                               archive=known["archive"] if known else str(archived))
                if known:
                    pending["hashes"] = dict(known["hashes"])
                record["pending"] = pending
                checkpoint()
            import_archive = Path(pending["archive"])
            import_manifest = load(import_archive / "complete.json")
            if import_archive != archived:
                security_artifacts.verify(import_archive, import_manifest["inventoryKey"])
            for stream, filename in description["streams"].items():
                name = project_name(provenance, description["revisionId"], stream)
                if stream not in pending["projects"]:
                    pending["projects"][stream] = client.project(
                        name, "inventory", collection, identity=project_identity(provenance, description["revisionId"], stream))
                    checkpoint()
                else:
                    client.project(name, "inventory", collection, cached=pending["projects"][stream],
                                   identity=project_identity(provenance, description["revisionId"], stream))
                project = pending["projects"][stream]
                client.properties(project, {"owner": OWNER, "revision": description["revision"],
                    "stream": stream, "source_scope": provenance["state"], "deployment": "unobserved",
                    "coverage_warning": security_artifacts.NATIVE_WARNING if stream == "native" else
                        "Trivy detects executable metadata, package metadata and dependency declarations. Presence is not execution, reachability, complete advisory coverage or a clean/nonaffected verdict.",
                    "source_target": provenance.get("target", provenance["source"]),
                    "source_system": provenance["system"], "source_mapping": {key: provenance.get(key) for key in
                        ("state", "realization", "drvPath", "outPath", "source", "pointer", "location", "update", "image", "resolvedImage", "ociPlatform", "sourceRevision", "sourceNarHash", "requestedByRevision", "requestedSourceNarHash", "collectedAt")},
                    "target_associations": provenance.get("references", []) if provenance["kind"] == "oci" else [provenance["target"]],
                    "import_sha256": pending["hashes"][stream], "inventory_key": import_manifest["inventoryKey"],
                    "archive_seal_sha256": import_archive.name})
                if stream not in pending["complete"]:
                    client.upload(project, import_archive / filename, args.timeout)
                    pending["complete"].append(stream)
                    checkpoint()
            if current and current not in record["history"]:
                record["history"].append(current)
            promote(client, record, checkpoint)
        completed_at = now()
        client.properties(collection, {"current_revision": description["revision"], "collection_status": "complete",
            "last_success": completed_at, "deployment": "unobserved", "source": {
                key: provenance.get(key) for key in ("id", "kind", "system", "target", "state", "source", "pointer", "references", "location", "update")
                if key != "references" or provenance["kind"] == "oci"}})
        record["source"] = provenance
        record["lastSuccess"] = completed_at
        record["statusPublishFailed"] = False
        record["lastAttempt"]["status"] = "complete"
        checkpoint()
        print(json.dumps({"target": target, "revision": description["revision"], "status": "complete",
                          "projects": record["current"]["projects"], "archive": str(archived),
                          "deployment": "unobserved"}))
    except Exception:
        record["lastAttempt"]["status"] = "failed-unknown"
        checkpoint()
        raise


def annotate_origins(args, database, checkpoint, client):
    """Enrich an owned current native view; never replace its original sealed input."""
    archived, provenance, manifest, description = archive_inventory(args.inventory, args.state_dir)
    record = database["targets"].get(description["target"])
    current = record.get("current") if record else None
    if (not current or provenance["kind"] != "nix"
            or current["revision"] != description["revision"]
            or current["contentHashes"] != description["contentHashes"]
            or "native" not in current["projects"]):
        raise ValueError("origins require the exact already-imported current Nix inventory")
    client.project(project_name(provenance), "collection", collection=True,
                   cached=record["collection"], identity=project_identity(provenance))
    project = client.project(project_name(provenance, current["revisionId"], "native"), "inventory",
                             record["collection"], cached=current["projects"]["native"],
                             identity=project_identity(provenance, current["revisionId"], "native"))
    journal = record.setdefault("origins", {})
    journal["lastAttempt"] = {"at": now(), "status": "collecting"}
    checkpoint()
    try:
        origins = homelab_origins.collect(args.flake, provenance)
        enriched, report = homelab_origin_bom.enrich(
            load(archived / "native-identity.cdx.json"), load(archived / "closure.json"), origins)
        # Display-only changes must not overwrite the last-good projection's evidence.
        directory = args.state_dir / "origins" / identity([description["target"], current["revision"], report, enriched])
        directory.mkdir(parents=True, exist_ok=True)
        save(directory / "origins.json", report)
        save(directory / "native-origins.cdx.json", enriched)
        receipt = {"source": origins["source"], "coverage": origins["coverage"],
                   "originalArchive": str(archived), "inventoryKey": manifest["inventoryKey"],
                   "project": project, "directory": str(directory),
                   "reportSha256": security_artifacts.digest(directory / "origins.json"),
                   "bomSha256": security_artifacts.digest(directory / "native-origins.cdx.json")}
        journal["lastAttempt"].update(status="importing", **receipt)
        checkpoint()
        client.upload(project, directory / "native-origins.cdx.json", args.timeout)
        client.properties(project, {"origin_source": origins["source"], "origin_coverage": origins["coverage"],
                                    "origin_bom_sha256": receipt["bomSha256"],
                                    "origin_report_sha256": receipt["reportSha256"]})
        journal["current"] = dict(receipt, completedAt=now())
        journal["lastAttempt"]["status"] = "complete"
        checkpoint()
        print(json.dumps({"target": provenance["target"], "project": project, "status": "complete",
                          "directory": str(directory), "coverage": origins["coverage"]}))
    except Exception as error:
        journal["lastAttempt"].update(status="failed-unknown", errorType=type(error).__name__)
        checkpoint()
        raise


def failed_target(record, attempt, client):
    record["lastAttempt"] = dict(attempt)
    if record.get("collection"):
        try:
            client.project(project_name(record["source"]), "collection", collection=True,
                           cached=record["collection"], identity=project_identity(record["source"]))
            client.properties(record["collection"], {"collection_status": attempt["status"],
                              "last_attempt": attempt["at"], "deployment": "unobserved"})
            record["statusPublishFailed"] = False
        except Exception:
            record["statusPublishFailed"] = True


def refresh(args, database, checkpoint, client):
    """Acquire data only, then use the existing resumable single-writer lifecycle."""
    policy = {"repository": args.repository, "branch": args.branch}
    states = sorted(set(getattr(args, "scope", None) or ["desired", "referenced"]))
    run_id = getattr(args, "run_id", None)
    selection = {"states": states if not args.target else [], "targetIds": sorted(set(args.target))}
    if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository)
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./-]*", args.branch)
            or ".." in args.branch or "//" in args.branch
            or any(not re.fullmatch(r"[a-f0-9]{24}", target) for target in args.target)
            or set(states) - {"desired", "exported", "referenced"}
            or not 1 <= args.max_age_seconds <= 90 * 86400
            or (run_id is not None and (type(run_id) is not int or run_id <= 0))):
        raise ValueError("invalid explicit producer policy, target selection or freshness bound")
    # Stock project properties are limited to 1024 characters; exact policies stay in the journal.
    selection_reference = {"states": selection["states"], "explicitTargetCount": len(selection["targetIds"]),
                           "sha256": identity(selection)}
    previous_source = database.get("sourcePolicy", policy)
    if {key: previous_source.get(key) for key in policy} != policy:
        raise ValueError("state belongs to another source trust policy; use separate API/evidence state for canaries")
    previous_selection = database.get("selectionPolicy")
    if previous_selection is None and "targetIds" in previous_source:
        previous_selection = {"states": [] if previous_source["targetIds"] else ["desired", "exported", "referenced"],
                              "targetIds": previous_source["targetIds"]}
    if previous_selection is not None and previous_selection != selection:
        database.setdefault("selectionHistory", []).append(
            {"at": now(), "previous": previous_selection, "current": selection})
    database["sourcePolicy"] = policy
    database["selectionPolicy"] = selection
    attempt = {"at": now(), "status": "discovering", "operation": "discover", "targets": {}, "selection": selection}
    if run_id is not None:
        attempt["requestedRun"] = run_id
    database["refresh"] = attempt
    checkpoint()
    def selected(entry):
        return entry["id"] in args.target if args.target else entry["state"] in states
    try:
        evidence = args.state_dir / "acquisitions"
        evidence.mkdir(exist_ok=True)
        archives = args.state_dir / "artifacts"
        archives.mkdir(exist_ok=True)
        directory = Path(tempfile.mkdtemp(prefix="refresh-", dir=evidence))
        attempt["evidence"] = str(directory)
        checkpoint()
        with github_credentials(args.github_token_file), tempfile.TemporaryDirectory(prefix="dependency-track-refresh-") as temporary:
            plan, receipt, artifacts = security_artifacts.discover_plan(
                args.repository, args.branch, directory, archive_directory=archives, run_id=run_id)
            attempt["run"] = receipt["run"]["id"]
            attempt["operation"] = "admit-plan"
            attempt["sourceCompletedAt"] = receipt["run"]["updated_at"]
            completed = datetime.fromisoformat(receipt["run"]["updated_at"].replace("Z", "+00:00"))
            age = (datetime.now(timezone.utc) - completed).total_seconds()
            if not 0 <= age <= args.max_age_seconds:
                raise ValueError("completed producer run is stale or future-dated")
            all_entries = [*plan["entries"], *plan["unsupported"]]
            attempt["excluded"] = [entry for entry in all_entries if not selected(entry)]
            attempt["unsupported"] = [{"source": entry, "selected": selected(entry)} for entry in plan["unsupported"]]
            if set(args.target) - {entry["id"] for entry in all_entries}:
                raise ValueError("configured target IDs are absent from the producer plan")
            if not any(selected(entry) for entry in plan["entries"]):
                raise ValueError("configured scope has no importable targets; zero-target success is not coverage")
            previous = database.get("expected", {})
            expected = {target_key(entry): {"source": entry, "selected": selected(entry),
                                            "coverage": "pending-unknown" if selected(entry) else "unselected"}
                        for entry in all_entries}
            if len(expected) != len(all_entries):
                raise ValueError("producer plan aliases multiple declarations to one lifecycle target")
            for target, old in previous.items():
                if target not in expected:
                    expected[target] = dict(old, selected=selected(old["source"]), coverage="missing-from-plan-unknown")
            for target, record in database["targets"].items():
                if target not in expected:
                    expected[target] = {"source": record["source"], "selected": selected(record["source"]),
                                        "coverage": "missing-from-plan-unknown"}
                record["selection"] = {"at": now(), "selected": expected[target]["selected"]}
                if not expected[target]["selected"] and record.get("collection"):
                    try:
                        client.project(project_name(record["source"]), "collection", collection=True,
                                       cached=record["collection"], identity=project_identity(record["source"]))
                        client.properties(record["collection"], {"selection_status": "unselected-retained",
                                          "selection_policy": selection_reference, "deployment": "unobserved"})
                    except Exception:
                        record["selection"]["statusPublishFailed"] = True
                        attempt.setdefault("selectionPublishFailures", []).append(target)
            database["expected"] = expected
            checkpoint()
            attempt["operation"] = "targets"
            for target, item in expected.items():
                entry = item["source"]
                if not item["selected"]:
                    continue  # Explicit scope changes retain current/history and active DT data.
                result = {"at": now(), "status": "failed-unknown", "operation": "admit-declaration"}
                attempt["targets"][target] = result
                try:
                    if item["coverage"] == "missing-from-plan-unknown":
                        raise ValueError("previously tracked declaration disappeared from the plan")
                    if entry not in plan["entries"]:
                        if entry.get("inventoryFailure"):
                            raise ValueError("producer failed to discover the selected inventory")
                        result["status"] = item["coverage"] = "unsupported-unknown"
                        if target in database["targets"]:
                            failed_target(database["targets"][target], result, client)
                        checkpoint()
                        continue
                    inventory = Path(temporary) / target
                    result["operation"] = "acquire"
                    artifact = security_artifacts.acquire_planned(
                        entry, receipt, artifacts, args.repository, inventory, archive_directory=archives)
                    save(directory / (target + "-artifact.json"), artifact)
                    options = argparse.Namespace(**vars(args))
                    pending = database["targets"].get(target, {}).get("pending")
                    if pending:
                        # Resume only the previously admitted journaled original, once,
                        # before moving to a newer producer inventory.
                        options.inventory = Path(pending["archive"])
                        result["operation"] = "resume-pending"
                        synchronize(options, database, checkpoint, client, expected_target=target)
                    options.inventory = inventory
                    result["operation"] = "import"
                    synchronize(options, database, checkpoint, client, expected_target=target)
                    if target in database["targets"]:
                        result["operation"] = "publish-metadata"
                        acquisition = {"repository": args.repository, "branch": args.branch,
                                       "run": receipt["run"]["id"], "sha": receipt["run"]["head_sha"],
                                       "completedAt": receipt["run"]["updated_at"], "artifact": artifact,
                                       "evidence": str(directory)}
                        database["targets"][target]["acquisition"] = acquisition
                        database["targets"][target]["selection"] = {"at": now(), "selected": True}
                        client.properties(database["targets"][target]["collection"], {
                            "source_run": {**{key: acquisition[key] for key in ("repository", "run", "sha", "completedAt")},
                                           "sourcePolicySha256": identity(policy)},
                            "selection_status": "selected", "selection_policy": selection_reference})
                        checkpoint()
                    if entry["kind"] == "nix" and homelab_origins.supported(entry):
                        if args.repository != "dvicory/homelab":
                            raise ValueError("host origins require the explicitly trusted Homelab repository")
                        options.flake = "github:dvicory/homelab/" + receipt["run"]["head_sha"]
                        result["operation"] = "host-origins"
                        annotate_origins(options, database, checkpoint, client)
                    elif target in database["targets"]:
                        database["targets"][target]["origins"] = {
                            "lastAttempt": {"at": now(), "status": "unsupported",
                                            "reason": "only NixOS toplevel roots support inclusion origins"}}
                    result.update(status="complete", operation="complete")
                    item["coverage"] = "complete-inventory"
                except Exception as error:
                    result["errorType"] = type(error).__name__
                    if isinstance(error, ApiError):
                        result["httpStatus"] = error.status
                    item["coverage"] = ("missing-from-plan-unknown" if item["coverage"] == "missing-from-plan-unknown"
                                        else "failed-unknown")
                    if target in database["targets"]:
                        failed_target(database["targets"][target], result, client)
                checkpoint()
        attempt["operation"] = "finalize"
        if (attempt.get("selectionPublishFailures") or any(
                result["status"] not in ("complete", "unsupported-unknown")
                or database["targets"].get(target, {}).get("statusPublishFailed", False)
                for target, result in attempt["targets"].items())):
            raise ValueError("refresh has missing or failed targets; last-good inventories retained")
        attempt["status"] = ("complete-with-unsupported" if any(item["selected"] for item in attempt["unsupported"])
                             else "complete")
        attempt["operation"] = "complete"
        checkpoint()
        print(json.dumps({"status": attempt["status"], "run": attempt["run"], "evidence": str(directory),
                          "targets": len(attempt["targets"]), "excluded": len(attempt["excluded"]),
                          "unsupported": len(attempt["unsupported"]), "deployment": "unobserved"}))
    except Exception as error:
        attempt.update(status="failed-unknown", errorType=type(error).__name__)
        for target, item in database.get("expected", {}).items():
            if target not in attempt["targets"] and item.get("selected", True):
                item["coverage"] = "failed-unknown"
        for target, record in database["targets"].items():
            if target not in attempt["targets"] and selected(record["source"]):
                failed_target(record, {"at": now(), "status": "failed-unknown"}, client)
        checkpoint()
        raise




def configure_advisory_policy(client):
    policy = load(Path(__file__).with_name("advisory-policy.json"))
    for name, wanted in policy.items():
        path = "extension-points/vuln-data-source/extensions/" + name + "/config"
        if client.request("GET", path, version=2)["config"] != wanted:
            try:
                client.request("PUT", path, {"config": wanted}, version=2)
            except ApiError as error:
                if error.status != 304:
                    raise
        if client.request("GET", path, version=2)["config"] != wanted:
            raise ValueError("advisory policy readback mismatch: " + name)
    return {"advisorySources": {name: {"enabled": config["enabled"],
            "ecosystems": config.get("ecosystems", [])} for name, config in policy.items()},
            "coverage": "Enabled sources do not prove completed mirrors, Nix patch applicability, runtime use or a clean scan."}


@contextmanager
def managed_session(client, password, *, bootstrap=False):
    """Own only the session created here, including an unexpectedly accepted default."""
    def login():
        return client.request("POST", "user/login", {"username": "admin", "password": password},
                              form=True, text=True, anonymous=True, expected_status=200)

    try:
        token = login()
    except ApiError as error:
        if not bootstrap or error.status != 401 or error.auth_error != "INVALID_CREDENTIALS":
            raise
        client.request("POST", "user/forceChangePassword",
                       {"username": "admin", "password": "admin", "newPassword": password,
                        "confirmPassword": password}, form=True, text=True, anonymous=True,
                       expected_status=200)
        # Stock password change returns an empty 200, not a session.
        token = login()
    previous = client.key, client.bearer
    client.key, client.bearer = token, True
    try:
        if not re.fullmatch(r"[\x21-\x7e]{1,65536}", token):
            raise ValueError("invalid managed session")
        yield
    finally:
        previous_deadline = client.deadline
        client.deadline = time.monotonic() + 10
        handlers = {signum: signal.signal(signum, signal.SIG_IGN)
                    for signum in (signal.SIGTERM, signal.SIGINT)}
        try:
            client.request("POST", "user/logout", expected_status=204)
        finally:
            client.key, client.bearer = previous
            client.deadline = previous_deadline
            for signum, handler in handlers.items():
                signal.signal(signum, handler)


def access_uuid(item):
    value = item["uuid"]
    if not isinstance(value, str) or not re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", value):
        raise ValueError("invalid access resource identity")
    return value


def permission_names(items):
    if not isinstance(items, list):
        raise ValueError("invalid permission list")
    names = [item["name"] for item in items]
    if any(not isinstance(name, str) or not re.fullmatch(r"[A-Z][A-Z_]*", name) for name in names):
        raise ValueError("invalid permission name")
    if len(set(names)) != len(names):
        raise ValueError("duplicate permissions")
    return set(names)


def administrator_team(client):
    teams = {}
    # Read through the empty final page, not just the page containing Administrators.
    for page in range(1, 1001):
        batch = client.request("GET", "team?" + urlencode(
            {"pageNumber": page, "pageSize": 100, "sortName": "name", "sortOrder": "asc"}))
        if not isinstance(batch, list):
            raise ValueError("invalid team page")
        if not batch:
            break
        for team in batch:
            uuid = access_uuid(team)
            if uuid in teams:
                raise ValueError("team pagination repeated a resource")
            teams[uuid] = team
    else:
        raise ValueError("team pagination exceeded safety bound")
    matches = [team for team in teams.values() if team.get("name") == "Administrators"]
    if len(matches) != 1:
        raise ValueError("existing administrator team is not unique")
    uuid = access_uuid(matches[0])
    team = client.request("GET", "team/" + uuid)
    if access_uuid(team) != uuid or team.get("name") != "Administrators":
        raise ValueError("administrator team readback mismatch")
    catalog = permission_names(client.request("GET", "permission"))
    if (not {"ACCESS_MANAGEMENT", "SYSTEM_CONFIGURATION"} <= catalog
            or permission_names(team.get("permissions")) != catalog):
        raise ValueError("administrator team does not hold the complete real permission catalog")
    effective = client.request("GET", "user/self/permissions")
    if not isinstance(effective, list) or not all(isinstance(name, str) for name in effective) or not catalog <= set(effective):
        raise ValueError("managed administrator lacks real administrator privileges")
    return {"name": "Administrators", "uuid": uuid, "permissions": sorted(catalog)}


def oidc_admin_group(client, name, team_uuid, *, require_mapping=False):
    groups = client.request("GET", "oidc/group")  # This stock endpoint is explicitly unpaginated.
    if not isinstance(groups, list):
        raise ValueError("invalid OIDC group list")
    ids, names = set(), set()
    wanted = None
    for group in groups:
        uuid = access_uuid(group)
        group_name = group["name"]
        if not isinstance(group_name, str) or uuid in ids or group_name in names:
            raise ValueError("invalid or duplicate OIDC group")
        ids.add(uuid)
        names.add(group_name)
        mapped = client.request("GET", "oidc/group/" + uuid + "/team")
        if not isinstance(mapped, list):
            raise ValueError("invalid OIDC team mapping")
        mapped_ids = {access_uuid(team) for team in mapped}
        if group_name != name:
            for mapped_uuid in mapped_ids:
                if mapped_uuid == team_uuid:
                    raise ValueError("unauthorized OIDC administrator binding; refusing to delete unrelated mappings")
                team = client.request("GET", "team/" + mapped_uuid)
                if (access_uuid(team) != mapped_uuid
                        or {"ACCESS_MANAGEMENT", "ACCESS_MANAGEMENT_CREATE", "ACCESS_MANAGEMENT_UPDATE"}
                        & permission_names(team.get("permissions"))):
                    raise ValueError("unauthorized OIDC access-management binding; refusing to delete unrelated mappings")
        if group_name == name:
            wanted = {"name": name, "uuid": uuid}
            if require_mapping and team_uuid not in mapped_ids:
                raise ValueError("OIDC administrator mapping readback mismatch")
    if require_mapping and wanted is None:
        raise ValueError("OIDC group readback mismatch")
    return wanted


def configure_access(args):
    password = credential(args.admin_password_file, password=True)
    if password.strip() == "admin":
        raise ValueError("recovery administrator password must not be the stock default")
    if (not 1 <= len(args.oidc_group) <= 255 or not args.oidc_group.strip()
            or re.search(r"[\x00-\x1f\x7f-\x9f]", args.oidc_group)):
        raise ValueError("OIDC group must be a bounded nonblank name without control characters")
    client = Client(args.api_url, anonymous=True)
    client.deadline = time.monotonic() + 90
    def cancelled(signum, frame):
        raise TimeoutError("access-policy reconciliation cancelled")
    handlers = {signum: signal.signal(signum, cancelled)
                for signum in (signal.SIGTERM, signal.SIGINT)}
    try:
        with managed_session(client, password, bootstrap=args.bootstrap):
            if client.request("GET", "user/self").get("username") != "admin":
                raise ValueError("managed session is not the recovery administrator")
            team = administrator_team(client)
            try:
                with managed_session(client, "admin"):
                    raise ValueError("stock default administrator credentials remain active")
            except ApiError as error:
                if error.status != 401 or error.auth_error != "INVALID_CREDENTIALS":
                    raise
            group = oidc_admin_group(client, args.oidc_group, team["uuid"])
            policy = configure_advisory_policy(client)
            if group is None:
                created = client.request("PUT", "oidc/group", {"name": args.oidc_group})
                if created.get("name") != args.oidc_group:
                    raise ValueError("created OIDC group name mismatch")
                group = {"name": args.oidc_group, "uuid": access_uuid(created)}
            client.request("PUT", "oidc/mapping", {"team": team["uuid"], "group": group["uuid"]})
            observed = oidc_admin_group(client, args.oidc_group, team["uuid"], require_mapping=True)
            if observed != group:
                raise ValueError("OIDC group identity changed during reconciliation")
            result = {"schema": 1, "oidcGroup": group, "administratorTeam": team,
                      "defaultLoginRefusal": "INVALID_CREDENTIALS", "advisoryPolicy": policy}
        return result
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    sync = commands.add_parser("sync", help="archive and ingest one admitted complete sealed inventory")
    sync.add_argument("--api-url", required=True, help="HTTPS origin, or HTTP loopback origin; no /api suffix")
    sync.add_argument("--api-key-file", required=True, type=Path)
    sync.add_argument("--inventory", required=True, type=Path)
    sync.add_argument("--state-dir", required=True, type=Path)
    sync.add_argument("--timeout", type=int, default=180, help="per-upload processing deadline in seconds")
    automatic = commands.add_parser("refresh", help="acquire a trusted producer plan, import its selected sealed inventories and host origins")
    automatic.add_argument("--api-url", required=True)
    automatic.add_argument("--api-key-file", required=True, type=Path)
    automatic.add_argument("--state-dir", required=True, type=Path)
    automatic.add_argument("--repository", required=True)
    automatic.add_argument("--branch", default="main", help="explicit admin-owned source trust; use separate API/evidence state for canaries")
    automatic.add_argument("--run-id", type=int, help="pin one verified completed run for recovery or qualification; normal refresh follows latest")
    automatic.add_argument("--github-token-file", required=True, type=Path)
    automatic.add_argument("--target", action="append", default=[], help="explicit 24hex declaration IDs; overrides state selection")
    automatic.add_argument("--scope", action="append", choices=("desired", "referenced", "exported"),
                           help="repeat declared-state selection; default desired+referenced, never deployed")
    automatic.add_argument("--max-age-seconds", type=int, default=604800)
    automatic.add_argument("--timeout", type=int, default=180)
    origins = commands.add_parser("origins", help="add proven inclusion paths to an already-imported current Nix view")
    origins.add_argument("--api-url", required=True)
    origins.add_argument("--api-key-file", required=True, type=Path)
    origins.add_argument("--inventory", required=True, type=Path)
    origins.add_argument("--state-dir", required=True, type=Path)
    origins.add_argument("--timeout", type=int, default=180, help="BOM processing deadline in seconds")
    origins.add_argument("--flake", required=True,
                         help="explicitly trusted github:dvicory/homelab/<full SHA>; evaluated, never taken from inventory")
    acquire = commands.add_parser("acquire", help="download trusted workflow data using existing gh authentication")
    acquire.add_argument("--entry", required=True, type=Path, help="admitted resolved PR120 entry JSON, not downloaded code")
    acquire.add_argument("--repository", required=True)
    acquire.add_argument("--branch", default="main")
    acquire.add_argument("--output", required=True, type=Path, help="new sealed directory")
    status = commands.add_parser("status", help="show durable current/history, pending failures and freshness; no API mutation")
    status.add_argument("--state-dir", required=True, type=Path)
    status.add_argument("--max-age-seconds", type=int, default=86400)
    status.add_argument("--plan", type=Path, help="PR120 plan JSON: explicitly report missing/unsupported expected targets")
    configure = commands.add_parser("configure", help="apply the source-owned advisory policy; requires admin session")
    configure.add_argument("--api-url", required=True)
    configure.add_argument("--admin-session-file", required=True, type=Path)
    access = commands.add_parser("configure-access", help="reconcile private native administrator access; owns its ephemeral session")
    access.add_argument("--api-url", required=True)
    access.add_argument("--admin-password-file", required=True, type=Path)
    access.add_argument("--oidc-group", required=True)
    access.add_argument("--bootstrap", action="store_true", help="allow changing stock admin/admin only after intended login is rejected")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.command == "configure-access":
            print(json.dumps(configure_access(args)))
            return 0
        if args.command == "configure":
            client = Client(args.api_url, args.admin_session_file, bearer=True)
            print(json.dumps(configure_advisory_policy(client)))
            return 0
        if args.command == "acquire":
            if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository)
                    or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./-]*", args.branch)
                    or ".." in args.branch or "//" in args.branch or args.output.exists()):
                raise ValueError("acquisition requires an explicit repository, trusted branch and new output directory")
            entry = load(args.entry)
            if not all(re.fullmatch(r"[a-f0-9]{24}", entry.get(key, "")) for key in ("id", "inventoryKey")):
                raise ValueError("malformed admitted inventory identity")
            security_artifacts.restore(entry, args.output, args.repository, args.branch)
            if not args.output.exists():
                raise ValueError("missing trusted inventory; no collection or execution fallback")
            return 0
        if args.command == "status":
            path = args.state_dir / "state.json"
            database = load(path) if path.exists() else {"schema": 1, "targets": {}}
            if args.max_age_seconds < 0:
                raise ValueError("freshness age must be nonnegative")
            for record in database["targets"].values():
                last = record.get("acquisition", {}).get("completedAt", record.get("lastSuccess"))
                record["coverage"] = ("unknown" if not last else "stale" if
                    (datetime.now(timezone.utc) - datetime.fromisoformat(last)).total_seconds() > args.max_age_seconds
                    else "unsupported-unknown" if record.get("lastAttempt", {}).get("status") == "unsupported-unknown"
                    else "failed-unknown" if record.get("lastAttempt", {}).get("status") != "complete"
                    else "complete-inventory")
                origins = record.get("origins", {}).get("lastAttempt", {}).get("status")
                if origins and origins not in ("complete", "unsupported"):
                    record["coverage"] = "failed-unknown"
                record["deployment"] = "unobserved"
            if isinstance(database.get("expected"), dict):
                for target, item in database["expected"].items():
                    if item["coverage"] == "complete-inventory":
                        item["coverage"] = database["targets"].get(target, {}).get("coverage", "missing-unknown")
            if args.plan:
                plan = load(args.plan)
                database["expected"] = [
                    {"source": entry, "coverage": database["targets"].get(target_key(entry), {}).get("coverage", "missing-unknown")}
                    for entry in plan["entries"]]
                database["expected"].extend({"source": entry, "coverage": "unsupported-unknown"}
                                            for entry in plan["unsupported"])
            print(json.dumps(database, indent=2))
            return 0
        if not 1 <= args.timeout <= 3600:
            raise ValueError("upload timeout must be between 1 and 3600 seconds")
        args.state_dir.mkdir(parents=True, exist_ok=True)
        # ponytail: one writer per state directory; separate controllers need a shared lease.
        with (args.state_dir / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state = args.state_dir / "state.json"
            database = load(state) if state.exists() else {"schema": 1, "targets": {}}
            checkpoint = lambda: save(state, database)
            client = None
            try:
                client = Client(args.api_url, args.api_key_file)
                if database.get("apiOrigin", client.url) != client.url:
                    raise ValueError("state belongs to a different API origin")
                database["apiOrigin"] = client.url
                if args.command == "refresh":
                    refresh(args, database, checkpoint, client)
                    return 0
                if args.command == "origins":
                    annotate_origins(args, database, checkpoint, client)
                    return 0
                database["lastInput"] = {"at": now(), "inventory": str(args.inventory), "status": "staging"}
                checkpoint()
                synchronize(args, database, checkpoint, client)
                database["lastInput"]["status"] = "complete"
                checkpoint()
            except Exception as error:
                if args.command in ("origins", "refresh"):
                    raise
                database["lastInput"] = {"at": now(), "inventory": str(args.inventory),
                                         "status": "missing-unknown" if isinstance(error, FileNotFoundError) else "failed-unknown",
                                         "errorType": type(error).__name__}
                for record in database["targets"].values():
                    if record.get("input") == str(args.inventory):
                        record["lastAttempt"] = dict(database["lastInput"])
                        if client and database.get("apiOrigin") == client.url and record.get("collection"):
                            try:
                                client.project(project_name(record["source"]), "collection", collection=True,
                                               cached=record["collection"], identity=project_identity(record["source"]))
                                client.properties(record["collection"], {
                                    "collection_status": database["lastInput"]["status"],
                                    "last_attempt": database["lastInput"]["at"], "deployment": "unobserved"})
                            except Exception:
                                record["statusPublishFailed"] = True
                checkpoint()
                raise
        return 0
    except Exception as error:
        # Do not stringify untrusted server/network exceptions or secret-file contents.
        if args.command == "configure-access":
            reason = ("HTTP " + str(error.status) + (" " + error.auth_error if error.auth_error else "")
                      if isinstance(error, ApiError) else type(error).__name__)
            print("dependency-track-sync failed: configure-access " + reason, file=sys.stderr)
            return 1
        print("dependency-track-sync failed: " + (str(error) if isinstance(error, (ValueError, ApiError, TimeoutError))
                                                  else type(error).__name__), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
