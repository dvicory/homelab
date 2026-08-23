# homelab

## CI

`.github/workflows/ci.yml` runs only for pushes to `main` or `ci/**`, plus
manual dispatches. Push a temporary `ci/<name>` branch to explicitly send a
revision to the GitHub-hosted build farm. Ordinary branches and pull requests
do not start the workflow.

`modules/flake/ci.nix` automatically projects packages, checks, development
shells, formatters, NixOS and Darwin systems, and Home Manager activation
packages for x86-64 Linux, ARM64 Linux, and ARM64 Darwin. Hestia evaluates that
projection once and groups related outputs per system to limit runner startup
and duplicate dependency builds.

All jobs read the public `dvicory-homelab` Cachix cache. Only a successful push
to `main` can enter the `cachix-publish` environment and receive its per-cache
write token; `ci/**` and manual dispatches remain read-only. Nix store contents
published by CI are public, so CI outputs must never contain decrypted secrets.