## Why

Updating a Nix-built Kubernetes helper currently requires importing its image into compute-1 or changing the guest's preloaded images. Publish those helpers independently so an application release can run through GitOps without host activation, guest replacement, or routine manual image imports.

## What Changes

- Add an independent helper-release guarantee to `management-boundaries`; retain its existing independent recovery and application-ownership requirements.
- Keep the existing Nix image producers. Publish secret-free, architecture-verified artifacts to public GHCR before desired state selects their manifest digests.
- Keep selected and supported rollback images in GHCR without automatic pruning. Preserve the Nix producers and locked release identities; do not add GitHub Releases, a second archive store, or an independent exact-byte recovery promise.
- Publish automatically only from an exact same-repository merged-main push after all required CI succeeds. Keep builds read-only and publication credentials in a separate main-owned publisher; PR and manual sources cannot publish.
- **BREAKING:** after publication verification, switch every Nix-built Kubernetes helper consumer to its committed digest and remove its helper preload, `Never`-only pull policy, and routine manual staging path. Keep unrelated K3s platform airgap inputs. Tests, review, and a separately approved merge still govern production selection.
- Deliver the publisher first, then perform one clean consumer cutover after real publication. Do not add a permanent empty-lock fallback or dual-mode resolver.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `management-boundaries`: require routine helper releases to be independent of the guest OS generation, with immutable publication eligibility and a trusted, secret-free publisher separated from PR-controlled code.

## Impact

Touches the four current helper producers (retained-directories, Kanidm provision, Jellyfin provisioner, and Jellarr), their Kubernetes consumers, Den image aggregation, CI release tooling, committed release identities, fixtures, and existing operations guidance. Runtime credentials stay in the existing secret-delivery flow.

This registry-only change carries forward the delivery portion of the historical `independent-application-delivery` proposal. That proposal and its completed disposable proofs remain intact as history. Guest OS activation, State protection, application internals, a self-hosted registry, a deployment controller, and changes to production secret ownership are outside this change.

The owner selected automatic merged-main publication after required CI, without a per-release approval click, and approved the four public GHCR namespaces and registry-only retention. Each PR merge and production rollout still requires separate approval. Current main does not yet promise the added helper-release guarantees.