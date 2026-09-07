---
id: ADR-0004
status: accepted
date: 2026-09-07
updated: 2026-09-07
decision-makers: [Homelab operator]
consulted: []
informed: [Homelab operator]
supersedes: []
superseded-by: []
modifies: []
modified-by: []
related-adrs: [ADR-0002]
related-specs: [management-boundaries]
related-changes: [reliable-household-services]
target-architecture: []
---

# Reconstruct managed application configuration from Nix

## Context and Problem Statement

Reducing custom integration must not transfer desired configuration back into undocumented UI state. The operator explicitly prefers Nix ownership, including the ability to reconstruct service connections and selected policy. Application records and media still require recovery from durable data.

## Considered Options

- Preserve all configuration as mutable application state and document manual setup.
- Import Nixflix's NixOS/systemd runtime into Kubernetes through an adapter.
- Declare managed configuration in thin Nix aspects and reconcile through supported application interfaces.

## Decision Outcome

Choose **thin declarative configuration with supported application interfaces**. Use native configuration first. Where a service connection requires an API, run an independent reconciliation Job rather than coupling every application restart to cross-service configuration. Nix owns explicitly declared connection, path, exposure and selected quality-policy fields; changing those fields in the UI does not override desired state. Preserve users, history, watch state, media and other undeclared application records.

Nixflix's strong ownership is desirable, but its systemd/private-helper coupling is not a Kubernetes interface. Configarr and Recyclarr cover quality policy, not the full required connection setup. Do not force them into a translator or reject them merely because they overwrite declared settings. Reuse a supported standalone implementation when it covers the actual boundary with less machinery.

### Consequences and Confirmation

- An application may restart while a peer is unavailable; configuration reconciliation can fail visibly and retry independently.
- Supported APIs create version-specific integration work. Keep the managed fields explicit and fail on incompatible APIs rather than silently choosing different policy.
- First-user enrollment and non-reproducible records are distinct from configuration. Identify any required first bootstrap explicitly; guest replacement must preserve established accounts.
- Confirm desired configuration repair after drift and preservation of retained records, not implementation details of upstream applications.
- Reconsider the runner when upstream native configuration or a supported existing tool covers the same managed fields without a private-helper adapter.

## References

- Proposed contracts: [household-services](../../../openspec/changes/reliable-household-services/specs/household-services/spec.md).
- Current ownership boundary: [management-boundaries](../../../openspec/specs/management-boundaries/spec.md).
- [Nixflix](https://github.com/kiriwalawren/nixflix).
