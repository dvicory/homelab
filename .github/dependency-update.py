#!/usr/bin/env python3
"""Token-free preparation; bounded data-only publication. No candidate code runs on the host."""
import contextlib
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile


CHART = re.compile(r'lib\.helm\.downloadHelmChart\s*\{([^{}]*)\}', re.S)
GITHUB = re.compile(r'"github:[^"\s]+"')
CERT_IMAGE = re.compile(r'image "(quay\.io/jetstack/cert-manager-[a-z]+)" "(sha256:[a-f0-9]{64})"')
# Official nixos/nix 2.35.4 multi-platform index, resolved read-only on 2026-11-06.
NIX_IMAGE = "docker.io/nixos/nix@sha256:f159a58f390677f41e8e900a74b6e2f9c7f27b364122ae6acf7a652ce6c551c0"
TRUSTED_ROOT = pathlib.Path(__file__).resolve().parent.parent
CANDIDATES = TRUSTED_ROOT / ".github/dependency-update-candidates"
MAX_BYTES = 32 * 1024 * 1024
MAX_FILES = 4096


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def changed_paths():
    records = subprocess.check_output(["git", "diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "HEAD"]).split(b"\0")
    records += subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"]).split(b"\0")
    records += subprocess.check_output(["git", "ls-files", "--others", "-z", "--", "docs", "generated/manifests"]).split(b"\0")
    return {name.decode("utf-8") for name in records if name}


def field(text, name):
    match = re.search(r'\b' + re.escape(name) + r'\s*=\s*"([^"\n]+)";', text)
    if not match:
        raise ValueError(f"missing literal {name}")
    return match.group(1)


def charts(text):
    for match in CHART.finditer(text):
        block = match.group(1)
        if "version = chartVersion;" in block:
            version = field(text, "chartVersion")
        elif "inherit version;" in block:
            versions = re.findall(r'\bversion\s*=\s*"([^"\n]+)";', text)
            if len(versions) != 1:
                raise ValueError("inherited chart version must have one literal owner")
            version = versions[0]
        else:
            version = field(block, "version")
        yield match, field(block, "repo"), field(block, "chart"), version


def replace_hash(text, old, new):
    if not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", new):
        raise ValueError("invalid recursive SHA-256 from nix hash path")
    if text.count('"' + old + '"') != 1:
        raise ValueError("chart hash must have exactly one source owner")
    return text.replace('"' + old + '"', '"' + new + '"')


def refresh_cert_images(text):
    images = list(CERT_IMAGE.finditer(text))
    if len(images) != 5:
        raise ValueError("expected five cert-manager image owners")
    version = field(text, "version")
    for match in images:
        repository, old_digest = match.groups()
        if repository.endswith("-controller"):
            continue
        digest = run("skopeo", "--override-os", "linux", "--override-arch", "amd64",
                     "inspect", "--no-creds", "--format", "{{.Digest}}", f"docker://{repository}:{version}")
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            raise ValueError(f"invalid registry digest for {repository}")
        text = text.replace(match.group(0), f'image "{repository}" "{digest}"')
    return text


def safe_path(name):
    path = pathlib.PurePosixPath(name)
    return (bool(path.parts) and not path.is_absolute() and str(path) == name
            and not any(part.startswith(".") for part in path.parts)
            and not any(ord(c) < 32 or ord(c) == 127 for c in name)
            and path.name.lower() != "readme.md")


def generated_path(name):
    if not safe_path(name):
        return False
    path = pathlib.PurePosixPath(name)
    return name == "flake.lock" or (name.startswith("docs/") and path.suffix == ".md") or (
        name.startswith("generated/manifests/") and path.suffix in {".yaml", ".yml"})


def declaration_path(name):
    return generated_path(name) or (safe_path(name) and (
        name == "flake.nix" or name == "pkgs/by-name/jellyfin-provisioner-image/package.nix"
        or (name.startswith(("modules/meta/", "modules/den/", "modules/flake/")) and name.endswith(".nix"))))


def regular_path(name, missing=False):
    """lstat every ancestor: is_file follows symlinks and isn't an admission check."""
    path = pathlib.Path(name)
    for parent in reversed(path.parents):
        if parent == pathlib.Path("."):
            continue
        try:
            mode = parent.lstat().st_mode
        except FileNotFoundError:
            if missing:
                return
            raise
        if not stat.S_ISDIR(mode):
            raise ValueError(f"non-directory/symlink ancestor: {parent}")
        if not path.is_absolute() and ((parent / ".git").exists() or (parent / ".git").is_symlink()):
            raise ValueError(f"embedded repository: {parent}")
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        if missing:
            return
        raise
    if not stat.S_ISREG(mode):
        raise ValueError(f"candidate is not a regular file: {name}")
    if path.stat().st_size > MAX_BYTES:
        raise ValueError(f"candidate file exceeds 32 MiB: {name}")


def patch_paths(path, declarations=False):
    regular_path(str(path))
    if pathlib.Path(path).stat().st_size > MAX_BYTES:
        raise ValueError("candidate patch exceeds 32 MiB")
    stats = subprocess.check_output(["git", "apply", "--numstat", "-z", "--", str(path)])
    records = stats.split(b"\0")[:-1] if stats else []
    if len(records) > MAX_FILES:
        raise ValueError("candidate exceeds 4096 changed files")
    allowed = declaration_path if declarations else generated_path
    names = []
    for record in records:
        parts = record.split(b"\t", 2)
        if len(parts) != 3 or not parts[0].isdigit() or not parts[1].isdigit():
            raise ValueError("candidate must contain plain text, not renames or binary data")
        name = parts[2].decode("utf-8")
        if not allowed(name):
            raise ValueError(f"candidate path is not allowed: {name!r}")
        names.append(name)
    if len(names) != len(set(names)):
        raise ValueError("duplicate patch paths")
    return names


def index_regular(names):
    for name in names:
        entries = subprocess.check_output(["git", "ls-files", "--stage", "-z", "--", name]).split(b"\0")
        for entry in filter(None, entries):
            metadata, filename = entry.split(b"\t", 1)
            mode, _, stage = metadata.split()
            if mode != b"100644" or stage != b"0" or filename.decode() != name:
                raise ValueError(f"non-regular/conflicted candidate index entry: {name}")


def write_patch(path, declarations=False):
    names = changed_paths()
    allowed = declaration_path if declarations else generated_path
    if len(names) > MAX_FILES or not all(allowed(name) for name in names):
        raise ValueError("canonical writers changed files outside the bounded allowlist")
    for name in names:
        regular_path(name, missing=True)
    if names:
        subprocess.run(["git", "add", "--force", "--all", "--", *sorted(names)], check=True)
    index_regular(names)
    patch = subprocess.check_output(["git", "diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-renames", "HEAD"])
    if len(patch) > MAX_BYTES:
        raise ValueError("candidate patch exceeds 32 MiB")
    pathlib.Path(path).write_bytes(patch)
    if patch:
        patch_paths(path, declarations)


def apply_patch(path, declarations=False):
    if not pathlib.Path(path).stat().st_size:
        regular_path(str(path))
        return
    names = patch_paths(path, declarations)
    for name in names:
        regular_path(name, missing=True)
    # Validate resulting index modes BEFORE materializing anything on the publisher.
    subprocess.run(["git", "apply", "--cached", "--", str(path)], check=True)
    index_regular(names)
    for name in names:
        if run("git", "ls-files", "--", name):
            subprocess.run(["git", "checkout-index", "--force", "--", name], check=True)
            regular_path(name)
        else:
            pathlib.Path(name).unlink(missing_ok=True)


@contextlib.contextmanager
def disposable_source():
    """Private host index outside the only mount writable by candidate Nix."""
    source = pathlib.Path.cwd()
    base = run("git", "rev-parse", "HEAD")
    names = changed_paths()
    for name in names:
        if not declaration_path(name):
            raise ValueError(f"unexpected initial source change: {name}")
        regular_path(name, missing=True)
    patch = subprocess.check_output(["git", "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "HEAD"])
    if len(patch) > MAX_BYTES or len(names) > MAX_FILES:
        raise ValueError("initial source changes exceed bounds")
    # Renovate replacement files are tracked; untracked source is not an input.
    if run("git", "ls-files", "--others", "--exclude-standard"):
        raise ValueError("unexpected untracked source entries")
    with tempfile.TemporaryDirectory(prefix="dependency-update-private-") as directory:
        private = pathlib.Path(directory).resolve()
        work = private / "work"
        work.mkdir()
        subprocess.run(["git", "init", "--quiet", "--bare", str(private / "index")], check=True)
        old_env = os.environ.copy()
        try:
            for key in list(os.environ):
                if key.startswith("GIT_"):
                    del os.environ[key]
            os.environ.update(GIT_DIR=str(private / "index"), GIT_WORK_TREE=str(work),
                              GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
            os.chdir(work)
            subprocess.run(["git", "fetch", "--quiet", "--depth=1", str(source), base], check=True)
            subprocess.run(["git", "update-ref", "HEAD", base], check=True)
            subprocess.run(["git", "read-tree", "HEAD"], check=True)
            subprocess.run(["git", "checkout-index", "--all"], check=True)
            if patch:
                incoming = private / "initial.patch"
                incoming.write_bytes(patch)
                apply_patch(incoming, declarations=True)
            yield private
        finally:
            os.chdir(source)
            os.environ.clear()
            os.environ.update(old_env)


def generate_in_disposable(input_changed=False):
    # Nothing from this writable copy is imported unless every canonical writer succeeds.
    original = {name: pathlib.Path(name).read_bytes() for name in changed_paths()
                if not generated_path(name) and name != "flake.nix"}
    owner = pathlib.Path.cwd().stat()
    # Keep package builders unprivileged; root builds can leave Nix's purity HOME behind.
    command = [
        "docker", "run", "--rm", "--interactive", "--cap-drop=ALL",
        "--cap-add=DAC_OVERRIDE", "--cap-add=CHOWN", "--cap-add=FOWNER",
        "--cap-add=SETUID", "--cap-add=SETGID", "--cap-add=KILL", "--security-opt=no-new-privileges",
        "--memory=4g", "--cpus=2", "--pids-limit=256",
        "--mount", f"type=bind,source={pathlib.Path.cwd()},target=/work",
        "--tmpfs", "/work/.git", "--tmpfs", "/tmp:exec",
        "--env", f"OUTPUT_OWNER={owner.st_uid}:{owner.st_gid}", "--env", "NIX_REMOTE=local",
        "--env", "NIX_CONFIG=experimental-features = nix-command flakes\nmax-jobs = 1\ncores = 2\naccept-flake-config = false\nsandbox = false\nbuild-users-group = nixbld",
        "--workdir", "/work", NIX_IMAGE,
    ]
    setup = """set -euo pipefail
fix_ownership() {
  for output in flake.nix flake.lock docs generated/manifests; do
    if [ -e "$output" ] || [ -L "$output" ]; then chown -hR "$OUTPUT_OWNER" "$output"; fi
  done
}
trap fix_ownership EXIT
git init --quiet
git config --global --add safe.directory /work
git add --all
git add --force --all -- docs generated/manifests
"""
    if input_changed:
        setup += "nix run --no-write-lock-file path:.#write-flake\nnix flake lock path:.\n"
    setup += """nix run --no-write-lock-file path:.#write-files
git add --force --all -- docs generated/manifests
system=$(nix eval --impure --raw --expr builtins.currentSystem)
apps=$(nix eval --no-write-lock-file --raw "path:.#apps.$system" --apply 'apps: builtins.concatStringsSep "\\n" (builtins.filter (name: builtins.match "sync-.*-manifests" name != null) (builtins.attrNames apps))')
while IFS= read -r app; do
  if [ -n "$app" ]; then
    nix run --no-write-lock-file "path:.#$app"
    git add --force --all -- docs generated/manifests
  fi
done <<< "$apps"
"""
    subprocess.run(command, input=setup, text=True, check=True)
    for name in changed_paths():
        regular_path(name, missing=True)
        if not generated_path(name) and not (input_changed and name == "flake.nix"):
            if name not in original or pathlib.Path(name).read_bytes() != original[name]:
                raise ValueError(f"canonical writer modified source owner: {name!r}")


def regenerate_outputs():
    with disposable_source() as private:
        generate_in_disposable()
        patch = private / "generated.patch"
        write_patch(patch)
        contents = patch.read_bytes()
    with tempfile.TemporaryDirectory() as directory:
        patch = pathlib.Path(directory) / "generated.patch"
        patch.write_bytes(contents)
        # Includes the already-refreshed lock; restore that baseline before applying.
        subprocess.run(["git", "restore", "--source=HEAD", "--staged", "--worktree", "--", "flake.lock"], check=True)
        apply_patch(patch)


def repair_owners():
    changed = sorted(changed_paths())
    input_changed = False
    for filename in changed:
        if not filename.startswith("modules/") or not filename.endswith(".nix"):
            continue
        path = pathlib.Path(filename)
        regular_path(filename)
        text = path.read_text()
        before = run("git", "show", f"HEAD:{filename}")
        input_changed |= GITHUB.findall(text) != GITHUB.findall(before)
        if filename.endswith("/cert-manager.nix"):
            text = refresh_cert_images(text)
        previous = {(repo, chart): version for _, repo, chart, version in charts(before)}
        for match, repo, chart, version in charts(text):
            if previous.get((repo, chart)) == version:
                continue
            with tempfile.TemporaryDirectory(prefix="dependency-update-chart-") as directory:
                pull = ["helm", "pull"]
                pull += [f"{repo}/{chart}"] if repo.startswith("oci://") else [chart, "--repo", repo]
                subprocess.run(pull + ["--version", version, "--untar", "--destination", directory], check=True)
                new_hash = run("nix", "hash", "path", "--type", "sha256", "--sri", str(pathlib.Path(directory) / chart))
            old_hash = field(before, "chartHash") if "inherit chartHash;" in match.group(1) else field(match.group(1), "chartHash")
            text = replace_hash(text, old_hash, new_hash)
        path.write_text(text)
    if set(changed) & {"pkgs/by-name/jellyfin-provisioner-image/package.nix",
                       "modules/den/aspects/kubernetes/services/jellyfin.nix"}:
        raise ValueError("Jellyfin requires a reviewed coupled helper release; no incomplete candidate is exported")
    return input_changed


def validate_metadata(metadata):
    if set(metadata) != {"branch", "base", "revision"} or metadata["base"] != "main":
        raise ValueError("unexpected candidate metadata/base")
    branch = metadata["branch"]
    if not isinstance(branch, str) or not re.fullmatch(r"dependency-update/renovate/[a-zA-Z0-9][a-zA-Z0-9._/-]{0,180}", branch):
        raise ValueError("candidate branch is outside the owned namespace")
    subprocess.run(["git", "check-ref-format", "refs/heads/" + branch], check=True)
    if not re.fullmatch(r"[a-f0-9]{40}", metadata["revision"]):
        raise ValueError("invalid candidate revision")
    return hashlib.sha256(branch.encode()).hexdigest()


def prepare_declaration():
    CANDIDATES.mkdir(exist_ok=True)
    try:
        data = pathlib.Path(os.environ["RENOVATE_POST_UPGRADE_COMMAND_DATA_FILE"])
        if data.stat().st_size > 4096:
            raise ValueError("oversized Renovate metadata")
        metadata = json.loads(data.read_text())
        metadata["revision"] = run("git", "rev-parse", "HEAD")
        key = validate_metadata(metadata)
        # PR/full dry-runs may use a newer/different main than the workflow ref.
        # Only the publisher requires an exact match to its trusted checkout.
        with disposable_source() as private:
            input_changed = repair_owners()
            generate_in_disposable(input_changed)
            patch = private / "candidate.patch"
            write_patch(patch, declarations=True)
            contents = patch.read_bytes()
        # Only host-created bytes survive. The live Renovate worktree was never mounted.
        (CANDIDATES / (key + ".patch")).write_bytes(contents)
        (CANDIDATES / (key + ".json")).write_text(json.dumps(metadata) + "\n")
    except BaseException:
        (CANDIDATES / "failed").write_text("A preparation hook failed; no candidates may be published.\n")
        raise


def candidate_files(directory):
    regular_path(str(directory / "manifest.json"))
    manifest = json.loads((directory / "manifest.json").read_text())
    if not isinstance(manifest, list) or len(manifest) > 64 or len(set(manifest)) != len(manifest):
        raise ValueError("invalid candidate manifest")
    if set(p.name for p in directory.iterdir()) != {"manifest.json", *(key + ext for key in manifest for ext in (".json", ".patch"))}:
        raise ValueError("unexpected candidate artifact entries")
    total = 0
    for key in manifest:
        if not isinstance(key, str) or not re.fullmatch(r"[a-f0-9]{64}", key):
            raise ValueError("invalid candidate artifact identity")
        meta, patch = directory / (key + ".json"), directory / (key + ".patch")
        regular_path(str(meta))
        regular_path(str(patch))
        total += meta.stat().st_size + patch.stat().st_size
        if meta.stat().st_size > 4096 or total > MAX_BYTES:
            raise ValueError("candidate artifact exceeds byte bounds")
        metadata = json.loads(meta.read_text())
        if validate_metadata(metadata) != key:
            raise ValueError("candidate identity mismatch")
        patch_paths(patch, declarations=True)
        yield metadata, patch


def seal_candidates():
    CANDIDATES.mkdir(exist_ok=True)
    if (CANDIDATES / "failed").exists():
        raise ValueError("Renovate caught a preparation failure; refusing all artifact export")
    keys = sorted(path.stem for path in CANDIDATES.glob("*.json"))
    (CANDIDATES / "manifest.json").write_text(json.dumps(keys) + "\n")
    list(candidate_files(CANDIDATES))


def publish_candidates(directory):
    # No Renovate/Nix/Helm or candidate programs in this write-token job.
    base = run("git", "rev-parse", "HEAD")
    candidates = list(candidate_files(pathlib.Path(directory).resolve()))
    if any(metadata["revision"] != base for metadata, _ in candidates):
        raise ValueError("candidate base is not this trusted checkout")
    body = ("Source-owner update with successful isolated canonical regeneration.\n\n"
            "Before merging, approve pending workflow runs or dispatch Nix CI on this branch and review the results. "
            "The updater does not merge or activate hosts. "
            "Merging generated manifests to main can roll out services through Argo.")
    auth = subprocess.check_output(["git", "config", "--get", "remote.origin.url"], text=True).strip()
    if auth != "https://github.com/" + os.environ["GH_REPO"] and auth != "https://github.com/" + os.environ["GH_REPO"] + ".git":
        raise ValueError("unexpected publication remote")
    import base64
    header = base64.b64encode(("x-access-token:" + os.environ["GH_TOKEN"]).encode()).decode()
    print("::add-mask::" + header, flush=True)
    subprocess.run(["git", "config", "user.name", "github-actions[bot]"], check=True)
    subprocess.run(["git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], check=True)
    for metadata, patch in candidates:
        subprocess.run(["git", "reset", "--hard", base], check=True)
        apply_patch(patch, declarations=True)
        if not run("git", "diff", "--cached", "--name-only"):
            continue
        branch = metadata["branch"]
        remote = run("git", "ls-remote", "origin", "refs/heads/" + branch)
        lease = remote.split("\t")[0] if remote else ""
        subprocess.run(["git", "commit", "-m", "chore(deps): refresh source declarations"], check=True)
        subprocess.run(["git", "-c", "http.https://github.com/.extraheader=AUTHORIZATION: basic " + header,
                        "push", f"--force-with-lease=refs/heads/{branch}:{lease}", "origin", "HEAD:refs/heads/" + branch], check=True)
        number = run("gh", "pr", "list", "--head", branch, "--base", "main", "--state", "open", "--json", "number", "--jq", ".[0].number // empty")
        args = ["gh", "pr", "edit", number] if number else ["gh", "pr", "create", "--head", branch, "--base", "main"]
        subprocess.run(args + ["--title", "chore(deps): refresh source declarations", "--body", body], check=True)


def self_test():
    text = '''chartVersion = "1.2.3";
chartHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
chart = lib.helm.downloadHelmChart {
  repo = "oci://example.test/charts"; chart = "example";
  version = chartVersion; inherit chartHash;
};'''
    assert [(repo, chart, version) for _, repo, chart, version in charts(text)] == [("oci://example.test/charts", "example", "1.2.3")]
    inherited = '''version = "v1.21.3";
chart = lib.helm.downloadHelmChart {
  repo = "oci://quay.io/jetstack/charts"; chart = "cert-manager";
  inherit version; chartHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
};'''
    assert [(repo, chart, version) for _, repo, chart, version in charts(inherited)] == [
        ("oci://quay.io/jetstack/charts", "cert-manager", "v1.21.3")]
    try:
        list(charts('version = "other";\n' + inherited))
    except ValueError:
        pass
    else:
        raise AssertionError("ambiguous inherited chart owner accepted")
    new = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
    assert field(replace_hash(text, field(text, "chartHash"), new), "chartHash") == new
    for name in [".github/workflows/evil.yml", "../flake.lock", "docs/../evil.md", "docs/.git/config.md", "README.md", "docs/README.md"]:
        assert not declaration_path(name), name
    assert declaration_path("modules/meta/inputs.nix") and generated_path("docs/operations/example.md")
    original = pathlib.Path.cwd()
    with tempfile.TemporaryDirectory() as directory:
        os.chdir(directory)
        try:
            subprocess.run(["git", "init", "--quiet"], check=True)
            subprocess.run(["git", "-c", "user.name=test", "-c", "user.email=test@example.test", "commit", "--quiet", "--allow-empty", "-m", "base"], check=True)
            pathlib.Path("docs").mkdir()
            pathlib.Path("docs/example.md").write_text("safe\n")
            write_patch("safe.patch")
            subprocess.run(["git", "reset", "--hard", "HEAD"], check=True, stdout=subprocess.DEVNULL)
            apply_patch("safe.patch")
            assert pathlib.Path("docs/example.md").read_text() == "safe\n"
            subprocess.run(["git", "reset", "--hard", "HEAD"], check=True, stdout=subprocess.DEVNULL)
            pathlib.Path("docs").mkdir(exist_ok=True)
            # Text numstat is not evidence of regular-file mode: reject gitlinks first.
            base = run("git", "rev-parse", "HEAD")
            subprocess.run(["git", "update-index", "--add", "--cacheinfo", f"160000,{base},docs/example.md"], check=True)
            pathlib.Path("gitlink.patch").write_bytes(subprocess.check_output(["git", "diff", "--cached", "HEAD"]))
            subprocess.run(["git", "reset", "--hard", "HEAD"], check=True, stdout=subprocess.DEVNULL)
            try:
                apply_patch("gitlink.patch")
            except ValueError:
                pass
            else:
                raise AssertionError("gitlink accepted")
            subprocess.run(["git", "reset", "--hard", "HEAD"], check=True, stdout=subprocess.DEVNULL)
            for mode, content in [("120000", "ordinary-target"), ("100755", "executable text\n")]:
                blob = subprocess.check_output(["git", "hash-object", "-w", "--stdin"], input=content.encode()).decode().strip()
                subprocess.run(["git", "update-index", "--add", "--cacheinfo", f"{mode},{blob},docs/example.md"], check=True)
                pathlib.Path("mode.patch").write_bytes(subprocess.check_output(["git", "diff", "--cached", "HEAD"]))
                subprocess.run(["git", "reset", "--hard", "HEAD"], check=True, stdout=subprocess.DEVNULL)
                try:
                    apply_patch("mode.patch")
                except ValueError:
                    pass
                else:
                    raise AssertionError(f"forbidden {mode} accepted")
                subprocess.run(["git", "reset", "--hard", "HEAD"], check=True, stdout=subprocess.DEVNULL)
            pathlib.Path("docs").mkdir(exist_ok=True)
            pathlib.Path("docs/example.md").symlink_to("safe.patch")
            try:
                regular_path("docs/example.md")
            except ValueError:
                pass
            else:
                raise AssertionError("symlink accepted")
            pathlib.Path("docs/ancestor").symlink_to("elsewhere", target_is_directory=True)
            try:
                regular_path("docs/ancestor/example.md", missing=True)
            except ValueError:
                pass
            else:
                raise AssertionError("symlink ancestor accepted")
            pathlib.Path("docs/embedded/.git").mkdir(parents=True)
            pathlib.Path("docs/embedded/example.md").write_text("ordinary")
            try:
                regular_path("docs/embedded/example.md")
            except ValueError:
                pass
            else:
                raise AssertionError("embedded repository accepted")
            for branch in ["renovate/outside", "dependency-update/renovate/../outside", "dependency-update/renovate/bad.lock"]:
                try:
                    validate_metadata({"branch": branch, "base": "main", "revision": base})
                except (ValueError, subprocess.CalledProcessError):
                    pass
                else:
                    raise AssertionError("unowned/invalid branch accepted")
        finally:
            os.chdir(original)
    with tempfile.TemporaryDirectory() as directory:
        os.chdir(directory)
        try:
            subprocess.run(["git", "init", "--quiet"], check=True)
            pathlib.Path("flake.lock").write_text("before\n")
            subprocess.run(["git", "add", "flake.lock"], check=True)
            subprocess.run(["git", "-c", "user.name=test", "-c", "user.email=test@example.test", "commit", "--quiet", "-m", "base"], check=True)
            pathlib.Path("flake.lock").write_text("candidate\n")
            live = pathlib.Path.cwd()
            try:
                with disposable_source():
                    assert pathlib.Path("flake.lock").read_text() == "candidate\n"
                    pathlib.Path("flake.lock").write_text("failed generation\n")
                    raise RuntimeError("generation failed")
            except RuntimeError:
                pass
            assert pathlib.Path("flake.lock").read_text() == "candidate\n"
            from unittest.mock import patch
            with patch(__name__ + ".CANDIDATES", live / "exports"), patch.dict(os.environ):
                os.environ.pop("RENOVATE_POST_UPGRADE_COMMAND_DATA_FILE", None)
                try:
                    prepare_declaration()
                except KeyError:
                    pass
                else:
                    raise AssertionError("missing preparation metadata accepted")
                try:
                    seal_candidates()
                except ValueError:
                    pass
                else:
                    raise AssertionError("failed preparation allowed artifact export")
                assert not list((live / "exports").glob("*.patch"))
        finally:
            os.chdir(original)
    print("dependency-update isolation self-check passed")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == ["--self-test"]:
        self_test()
    elif args == ["--refresh-generated"]:
        regenerate_outputs()
    elif len(args) == 2 and args[0] == "--write-patch":
        write_patch(args[1])
    elif len(args) == 2 and args[0] == "--apply-patch":
        apply_patch(args[1])
    elif args == ["--prepare-declaration"]:
        prepare_declaration()
    elif args == ["--seal-candidates"]:
        seal_candidates()
    elif len(args) == 2 and args[0] == "--publish-candidates":
        publish_candidates(args[1])
    else:
        raise SystemExit("usage: dependency-update.py --self-test|--refresh-generated|--write-patch PATH|--apply-patch PATH|--prepare-declaration|--seal-candidates|--publish-candidates DIR")
