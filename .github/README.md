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
nix build --option sandbox relaxed .#checks.aarch64-linux.prod-home-replacement
```

The Linux VM checks run the same scenarios on x86-64 and ARM64. Compute fixtures
select the `prod-home` cluster's declared host and guest. The deployed architecture
is evaluated verbatim; ARM exercises a hypothetical native variant without
changing production configuration. Execution requires a suitable Linux/KVM builder.

Manual dispatch builds the same full projection by default. To run one existing
flake check, set `check` and optionally `system` (default `x86_64-linux`):

```sh
gh workflow run ci.yml --ref "$REF" -f check=prod-home-replacement
```

Check names and implementations belong in Nix, not workflow branches. Successful
check jobs upload their output paths as `check-output-<system>-<run-id>` artifacts;
build logs, including failures, remain in the Actions job logs. Linux runners
enable available KVM acceleration and permit tests with explicit sandbox opt-outs.
System builds and checks bypass Hestia's whole-NAR memory buffering, using the
durable/upstream caches instead.

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