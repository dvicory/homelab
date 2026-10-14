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

### Required-green main Nix helper candidates

`helper-release.yml` is reusable only: **Nix CI** calls it automatically for a
same-repository `push` to `main`, after **Required CI** succeeds. That gate joins
every required CI dependency, including all build matrix legs, the Darwin
builder bootstrap and the Actions security audit. Every dependency must succeed;
failed, cancelled or skipped dependencies refuse publication. PRs and manual or
selected CI runs never publish. There is no early PR admission, `workflow_run`
trigger, manual publisher dispatch or per-release approval click.

Both caller and callee check the trusted repository, main push event, CI workflow
path and immutable source/tooling SHA. The callee also checks GitHub's actual
workflow ID, run ID, attempt, repository and main head facts, and the completed,
successful **Required CI** job for that exact SHA/attempt. It repeats that check
before publication. The parent run is still executing the publisher, so its
overall conclusion is deliberately not the gate. The exact merged-main push SHA
is retained even if a newer main push arrives; consumers never follow a branch
or mutable image tag.

The producer builds and audits four native x86-64 helpers in a read-only,
sandboxed job. Only the caller's narrowly scoped reusable-workflow call grants
`packages: write`; the callee reduces permissions for authorization, build and
verification, leaving that authority only in its publisher job. No repository
write permission, inherited repository secrets or approval environment is used.
GitHub's token is repository-associated package authority, **not four
package-scoped credentials**. Fixed destinations remain enforced by publisher
code; artifact data cannot choose them.

The publisher downloads an immutable artifact ID from its own read-only build
and checks the independently recorded metadata fingerprint, every archive's
actual checksum, config/rootfs and native platform. It checks out
`github.workflow_sha`, which must equal the exact main producer SHA, and runs
only that main-owned publisher tooling. It never executes transferred scripts
or image entrypoints. Publication credentials live in an ephemeral
authentication file removed on exit.

Data separation does not make archives safe. The credentialed job still trusts
its parsers, pinned Actions and tools. Hashes bind transferred bytes, and
credential scanning detects recognizable material; neither proves those bytes
harmless or free of every possible secret. No audit finding is suppressed.
Publication keeps Docker schema 2 config bytes, which GHCR and K3s support.
Converting them to OCI rewrites creation/history timestamps and is refused by
the exact producer-config identity check.

The fixed destinations are
`ghcr.io/dvicory/homelab/{retained-directories,kanidm-provision,jellyfin-provisioner,jellarr}`.
Automation requires a separately approved merge of this workflow and repository
Actions package-write access to those destinations. This configuration does not
authorize an unreviewed branch-owned publisher, personal token substitution or
package visibility changes.

New GHCR packages default private. Public visibility and repository Actions
access are external package-settings prerequisites, not mutations this workflow
performs. If visibility prevents verification, resolve it only with separate
owner authorization, then rerun the failed **verify** job, not the successful
publisher. The verification job has no package-write permission and
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
`checks.<system>.helper-source` exercises exact main-caller and completed
required-job receipt authorization, including refusal of PR/manual/fork sources.
`checks.<system>.helper-release` runs the registered archive/admission audit,
including referenced extensionless layers, linked transfer files, metadata
credentials and public-certificate controls.

GitHub enforces full-SHA action pins and the repository action allowlist.
Dependabot groups action updates into a weekly pull request after a seven-day
cooldown. `.github/workflows/security.yml` runs zizmor when GitHub automation
changes and is also called by every Nix CI run, rejecting medium-or-higher
findings before helper publication.

The reusable call uses GitHub's documented [same-commit local workflow
reference](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#calling-a-reusable-workflow).
The [caller context and permission
rules](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
mean the callee sees the caller's `github` facts and can only reduce the caller's
token permissions, not elevate them. No environment secret or approval
configuration is required for automatic helper promotion.