"""Selected-option inclusion evidence from an explicitly trusted frozen Homelab flake."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import quote


_PIN = re.compile(r"github:dvicory/homelab/([0-9a-f]{40})")
_TARGET = re.compile(r"nixosConfigurations\.([A-Za-z0-9_-]+)\.config\.system\.build\.toplevel")
_STORE = re.compile(r"/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+")
_REV = re.compile(r"[0-9a-f]{40}")
_NAR = re.compile(r"sha256-[A-Za-z0-9+/]{43}=")
_OPTIONS = ["environment.systemPackages", "systemd.package"]


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _store(value, derivation=False):
    if (not isinstance(value, str) or not _STORE.fullmatch(value)
            or value.endswith(".drv") != derivation):
        raise ValueError("invalid Nix derivation/output path")
    return value


def _relative(value):
    if (not isinstance(value, str) or not value or value.startswith("/")
            or any(part in ("", ".", "..") for part in value.split("/"))
            or any(ord(char) < 32 or ord(char) == 127 for char in value)):
        raise ValueError("invalid source-relative path")
    return value


def _source_prefix(value):
    if not isinstance(value, str) or not value.startswith("/nix/store/"):
        raise ValueError("invalid source store prefix")
    parts = value[len("/nix/store/"):].split("/", 1)
    _store("/nix/store/" + parts[0])
    if len(parts) == 2:
        _relative(parts[1])
    return value


def _file_in(prefix, filename):
    """Never turn lexical traversal or a symlink escape into a source URL."""
    if not isinstance(filename, str) or not filename.startswith(prefix + "/"):
        return None
    relative = _relative(filename[len(prefix) + 1:])
    root = Path(prefix).resolve(strict=True)
    path = Path(filename).resolve(strict=True)
    if not path.is_relative_to(root) or not path.is_file():
        raise ValueError("source file escapes supplying input or is not a regular file")
    return relative


def _nix_json(arguments):
    command = ["nix", *arguments, "--no-write-lock-file", "--option",
               "accept-flake-config", "false", "--option",
               "allow-import-from-derivation", "false", "--builders", ""]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode:
        raise ValueError("Nix origin query failed (exit " + str(result.returncode) + ")")
    return json.loads(result.stdout)


def _repository(locked, prefix):
    """Only known pinned repository sources can supply a GitHub blob URL."""
    revision = locked.get("rev")
    if not isinstance(revision, str) or not _REV.fullmatch(revision):
        return None
    if locked.get("type") == "github":
        owner, repo = locked.get("owner"), locked.get("repo")
        if any(not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", value)
               for value in (owner, repo)):
            return None
        return owner, repo, revision
    # NixOS release tarballs are the official nixpkgs source distribution. Its
    # embedded revision must corroborate the locked metadata, not a filename hint.
    url = locked.get("url", "")
    if (locked.get("type") == "tarball" and isinstance(url, str)
            and re.fullmatch(r"https://releases\.nixos\.org/nixos/[A-Za-z0-9._/-]+/nixexprs\.tar\.xz", url)
            and not any(part in (".", "..") for part in url.split("/"))):
        revision_file = Path(prefix) / ".git-revision"
        relative = _file_in(prefix, str(revision_file)) if revision_file.exists() else None
        if relative is not None and revision_file.read_text().strip() == revision:
            return "NixOS", "nixpkgs", revision
    return None


def _input_sources(metadata, evaluated):
    sources = {}
    nodes = metadata["locks"]["nodes"].values()
    for source in evaluated["inputs"]:
        prefix = _source_prefix(source["storePath"])
        candidates = set()
        for node in nodes:
            locked = node.get("locked", {})
            if (not source.get("revision") or not source.get("narHash")
                    or locked.get("rev") != source["revision"]
                    or locked.get("narHash") != source["narHash"]):
                continue
            directory = locked.get("dir", "")
            if directory:
                _relative(directory)
                # getFlake.outPath is the selected flake directory; the URL
                # must retain that directory relative to the repository.
                store_root = "/nix/store/" + prefix[len("/nix/store/"):].split("/", 1)[0]
                if prefix != store_root + "/" + directory:
                    continue
            repository = _repository(locked, prefix)
            if repository is not None:
                candidates.add((*repository, directory))
        if len(candidates) == 1:
            sources[prefix] = candidates.pop()
    return sources


def _location(filename, root, revision, sources):
    relative = _file_in(root, filename)
    if relative is not None:
        return "homelab", relative, "https://github.com/dvicory/homelab/blob/" + revision + "/" + quote(relative, safe="/")
    matches = [prefix for prefix in sources if isinstance(filename, str) and filename.startswith(prefix + "/")]
    if not matches:
        return "unresolved", None, None
    # A nested input wins over a containing input; a store hash is never guessed.
    prefix = max(matches, key=len)
    relative = _file_in(prefix, filename)
    owner, repo, source_revision, directory = sources[prefix]
    repository_file = directory + "/" + relative if directory else relative
    return ("upstream-definition", repository_file,
            "https://github.com/" + owner + "/" + repo + "/blob/" + source_revision + "/" + quote(repository_file, safe="/"))


def collect(flake: str, provenance: dict) -> dict:
    """Evaluate without builds; refuse any source, platform or inventory-root drift."""
    pin = _PIN.fullmatch(flake) if isinstance(flake, str) else None
    if pin is None:
        raise ValueError("origin source must be explicit github:dvicory/homelab/<full 40hex revision>")
    target = provenance.get("target")
    match = _TARGET.fullmatch(target) if isinstance(target, str) else None
    if provenance.get("kind") != "nix" or match is None:
        raise ValueError("unsupported origin target: only NixOS config.system.build.toplevel roots are supported")
    root = {"drvPath": _store(provenance.get("drvPath"), True),
            "outPath": _store(provenance.get("outPath"))}
    metadata = _nix_json(["flake", "metadata", "--json", flake])
    locked = metadata["locked"]
    store_path = _store(metadata["path"])
    if (locked.get("type") != "github" or locked.get("owner") != "dvicory"
            or locked.get("repo") != "homelab" or locked.get("rev") != pin[1]
            or not isinstance(locked.get("narHash"), str) or not _NAR.fullmatch(locked["narHash"])
            or locked.get("dir")):
        raise ValueError("actual source metadata does not match trusted Homelab pin")
    expected_source = {"storePath": store_path, "revision": pin[1], "narHash": locked["narHash"]}
    apply = "query: query { flake = builtins.getFlake " + json.dumps(flake) + "; host = " + json.dumps(match[1]) + "; }"
    evaluated = _nix_json(["eval", "--json", "--file", str(Path(__file__).with_name("homelab-origins.nix")), "--apply", apply])
    if evaluated["source"] != expected_source:
        raise ValueError("evaluated source differs from actual pinned flake metadata")
    evaluated_root = {"drvPath": evaluated["root"]["drvPath"], "outPath": evaluated["root"]["outputPath"]}
    if evaluated_root != root:
        raise ValueError("evaluated NixOS root drvPath/outPath differs from sealed inventory")
    if not provenance.get("system") or evaluated["system"] != provenance["system"]:
        raise ValueError("evaluated NixOS platform differs from sealed inventory")
    sources = _input_sources(metadata, evaluated)
    aspects = {}
    for aspect in evaluated["aspects"]:
        identity = aspect["identityKey"]
        if not isinstance(identity, str) or not identity:
            raise ValueError("invalid resolved Den identity")
        aspects.setdefault(identity, set()).add(aspect["file"])
    origins = {}
    for declaration in evaluated["origins"]:
        option, definition, package = (declaration[key] for key in ("option", "definition", "package"))
        if option not in _OPTIONS or not isinstance(definition, str) or not definition:
            raise ValueError("invalid option definition")
        _store(package["drvPath"], True)
        _store(package["outputPath"])
        if not isinstance(package.get("name"), str) or not package["name"]:
            raise ValueError("invalid declared package name")
        aspect = None
        filename = definition
        if definition.startswith("nixos@"):
            identity = definition[len("nixos@"):]
            filename = None
            if identity in aspects:
                aspect = identity
                files = aspects[identity]
                # Multiple different source sites for one identity are ambiguous.
                if len(files) == 1:
                    filename = next(iter(files))
        kind, source_file, source_url = _location(filename, store_path, pin[1], sources)
        origin = {"option": option, "definition": definition, "kind": kind,
                  "aspect": aspect, "sourceFile": source_file, "sourceUrl": source_url,
                  "package": {key: package[key] for key in ("name", "drvPath", "outputPath")}}
        identifier = hashlib.sha256(_canonical(origin).encode()).hexdigest()
        origins[identifier] = {"id": identifier, **origin}
    return {"schema": 1, "target": target, "root": root,
            "source": {"flake": flake, **expected_source},
            "coverage": {"options": list(_OPTIONS), "complete": False},
            "origins": [origins[key] for key in sorted(origins)]}
