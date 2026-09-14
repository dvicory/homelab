## Why

Current Homelab contracts identify durable storage and application recovery boundaries, but they do not define a shared model for a state's stable identity, its protection obligations, the evidence that those obligations were met, or safe restoration. Adding that model now avoids coupling protection to the changing Kubernetes, Incus, host-storage, and backup implementations.

## What Changes

- Introduce stable logical state identities that remain unchanged when deployment, realization, software version, source path, or protection policy changes.
- Separate reusable state descriptions from concrete instance policy, live realizations, capture identity, retained representations, and restore destinations.
- Compile named protection policies and explicit target routes through Den/gen into either a diagnostic plan or a strictly resolved executable manifest. Required missing or ambiguous fulfillment remains visible in a plan and prevents executable enablement.
- Perform capture, discovery, scratch restore, and verification only through explicit operator commands. One stable capture may feed multiple required routes, while each retained point remains target-qualified and carries compatibility and evidence metadata.
- Use packaged, versioned executable drivers so deployment platforms and native backup representations remain outside the coordinator. Preserve native ZFS representations in the first executable slice rather than defining a universal archive format.
- Report configured intent, observed points, partial failure, restoration, and verification as distinct states. Configuration or capture success alone does not establish protection or application-consistent recovery.
- Add a plan-only inventory derived from the existing `/home` and `/persist` declarations, plus a disposable two-pool ZFS recovery test. These do not enable production capture, scheduling, retention, or restore.
- Require restore to select an immutable point and a new allowlisted scratch destination. Routine activation never performs restore or destructive provisioning.

Non-goals include production deployment, schedules or pruning, selection of final off-host topology or key custody, destructive in-place restore, whole-cluster recovery, application-specific consistency adapters, a general workflow engine, or changes to existing storage placement and deployment ownership.

## Capabilities

### New Capabilities

- `state-protection`: Stable state identity, instance-owned protection policy, strict obligation resolution, capture fan-out, target-qualified recovery evidence, external driver boundaries, and explicit safe restoration.

### Modified Capabilities

None. Existing storage, management, secret, fleet-composition, and active application-recovery contracts remain applicable and unchanged.

## Impact

This adds Den/gen state, realization, policy, target, route, and driver declarations; inspectable inventory and executable manifests; a packaged Rust `homelab-preserve` coordinator; executable fixture and ZFS drivers; focused model/protocol checks; an independent NixOS ZFS VM check; and user-facing operation and adapter documentation. It uses the current immutable Den, gen-schema, and gen-scope pins and does not require a broad dependency upgrade or a local-path input.
