# homelab

## CI

`.github/workflows/ci.yml` runs for pushes to `main`, pull requests, and
manual dispatches from any ref. Pushes to other branches alone do not start
Nix CI.

`modules/flake/ci.nix` automatically projects packages, checks, development
shells, formatters, NixOS and Darwin systems, and Home Manager activation
packages for x86-64 Linux, ARM64 Linux, and ARM64 Darwin. Each runner evaluates
its own system's projection: nixidy chart evaluation can require native builds.
Every CI group is a directly buildable Nix derivation. `ciBundles.<system>`
builds the complete projection; neither target requires GitHub Actions.

On a builder for the selected system:

```sh
nix build .#ciBundles.aarch64-darwin
nix build .#ciJobs.x86_64-linux.nixosConfigurations
nix build .#checks.aarch64-linux.den-semantics
```

Linux VM checks remain directly buildable for x86-64 and ARM64. Hosted ARM
jobs omit checks whose Hestia group ends in `-runtime`, because GitHub's ARM
runners do not expose KVM. A KVM-capable ARM builder can build any omitted
check directly. Check jobs use `--max-jobs 1` so VM tests do not compete with
other builds on the same runner; other CI groups retain Nix's normal
parallelism. Check jobs also evaluate their projection in a separate
`nix eval` process and then build the resulting derivation. Evaluating every
check takes about 10 GiB, and a `nix build` process that evaluated them keeps
that memory until its last build ends.

A hosted x86-64 runner has 4 vCPUs and 16 GiB of memory. A VM check must fit
there: request at most 4 cores, and leave the runner several GiB beyond the
guest's memory. A VM that oversubscribes the runner does not fail cleanly;
GitHub loses the runner and the job ends without the test's result.

Hosted CI builds the full ARM64 Darwin configuration. An ARM64 Linux job first
builds the Linux system closure used by its `nix.linux-builder` VM and passes
that closure to the macOS job through a one-day workflow artifact. This breaks
the first-build cycle without weakening the production configuration. The
workstation builds the same configuration as its activation gate.

Manual dispatch builds the full projection by default. Set `system` to build
only that platform, or set `check` to run one check (defaulting to x86-64 when
no specific platform is selected):

```sh
gh workflow run ci.yml --ref "$REF" -f check=den-semantics
gh workflow run ci.yml --ref "$REF" -f system=aarch64-linux
```

`check=household-sign-in-runtime` selects the read-only native x86 Docker
lane rather than a cached Nix check derivation. The entire materialized
household suite runs on every full CI invocation, even when its pinned app
dependencies are cached. It uses the canonical production manifests and
three helper archives; directory NetworkPolicy remains a separate real
K3s/kernel VM gate.

The same app is available as `nix run .#household-sign-in-runtime`. Run it
only as root inside an exclusive disposable native x86 Linux Docker fixture,
with `idm.plus2.danielvicory.dev` resolving to `127.0.0.1`. The existing
`TMPDIR` parent (default `/root`) is canonicalized; its `household` child must
not exist, including a dangling symlink. The app refuses existing fixture
resources before loading images, never edits host resolution, and cleans only
owned containers, network and synthetic credentials on exit. The hosted disposable runner
adds one explicit canonical-domain loopback entry. No production account,
credential or Seerr publication is part of this acceptance.

The hosted household lane places `/nix`, Docker and containerd data on its
owned Btrfs image. Setup refuses existing mounts; cleanup checks the filesystem
UUID and expected bind-mount roots before unmounting them or deleting the image.

Check names and implementations belong in Nix, not workflow branches. Successful
check jobs upload nonempty outputs as `check-output-<system>-<run-id>` artifacts;
Linux runners enable available KVM acceleration and publish nonempty outputs to
the public `dvicory-homelab` Cachix cache. System builds and checks can reuse
narinfo and objects uploaded by other jobs.
All jobs read the public `dvicory-homelab` Cachix cache. Successful `main` push
jobs publish their existing outputs and runtime closures directly from the build
runner; another job's failure does not prevent those uploads. There is no second
build on a separate publication runner. The `cachix-publish` environment remains
restricted to `main`, and only the publication step receives its per-cache write
token. Pull requests and manual dispatches remain read-only.

Nix store contents published by CI are public, so CI outputs must never contain
decrypted secrets.

GitHub enforces full-SHA action pins and the repository action allowlist.
Dependabot groups action updates into a weekly pull request after a seven-day
cooldown. `.github/workflows/security.yml` runs zizmor when GitHub automation
changes and rejects medium-or-higher findings.