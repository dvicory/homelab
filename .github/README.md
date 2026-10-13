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

### Early Nix helper candidates

`helper-release.yml` is a separate main-owned lane. A requested **Nix CI**
run starts authorization and read-only native x86-64 helper builds alongside
the rest of CI, not after its runtime tests. GitHub's actual CI workflow ID
and path, repository, event, current source SHA, PR head and maintain/admin
permission facts authorize a source. Forks, stale heads and write-only
contributors are refused; `author_association` is not an authorization rule.

Only the protected `helper-release` publisher job has `packages: write`.
It downloads an immutable artifact ID from its own read-only build and checks
the independently recorded metadata fingerprint, each archive's actual
checksum, config/rootfs and native platform. It runs only main-owned tooling;
it never checks out PR code or takes a package destination from artifact data.
Publication credentials live in an ephemeral authentication file removed on
exit. There is no repository write permission or automatic selection commit.
Publication keeps Docker schema 2 config bytes, which GHCR and K3s support.
Converting them to OCI rewrites creation/history timestamps and is refused
by the exact producer-config identity check.

The fixed destinations are public
`ghcr.io/dvicory/homelab/{retained-directories,kanidm-provision,jellyfin-provisioner,jellarr}`.
The owner approved early same-repository maintainer candidate publication and
these irreversible public namespaces, but the publisher PR still needs a
separately approved merge before this workflow can be used. Do not dispatch an
unreviewed branch-owned publisher or substitute a personal token.

After that merge, an owner may explicitly request the lane for a current
permitted Nix CI source run:

```sh
gh workflow run helper-release.yml --ref main -f source_run="$SOURCE_RUN"
```

New GHCR packages default private. Configure only the four approved packages
as public through GitHub's supported package-settings interface; the workflow
does not change visibility. Then rerun the failed **verify** job, not the
successful publisher. The verification job has no package-write permission and
uses `--no-creds`, verified TLS and full digest retrieval to compare the remote
config/rootfs with the original Nix output. A private or mismatched candidate
remains ineligible even if authenticated publication succeeded.

`helper-verified-<sha>` records candidates for a separately tested/reviewed
consumer PR; it does not deploy them. Seven-day Actions artifacts only transfer
builds and evidence. Retain selected and supported rollback manifests/layers in
GHCR without automatic pruning, plus their committed source/digest mappings.
No GitHub Release archive or independent offline/exact-byte recovery guarantee
is added. A lost registry version must be rebuilt from still-available locked
inputs and may have a different digest; a GitHub-wide outage remains an
availability limit, never permission to use a mutable fallback.

The native disposable check is
`checks.x86_64-linux.helper-release-runtime`; it builds the existing retained
helper and a genuinely recompiled version, runs their Kubernetes Jobs through
a real TLS registry without helper preloads/imports, and checks anonymous
access, refusal, explicit old-digest rollback and retained-state identity.
`checks.<system>.helper-source` exercises the actual authorization decisions.

GitHub enforces full-SHA action pins and the repository action allowlist.
Dependabot groups action updates into a weekly pull request after a seven-day
cooldown. `.github/workflows/security.yml` runs zizmor when GitHub automation
changes and rejects medium-or-higher findings.