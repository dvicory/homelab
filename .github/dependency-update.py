#!/usr/bin/env python3
"""Repair generated flake and Helm hashes after upstream Renovate changes source owners."""
import pathlib
import re
import subprocess
import sys
import tempfile


CHART = re.compile(r'lib\.helm\.downloadHelmChart\s*\{([^{}]*)\}', re.S)
GITHUB = re.compile(r'"github:[^"\s]+"')
CERT_IMAGE = re.compile(r'image "(quay\.io/jetstack/cert-manager-[a-z]+)" "(sha256:[a-f0-9]{64})"')
# Official nixos/nix 2.35.4 multi-platform index, resolved read-only on 2026-11-06.
NIX_IMAGE = "docker.io/nixos/nix@sha256:f159a58f390677f41e8e900a74b6e2f9c7f27b364122ae6acf7a652ce6c551c0"


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def changed_paths():
    return set(run("git", "diff", "--name-only", "HEAD").splitlines()) | set(
        run("git", "ls-files", "--others", "--exclude-standard").splitlines()
    )


def field(text, name):
    match = re.search(r'\b' + re.escape(name) + r'\s*=\s*"([^"\n]+)";', text)
    if not match:
        raise ValueError(f"missing literal {name}")
    return match.group(1)


def charts(text):
    for match in CHART.finditer(text):
        block = match.group(1)
        version = field(text, "chartVersion") if "version = chartVersion;" in block else field(block, "version")
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
            continue  # Renovate already updated the controller digest and shared version.
        digest = run("skopeo", "inspect", "--format", "{{.Digest}}", f"docker://{repository}:{version}")
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            raise ValueError(f"invalid registry digest for {repository}")
        text = text.replace(match.group(0), f'image "{repository}" "{digest}"')
    return text


def regenerate_outputs(input_changed=False):
    # Updated input code is executable: never share the host store or daemon.
    original_changes = changed_paths()
    owner = pathlib.Path.cwd().stat()
    command = [
        "docker", "run", "--rm", "--interactive", "--cap-drop=ALL",
        # Rewrite runner-owned source and return new generated files to that owner.
        "--cap-add=DAC_OVERRIDE", "--cap-add=CHOWN",
        "--security-opt=no-new-privileges", "--memory=4g", "--cpus=2", "--pids-limit=256",
        "--mount", f"type=bind,source={pathlib.Path.cwd()},target=/work",
        "--tmpfs", "/work/.git", "--tmpfs", "/tmp:exec",
        "--env", f"OUTPUT_OWNER={owner.st_uid}:{owner.st_gid}",
        "--env", "NIX_REMOTE=local",
        "--env", "NIX_CONFIG=experimental-features = nix-command flakes\nmax-jobs = 1\ncores = 2\naccept-flake-config = false\nsandbox = false\nbuild-users-group =",
        "--workdir", "/work", NIX_IMAGE,
    ]
    setup = """set -euo pipefail
fix_ownership() {
  for output in flake.nix flake.lock docs generated/manifests; do
    if [ -e "$output" ] || [ -L "$output" ]; then chown -hR "$OUTPUT_OWNER" "$output"; fi
  done
}
trap fix_ownership EXIT
# Canonical writers find the Git root. This index is private, not host credentials.
git init --quiet
git config --global --add safe.directory /work
git add --all
git add --force --all -- docs generated/manifests
"""
    if input_changed:
        setup += "nix run --no-write-lock-file path:.#write-flake\nnix flake lock path:.\n"
    # Keep write-files and every declared sync-*-manifests app as their existing
    # owners. Track new output before the next evaluation, including new resources.
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
    for filename in changed_paths():
        if pathlib.Path(filename).is_symlink():
            raise ValueError("generated update must not introduce symlink outputs")
        if filename not in original_changes and not generated_path(filename) and not (input_changed and filename == "flake.nix"):
            raise ValueError(f"canonical writer changed a non-generated path: {filename!r}")


def generated_path(name):
    path = pathlib.PurePosixPath(name)
    if str(path) != name or any(part.startswith(".") for part in path.parts):
        return False
    if any(ord(character) < 32 for character in name) or path.name.lower() == "readme.md":
        return False
    return name == "flake.lock" or (
        name.startswith("docs/") and path.suffix == ".md"
    ) or (name.startswith("generated/manifests/") and path.suffix in {".yaml", ".yml"})


def patch_paths(path):
    if pathlib.Path(path).stat().st_size > 32 * 1024 * 1024:
        raise ValueError("generated candidate patch exceeds 32 MiB")
    stats = subprocess.check_output(["git", "apply", "--numstat", "-z", "--", path])
    records = stats.split(b"\0")[:-1] if stats else []
    if len(records) > 4096:
        raise ValueError("generated candidate exceeds 4096 changed files")
    names = []
    for record in records:
        parts = record.split(b"\t", 2)
        if len(parts) != 3 or not parts[0].isdigit() or not parts[1].isdigit():
            raise ValueError("generated patch must contain plain text files, not renames or binary data")
        name = parts[2].decode("utf-8")
        if not generated_path(name):
            raise ValueError(f"generated patch path is not allowed: {name!r}")
        names.append(name)
    return names


