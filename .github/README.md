# homelab

## CI

`.github/workflows/ci.yml` runs for pushes to `main` or `ci/**`, pull requests,
and manual dispatches. Push a temporary `ci/<name>` branch to send a revision
to the GitHub-hosted build farm without merging it.

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
parallelism.

Hosted CI omits the full ARM64 Darwin system closure. That configuration embeds
its `aarch64-linux` Virtualization.framework builder image, which a fresh hosted
macOS runner cannot build before the builder exists. Build
`darwinConfigurations.daniels-2021-mbp.system` on the workstation as the
activation gate; the remaining ARM64 Darwin groups still build in CI.

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
token. Pull requests, `ci/**`, and manual dispatches remain read-only.

Nix store contents published by CI are public, so CI outputs must never contain
decrypted secrets.

GitHub enforces full-SHA action pins and the repository action allowlist.
Dependabot groups action updates into a weekly pull request after a seven-day
cooldown. `.github/workflows/security.yml` runs zizmor when GitHub automation
changes and rejects medium-or-higher findings.