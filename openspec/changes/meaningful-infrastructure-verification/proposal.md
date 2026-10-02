## Why

Current verification mixes useful safety checks with source-text comparisons, copied configuration, custom Kubernetes validators, and large runtime scenarios. Replace custom verification with maintained Kubernetes-native tooling where it can establish the same boundary, retaining required policy enforcement and real authorization, storage, and recovery evidence.

## What Changes

- Remove tests that only pin implementation text, incidental defaults, copies, or mock forwarding. Keep behavioral and safety assertions even when they are small or use controlled fakes.
- Require representative passing and failing cases for each new or migrated safety check. Reject silent success from empty selection, missing schemas, unexpected skips, or swallowed errors.
- Add pinned, offline Kubeconform validation of the actual canonical manifests, including schemas from the deployed CRDs and explicit schema-coverage accounting.
- Make pinned, offline Kyverno policies the required rendered-resource semantic gate. Migrate retention, ownership, source confinement, authority, identity/Gateway protection, pod security, and application/storage declaration rules; delete equivalent Python/Nix validators and their dead helpers after positive and negative replacement proof. The bounded pilot is evidence, not the final deliverable.
- Use Chainsaw and native Kubernetes operations against the existing disposable target-version K3s fixture for admission, Argo, Gateway, and runtime-Secret API behavior. Replace custom polling/assertion orchestration and Kubernetes-only NixOS VM coverage; delete superseded wrappers and registrations once equivalent required coverage passes.
- Keep Nix for declared-state generation, artifact freshness, and meaningful custom Nix/Den input semantics. Retain local application/protocol execution and narrow Linux VM proof only for boundaries Kubernetes tooling cannot establish, including host mounts, ID maps, filesystems, firewall behavior, service activation, and actual guest recovery. A custom check needs a concrete retained boundary, not a preference for its current implementation.
- Make selected scenario coverage and failure reports part of CI success. Measure setup, execution, warm/cold behavior, and external-fetch failures separately; do not promise a runtime reduction before comparison.
- Keep ordinary reviewed policy files under continuous required CI enforcement, with native positive/negative fixtures and fail-closed coverage. Distinguish repository/bundle policy from rules potentially suitable for later admission or background enforcement; this change does not deploy a Kyverno controller or claim offline evidence proves live enforcement.

## Capabilities

### New Capabilities

None. This changes verification tooling and evidence, not intended infrastructure behavior. The change explicitly skips delta specs.

### Modified Capabilities

None. Existing current contracts retain authority. Active application/recovery proposals remain proposed until accepted; this work does not promote their contents into current requirements.

## Impact

Affected areas are `modules/tests`, `modules/flake/kubernetes-manifests.nix`, CI projection/workflow definitions, relevant compute-runtime tests, and the later-integrated Jellyfin/media scenarios. Tool and schema versions belong in Nix-owned inputs/derivations; generated manifests remain desired-state artifacts, not a second policy authority.

The slice lands after the active application work and rebases onto its accepted revision. No production admission webhook, new application behavior, host activation, secret migration, destructive data operation, or production deployment is included. A live policy engine or a change to runtime security/storage guarantees requires a separate semantic decision.

The real Argo source-error scenario depends on the separately approved `fail-closed-application-source-health` change. Its production health behavior and contract delta remain owned there; this CI migration consumes that revision and proves controller behavior without silently redefining it.