def write_patch(path):
    subprocess.run(["git", "add", "--force", "--all", "--", "docs", "generated/manifests"], check=True)
    names = changed_paths()
    if not all(generated_path(name) for name in names):
        raise ValueError("canonical writers changed files outside the generated-output allowlist")
    patch = subprocess.check_output(["git", "diff", "--no-renames", "HEAD", "--", "flake.lock", "docs", "generated/manifests"])
    pathlib.Path(path).write_bytes(patch)
    if patch:
        patch_paths(path)


def apply_patch(path):
    if not pathlib.Path(path).stat().st_size:
        return
    names = patch_paths(path)
    # Git applies data only. The write-token publisher never evaluates candidate Nix.
    subprocess.run(["git", "apply", "--index", "--", path], check=True)
    if any(pathlib.Path(name).is_symlink() for name in names):
        raise ValueError("generated candidate must not create symlink outputs")


def main():
    changed = run("git", "diff", "--name-only", "HEAD", "--", "modules").splitlines()
    input_changed = False
    for filename in changed:
        if not filename.endswith(".nix"):
            continue
        path = pathlib.Path(filename)
        text = path.read_text()
        before = run("git", "show", f"HEAD:{filename}")
        input_changed |= GITHUB.findall(text) != GITHUB.findall(before)
        if filename.endswith("/cert-manager.nix"):
            text = refresh_cert_images(text)
        previous = {(repo, chart): version for _, repo, chart, version in charts(before)}
        for match, repo, chart, version in charts(text):
            if previous.get((repo, chart)) == version:
                continue
            # Same recursive unpacked hash recipe as nixidy's upstream update-chart.sh.
            with tempfile.TemporaryDirectory(prefix="dependency-update-chart-") as directory:
                pull = ["helm", "pull"]
                pull += [f"{repo}/{chart}"] if repo.startswith("oci://") else [chart, "--repo", repo]
                subprocess.run(pull + ["--version", version, "--untar", "--destination", directory], check=True)
                new_hash = run("nix", "hash", "path", "--type", "sha256", "--sri", str(pathlib.Path(directory) / chart))
            old_hash = field(before, "chartHash") if "inherit chartHash;" in match.group(1) else field(match.group(1), "chartHash")
            text = replace_hash(text, old_hash, new_hash)
        if text != path.read_text():
            path.write_text(text)
    jellyfin = {
        "pkgs/by-name/jellyfin-provisioner-image/package.nix",
        "modules/den/aspects/kubernetes/services/jellyfin.nix",
    }
    package_changes = run("git", "diff", "--name-only", "HEAD", "--", "pkgs/by-name").splitlines()
    if set(changed + package_changes) & jellyfin:
        print("Draft-only Jellyfin candidate: canonical rendering requires a reviewed coupled helper release; generated output is intentionally not claimed ready.", file=sys.stderr)
    else:
        regenerate_outputs(input_changed)


def self_test():
    text = '''chartVersion = "1.2.3";
chartHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
chart = lib.helm.downloadHelmChart {
  repo = "oci://example.test/charts"; chart = "example";
  version = chartVersion; inherit chartHash;
};'''
    assert [(repo, chart, version) for _, repo, chart, version in charts(text)] == [("oci://example.test/charts", "example", "1.2.3")]
    old = field(text, "chartHash")
    new = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
    assert field(replace_hash(text, old, new), "chartHash") == new
    assert GITHUB.findall('url = "github:owner/repo/abc";') == ['"github:owner/repo/abc"']
    certs = '\n'.join(f'image "quay.io/jetstack/cert-manager-{name}" "sha256:{"a" * 64}"'
                      for name in ["controller", "webhook", "cainjector", "acmesolver", "startupapicheck"])
    assert len(CERT_IMAGE.findall(certs)) == 5
    try:
        replace_hash(text, old, "not-a-hash")
    except ValueError:
        pass
    else:
        raise AssertionError("invalid hash accepted")
    assert generated_path("flake.lock") and generated_path("docs/operations/example.md")
    assert generated_path("generated/manifests/example/Deployment-example.yaml")
    for name in [".github/workflows/evil.yml", "../flake.lock", "docs/../evil.md", "docs/.git/config.md", "README.md", "docs/README.md"]:
        assert not generated_path(name), name
    print("dependency-update hook self-check passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif sys.argv[1:] == ["--refresh-generated"]:
        regenerate_outputs()
    elif len(sys.argv) == 3 and sys.argv[1] == "--write-patch":
        write_patch(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "--apply-patch":
        apply_patch(sys.argv[2])
    elif sys.argv[1:]:
        raise SystemExit("usage: dependency-update.py [--self-test|--refresh-generated|--write-patch PATH|--apply-patch PATH]")
    else:
        main()
