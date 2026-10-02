## Why

Current verification mixes useful safety checks with source-text comparisons, copied configuration, weak selection checks, and large runtime scenarios. Separate the evidence layers so failures are caught earlier without replacing real authorization, storage, or recovery proof with faster but vacuous checks.

## What Changes

- Remove tests that only pin implementation text, incidental defaults, copies, or mock forwarding. Keep behavioral and safety assertions even when they are small or use controlled fakes.
- Require representative passing and failing cases for each new or migrated safety check. Reject silent success from empty selection, missing schemas, unexpected skips, or swallowed errors.
- Add pinned, offline Kubeconform validation of the actual canonical manifests, including schemas from the deployed CRDs and explicit schema-coverage accounting.
- Use the Kyverno CLI for a bounded pilot of semantic manifest policy; retain existing meaningful Python/Nix checks unless the pilot demonstrates a simpler replacement with equivalent negative coverage. Do not install Kyverno controllers.
- Use Chainsaw for focused scenarios against a disposable target-version K3s API/controllers. Move Kubernetes-only behavior out of broad NixOS VM scenarios only after replacement evidence exists.
- Keep Nix for declared-state generation and custom Nix/Den semantics, Go/local execution for local algorithms, and narrow Linux VM coverage for host mounts, ID maps, filesystem permissions, firewall behavior, service activation, and actual guest recovery.
- Make selected scenario coverage and failure reports part of CI success. Measure setup, execution, warm/cold behavior, and external-fetch failures separately; do not promise a runtime reduction before comparison.

## Capabilities

### New Capabilities

None. This changes verification tooling and evidence, not intended infrastructure behavior. The change explicitly skips delta specs.

### Modified Capabilities

None. Existing current contracts retain authority. Active application/recovery proposals remain proposed until accepted; this work does not promote their contents into current requirements.

## Impact

Affected areas are `modules/tests`, `modules/flake/kubernetes-manifests.nix`, CI projection/workflow definitions, relevant compute-runtime tests, and the later-integrated Jellyfin/media scenarios. Tool and schema versions belong in Nix-owned inputs/derivations; generated manifests remain desired-state artifacts, not a second policy authority.

The slice lands after the active application work and rebases onto its accepted revision. No production admission webhook, new application behavior, host activation, secret migration, destructive data operation, or production deployment is included. A live policy engine or a change to runtime security/storage guarantees requires a separate semantic decision.
