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

Linux VM checks remain directly buildable for x86-64 and ARM64. Hosted CI
partitions the actual check derivations using NixOS test drivers and
`requiredSystemFeatures`, never Hestia group names. Each x86-64 VM/KVM check
runs on its own native Ubuntu 24.04 runner with `--max-jobs 1`; the fast check
aggregate contains no runtime checks. All platforms retain their full fast
semantic/schema/freshness inventory and package/configuration/development groups.
Hosted ARM runtime checks are recorded as unsupported because its runners do
not expose KVM; a KVM-capable ARM builder can still build those checks directly.
Every registered check must be a derivation and belongs to exactly one of the
fast, hosted runtime, or explicitly unsupported partitions. Future checks join
automatically. Planning projects this inventory without forcing `drvPath`, so
runtime lanes can start without evaluating every check's complete build graph.
Native check jobs still upload the full evaluated platform inventory with exact
derivation identities; runtime build receipts retain their exact derivations.

Build jobs release their separate `nix eval` heap before building the exact
derivation, preserving memory for the VM. No runner executes competing VM suites.

A hosted x86-64 runner has 4 vCPUs and 16 GiB of memory. A VM check must fit
there: request at most 4 cores, and leave the runner several GiB beyond the
guest's memory. A VM that oversubscribes the runner does not fail cleanly;
GitHub loses the runner and the job ends without the test's result.

Hosted CI builds the full ARM64 Darwin configuration. An ARM64 Linux job first
builds the Linux system closure used by its `nix.linux-builder` VM and passes
that closure to the macOS job through a one-day workflow artifact. Only the
Darwin configuration job waits for this bootstrap; Linux and other Darwin
groups do not. This breaks the first-build cycle without weakening the
production configuration. The workstation builds the same configuration as
its activation gate.

Manual dispatch builds the full projection by default. Set `system` to build
only that platform, or set `check` to run one check (defaulting to x86-64 when
no specific platform is selected):

```sh
gh workflow run ci.yml --ref "$REF" -f check=den-semantics
gh workflow run ci.yml --ref "$REF" -f system=aarch64-linux
```

Check names and implementations belong in Nix, not workflow branches. Single
check dispatch validates its registration and hosted platform support; selecting
an unsupported runtime platform fails explicitly rather than silently skipping.
`media-runtime` dispatch still runs the unchanged native x86-64 Docker suite.
Successful check jobs upload nonempty outputs as
`check-output-<system>-<check-or-group>-<run-id>` artifacts; empty outputs retain
their evidence in the job log. Linux runners enable available KVM acceleration.
System builds and checks can reuse narinfo and objects uploaded by other jobs.
Hestia's binary version is pinned alongside its action. Use core v3.1.0 or
newer: it rejects cached narinfos whose backing packs are unavailable, rather
than repeatedly advertising objects that fail during download. The manifest
and backing packs are separate GitHub cache entries; a manifest hit alone
does not prove that its objects remain available.

All jobs read the public `dvicory-homelab` Cachix cache and the signed upstream
`https://cache.numtide.com` cache documented by the pinned `llm-agents` input.
CI and shared Nix settings append its fixed public key
`niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=`.
CI appends the upstream cache and key to the user configuration after Cachix:
Cachix's base settings override installer-level `extra-*` values. The later
Hestia configuration preserves this user configuration. Existing substituters
and keys remain configured. This permits exact upstream package substitution
without changing package sources or versions. Signature verification remains
required; CI does not automatically accept PR-provided flake configuration or
grant upstream cache-write access. Successful `main` push
jobs publish their existing outputs, runtime closures, and realized build
dependencies directly from the build runner; another job's failure does not
prevent those uploads. Publication uses the derivation roots recorded by the
successful build, including dependencies embedded in compressed images that
have no runtime store references. It excludes the source/derivation-only
closure and never builds missing outputs for publication. There is no second
build on a separate publication runner. The `cachix-publish` environment remains
restricted to `main`, and only the publication step receives its per-cache write
token. Pull requests and manual dispatches remain read-only.

A successful warm `main` job does not prove that a cold PR runner can substitute
its dependencies. For a repeated compiled dependency, compare the exact
derivation and every required output with the `main` log, then query each output
using `nix path-info --store https://dvicory-homelab.cachix.org "$output"`.
A 404 means the output is unavailable, not that its derivation changed; Cachix
also hides paths whose closure is incomplete. The publisher's realized-only
selection includes the patched Incus server, documentation, agent loader and
client even when a VM image hides them from its runtime references.

Restore unavailable dependencies only through owner-approved protected-main
publication of the exact successful outputs and their closures. Never use PR
credentials or accept unsigned NARs to make a cold-cache proof pass. Measure
substitution from an empty isolated store with builds disabled before
attributing a runtime improvement to the cache.

Exact derivations, not changed-file guesses, determine cache reuse. Runtime
fixtures must reference individual files, package-local directories (including
the test's adjacent scripts), or explicit filesets rather than interpolate
`self` paths that retain the entire flake source as a build input. The recovery
fixture includes all of its copied manifests and no unrelated applications.
Hermes image tags still identify the Git source revision; changing that
deployment provenance is not a cache optimization.

Nix store contents published by CI are public, so CI outputs must never contain
decrypted secrets.

GitHub enforces full-SHA action pins and the repository action allowlist.
Dependabot groups action updates into a weekly pull request after a seven-day
cooldown. `.github/workflows/security.yml` runs zizmor when GitHub automation
changes and rejects medium-or-higher findings.