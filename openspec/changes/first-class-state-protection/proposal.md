## Why

Current Homelab contracts identify durable storage and application recovery boundaries, but they do not define a shared model for stable state identity, protection obligations, coverage, or recovery evidence. That missing model must not become a second backup engine alongside mature tools that already own snapshot, replication, repository, retention, and application-export lifecycles.

## What Changes

- Introduce stable logical state identities that remain unchanged when deployment, realization, software version, source path, or protection policy changes.
- Separate reusable state-slot semantics from concrete state, instance policy, one authoritative live realization with nested access projections, logical protection target, Integration-owned native destination and retained-point representation, optional application payload representation, retained point, and M1-authorized scratch restore destination.
- Compile named policies and explicit target routes through Den/gen into either a diagnostic plan or a strictly resolved executable manifest. Match lifecycle-owner Integrations primarily by their required source capabilities and actual configured consistency/fidelity guarantees; use realization-kind restrictions only when a native mechanism genuinely requires one. Missing or ambiguous realization, coverage, target, or Integration fulfillment remains visible in a plan and prevents executable enablement.
- Treat zrepl, Restic and its NixOS integration, resticprofile, Borg/borgmatic, and similar established software as lifecycle owners. Homelab configures and wires selected owners; it does not independently implement their scheduling, retention, pruning, incremental transfer, resumability, repository management, snapshot lifecycle, or database dumping.
- Retain a small versioned, language-independent adapter boundary. An adapter exposes the lifecycle owner's native operation as one capability where appropriate; the protocol does not require every owner to decompose work into Preserve-specific capture, protect, release, or retry stages.
- Keep `homelab-preserve` limited to inspection, fixed safe dispatch, recovery-point selection, scratch-destination safety, and verification. Unsupported owner operations remain unsupported rather than being recreated in the coordinator.
- Qualify recovery evidence by logical state, route, target, owner, and native point identity. Retain optional opaque, namespaced producer provenance without making it part of state identity or requiring generic interpretation. Each owner may satisfy source-independent recovery through its native catalog or durable metadata; Preserve does not require one universal metadata store.
- Add a deliberately small direct-ZFS reference adapter for disposable conformance testing only. It may snapshot a synthetic source, perform one full second-pool copy, enumerate points, restore into new scratch, and verify, but it is not a production replication implementation.
- Add plan-only inventory derived from the existing `/home` and `/persist` declarations, plus independent fast checks and a disposable two-pool ZFS VM recovery test. These do not enable production protection.

Non-goals include production deployment, schedules or retention policy selection, production repository or receiver provisioning, destructive in-place restore, whole-cluster recovery, a general workflow engine, application-specific consistency implementations, importing another backup framework wholesale, or changing existing storage placement and deployment ownership.

## Capabilities

### New Capabilities

- `state-protection`: Stable state identity, instance-owned protection policy, strict target and lifecycle-owner resolution, coverage validation, target-qualified recovery evidence, bounded external adapters, and explicit safe restoration.

### Modified Capabilities

None. Existing storage, management, secret, fleet-composition, and active application-recovery contracts remain applicable and unchanged.

## Impact

This adds Den/gen state-protection declarations and checks, evaluated inventory and executable manifests, a minimal `homelab-preserve` command, thin lifecycle-owner adapter seams, inactive representative zrepl and NixOS Restic configuration projections, a fixture-only direct-ZFS reference adapter, and independent model/protocol/VM CI evidence. M1 does not enable a mature owner for real state, import SelfHostBlocks, modify existing active OpenSpec changes, or require a broad dependency upgrade.
