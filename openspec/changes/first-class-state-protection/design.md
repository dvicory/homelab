## Context

See `proposal.md` for motivation and `specs/state-protection/spec.md` for the proposed contract.

Current repository evidence fixes several implementation seams:

- Den already treats aspects as behavior and pipes as accumulated aspect data. `persist` is declared as a quirk, emitted by aspects, and consumed by `modules/den/aspects/core/persist-collector.nix`; preserve can use the same composition boundary without making deployment resources its own inventory.
- `modules/den/aspects/disk/zfs/pool.nix` declares `rpool/safe/home` mounted at `/home` and `rpool/safe/persist` mounted at `/persist`. `modules/den/aspects/disk/impermanence.nix` marks `/persist` as needed for boot and projects declared persistent paths into it. These declarations, not runtime probing or packet examples, are the source for the first real plan.
- The immutable inputs are Den `5f78bef87047c5ecd632a5a23c9b3718f1de3301`, gen-schema `fd79d909cf5a84be0f902dacf4202044642d44af`, and gen-scope `3bc93dfdb49da9ae06ce84a1d35905a1c138de99`. The selected gen-schema exports instance registries, explicit `_identity.keys`, typed references, validators, and codecs. The selected gen-scope exports `mkKind`, `mkKinds`, `mkClaim`, and `resolveClaims`; its cascade returns resources, wiring, unresolved work, and provenance and rejects resource collisions instead of selecting by order.
- The direct `gen-algebra` input is currently unused. This change does not add a use merely to increase the number of gen libraries involved and does not change any pin unless a reproduced generic defect requires it.
- Flake packages are assembled in `modules/flake/packages.nix`; checks are ordinary per-system outputs. `modules/flake/ci.nix` currently groups all checks together, while `.github/workflows/ci.yml` already uses `fail-fast: false` and supports direct check dispatch.
- Before this change, `den-semantics`, `storage-roots-contracts`, and `check-flake-file` build successfully on `aarch64-darwin`. No preserve package, manifest, protocol, or VM check exists.

Four active changes overlap the subject but remain read-only during this work. Preserve must not restore disposable cluster state, claim that a filesystem point is application-consistent, change storage placement, or mark another change's application capture tasks complete.

## Goals / Non-Goals

**Goals:**

- Make state declarations genuine Den aspect contributions evaluated through gen-backed types and claims.
- Keep logical identity, live realization, protection policy, capture, retained point, and restore output distinct in code and serialized data.
- Produce a useful non-operational plan for current `/home` and `/persist` plus a fully executable synthetic ZFS plan.
- Ship one coordinator and small external drivers that can be installed and interpreted without reevaluating Nix.
- Prove native local and second-pool recovery through the shipped executables in a disposable VM.

**Non-Goals:**

- Resolving application-specific database/filesystem consistency, changing nixidy or compute lifecycle, or recovering Kubernetes control-plane state.
- Choosing production cadence, retention, receiver authority, encryption transport, target geometry, or key custody.
- Incremental ZFS replication, target pruning, automatic scheduling, in-place restore, or a general operation graph.
- Modifying any pre-existing OpenSpec change during this work.

## Decisions

### Record one new capability and one architecture decision

Create the new `state-protection` capability rather than broadening `storage-foundations`. The capability applies to filesystem and future database or opaque state regardless of whether physical storage is host-owned. Add ADR-0009 for the architecture-significant choice: Den/gen compiles platform-neutral state capabilities, a Rust coordinator performs explicit operations through external versioned drivers, and retained representations remain native.

The ADR will relate to ADR-0006 and ADR-0008 without modifying them. It will link this active change, not treat its delta spec as current authority.

*Alternatives considered:* adding requirements to `storage-foundations` would make logical state and restore semantics appear to be physical-storage lifecycle. Extending `reliable-household-services` would make a fleet-wide capability application-specific and would edit concurrent work.

### Use a Den pipe as the declaration boundary and gen-schema as the typed model

Declare a `preserve` quirk. Aspects contribute model fragments to that pipe; a preserve collector evaluates the fragments into typed registries and compiles their claims. This mirrors the existing persistence collector while keeping persistence and protection separate: declaring a persistent path does not claim a retained recovery point exists.

Use gen-schema instance registries for state slots, states, realizations, policies, routes, targets, drivers, and scratch destinations. References between those records use the selected gen-schema reference type. Public state identity is a required textual `stateId`; each state sets `_identity.keys = [ "stateId" ]`. Mutable realization, package, path, version, selector result, and policy fields are excluded from that identity. Stored recovery metadata carries `stateId` directly so future internal hash changes do not make old points undecodable.

A state is concrete fleet data. A state slot is reusable behavior metadata. A realization binds a concrete state to one live access capability. Policies name ordered-independent route sets; routes name a target and optionally an implementation. Drivers declare supported operations, data kinds, representations, and the trusted packaged executable. Scratch destinations declare both a native child-dataset root and a mount-path root.

The ZFS pool aspect will define its dataset map once and use that same value for the disko dataset configuration and preserve contributions. It will emit plan-only `household/home` and `household/persist` states with their actual `rpool/safe/home` and `rpool/safe/persist` realizations, non-recursive dataset scope, desired named policies, and explicit unresolved external targets. It will not inspect mounts, dataset contents, or the host.

*Alternatives considered:* a standalone attrset facade would not participate in Den composition or gen identity/reference validation. Automatically translating every persistence entry would confuse reboot persistence with protection and invent state boundaries for paths that may need application-aware capture.

### Resolve policy deterministically, then use the gen-scope cascade for obligations

Policy selection has three explicit precedence levels: concrete state assignment, matching fleet selector defaults, then a reusable slot suggestion. A level that yields more than one distinct policy is an error. A higher level replaces rather than unions lower-level choices. A disposable policy contains no routes; it is an explicit result, not what happens when fulfillment is missing.

Use a two-level demand cascade:

1. A `state-protection` claim validates policy and authoritative realization and emits one `route-obligation` claim per named route.
2. A `route-obligation` claim resolves the target, required realization capability, representation, and exactly one eligible configured driver, then emits one serialized route result.

The cascade is static claim compilation, not runtime sequencing. Domain glue performs compatibility checks and formats diagnostics, while gen-scope owns descending claim expansion, collision refusal, unresolved work, wiring, and provenance.

Run the same claims in two modes. Inventory mode materializes typed gaps as route results and marks the state non-operational. Executable mode throws with state and route context for missing or duplicate realizations, missing targets, unsupported methods, or zero/multiple eligible drivers. JSON projection deep-forces validation so a consumer cannot bypass errors by reading only one convenient field.

*Alternatives considered:* a recursive state-to-route resolver would duplicate the pinned cascade. Treating plan mode as `ignoreErrors` would allow invalid enabled resources to escape validation.

### Serialize separate inventory and executable documents

Protocol-independent manifest schema version 1 has two document kinds:

- `desired-inventory` contains all planned states, selected policy intent, known realization bindings, route status, caveats, and `operational: false` where incomplete.
- `executable-plan` contains only explicitly enabled, fully resolved states, fixed driver references, targets, routes, and scratch capabilities.

Expose the evaluated documents as Nix packages so they are inspectable files, including a real-host inventory and a synthetic two-pool fixture plan. The runtime reads a compatible JSON document and never needs a live Den evaluator or source checkout.

The coordinator accepts an explicit `--manifest` path. Its user-facing commands are `plan`, `status`, `points <state>`, `capture <state>`, `restore <state> --from <route> --point <id> --to <scratch>:<new-name> [--dry-run|--execute]`, and `verify <receipt>`, each with JSON output. `restore` defaults to a non-mutating preflight and requires explicit execution.

*Alternatives considered:* one document with a global lenient switch would blur operational authority. Embedding Nix expressions in runtime requests would make Nix a restore control plane.

### Use one Rust package with separate executable targets and a language-independent protocol

Build one Cargo package with distinct `homelab-preserve` and `homelab-preserve-zfs` binaries. Shared Rust types cover only the versioned protocol and common manifest/receipt structures; coordinator modules contain no ZFS command construction. Package a separate test-only Python driver to prove that adding an executable does not require coordinator changes or recompilation.

Protocol version `1.0` uses one bounded JSON request on stdin and one bounded JSON response on stdout; diagnostics use stderr. Every envelope includes the version, request ID, operation, typed payload, and either a typed result or structured error. The operations are `describe`, `observe`, `points`, `capture`, `protect`, `restore`, and `verify`. Capture returns a scoped stable-view handle; protect consumes that handle for a named route; restore accepts one target-qualified point and one configured destination capability. Handles and backend locators are adapter-owned versioned objects, not arbitrary shell fragments.

The coordinator validates driver capabilities before mutation, starts only the executable fixed in the manifest, drains stdout and stderr concurrently, applies time and size bounds, checks child exit status, and rejects malformed, truncated, oversized, or incompatible responses. Point provenance may record a historical package path, but dispatch never reads it as executable configuration.

The test-only driver implements a stable-view consumer and optional fixture barrier. In the VM, it can signal after receiving the snapshot view, wait while the test mutates the live dataset, and then verify that it still reads the captured bytes. Its output is fixture evidence, not a recovery point.

*Alternatives considered:* a dynamic in-process plugin ABI adds language and linking constraints. A generic privileged command field would defeat protocol validation. Base64 backup bytes in JSON would defeat output bounds and streaming.

### Store native ZFS point metadata on the retained representation

Use the pinned OpenZFS commands rather than parsing send streams. For one capture, the ZFS driver:

1. validates the configured source dataset and non-recursive scope;
2. allocates a capture ID, creates one snapshot, and applies a hold;
3. records the local route's complete point descriptor in namespaced ZFS user properties on that snapshot;
4. exposes the read-only snapshot tree as the stable filesystem-view handle;
5. performs a full property-preserving send into a fresh staging child under the configured receiver root;
6. validates the received snapshot and native GUID, writes a replica-specific descriptor on it, and only then marks the replica point complete; and
7. retains the local snapshot while releasing only temporary operation resources.

Each full replica point is a fresh child dataset. This is deliberately space-inefficient but makes points independent and avoids incremental-chain lifetime rules in M1. Received datasets use explicit safe mount/share properties and cannot inherit a source mountpoint over an active path.

Point discovery enumerates snapshots only beneath the configured target root, reads the namespaced descriptor properties, and cross-checks descriptor state, route, target, dataset ancestry, completion, and native GUID. It ignores incomplete staging datasets. Because the replica descriptor lives on the receiver snapshot, discovery and restore continue after source-pool export and removal of the coordinator journal.

A route failure leaves the complete local point and returns partial/nonzero status. The operation journal records capture identity, route receipts, owned staging names, and completion under an explicitly configured runtime path. Retry may remove or reuse only a staging dataset whose native location and operation marker both match the current configured receiver root; it never prunes complete points.

*Alternatives considered:* source-side clones do not prove receiver recovery. A coordinator-only SQLite/JSON catalog is useful as a cache but fails the source-loss requirement. One mutable receiver dataset would need destructive rollback or overwrite semantics.

### Restore by native copy into a new constrained child dataset

A scratch capability contains an allowlisted ZFS parent and mount root. The requested new name is one validated path component, not a dataset or path supplied verbatim. Preflight and execute both verify parent ancestry, source/target non-aliasing, destination absence, mountpoint containment, protocol/format compatibility, and safe ZFS properties.

Restore uses a full send/receive or clone only when its dependencies remain valid; the source-independent replica path uses send/receive into a fresh child. The destination receives explicit `canmount`, mountpoint, share, and device-execution safety properties rather than inheriting them from the point. No `zfs receive -F`, rollback, original-path mount, or active-state replacement exists.

The restore receipt fixes the selected point and destination. Native verification checks the retained snapshot identity, the restored snapshot identity, and whether the mounted scratch dataset has diverged from that restored snapshot. The independent VM oracle checks known bytes, layout, UID/GID, modes, symlink, hardlink inode identity, representative ACL/xattr behavior, and sparse allocation. It deliberately alters one restored file and requires `verify` to fail. Filesystem consistency remains distinct from application validity.

*Alternatives considered:* copying from a mounted live tree loses native point identity and can race. Trusting a prior success receipt would not inspect the restored result.

### Keep fast checks and the ZFS VM independently runnable

Add fast checks for model identity and resolution, manifest serialization, Rust/protocol behavior, fixture-driver interoperability, partial reporting, output bounds, and restore-destination validation. These run without ZFS, Incus, or Kubernetes.

Add a Linux-only `preserve-zfs` NixOS test with two small virtual disks. The Python test driver creates and later destroys only its fixture pools, seeds synthetic data, invokes the shipped CLI and drivers for every protection operation, and independently asserts results. It does not implement snapshot, send, receive, restore, or driver verification itself.

Give `preserve-zfs` its own `ciJobs` group and GitHub Actions matrix entry on Linux, exclude it from the aggregate fast-check group to avoid duplicate execution, keep `fail-fast: false`, and retain direct check dispatch. It does not depend on `prod-home-replacement`, `compute-storage-zfs`, a registry image, or network access after Nix inputs are available.

*Alternatives considered:* adding the VM derivation only to the aggregate `checks` link farm would expose a flake check but would not give it independent CI status or scheduling.

## Risks / Trade-offs

- [The pinned gen APIs may expose a narrower Nix-module bridge than their public examples suggest] → write focused evaluation tests against the immutable pins first; keep compatibility glue local and report a generic defect before changing any input.
- [The new Den pipe and pool aspect touch files near concurrent storage work] → keep model code additive, factor only the existing dataset value needed to avoid duplication, and do not edit active change artifacts.
- [ZFS user-property size and propagation may vary] → keep descriptors compact, test actual property-preserving send/receive behavior in the VM, and fail if required metadata does not round-trip.
- [Full per-point replicas use more time and space] → use tiny fixtures, state the limitation, and defer incremental retention design rather than adding an unsafe chain manager.
- [Root inside the disposable VM has broad ZFS authority] → restrict driver configuration and dataset ancestry checks, document that this is not production least privilege, and make no host installation or sudo change.
- [A filesystem-native verification can miss application semantics] → report its exact scope and retain an independent known-fixture oracle; application-specific validation remains separate work.
- [The requested workspace is nested under another Git checkout] → use explicit `path:$PWD` flake references for local evidence so Nix evaluates this Jujutsu workspace rather than its enclosing Git repository.

## Migration Plan

1. Add and validate the new OpenSpec change and ADR without modifying existing active changes.
2. Add the pure Den/gen model, real plan-only inventory, strict synthetic plan, and focused evaluation checks.
3. Add the Rust package, protocol fixtures, and fast tests.
4. Add the ZFS driver and independent two-pool VM acceptance.
5. Add independent CI projection and maintained usage/adapter documentation.
6. Run local supported checks and report any Linux-builder or VM blocker precisely.

The change is additive and leaves production enablement off. Rollback removes the preserve outputs, packages, aspect contributions, checks, and documents; it performs no data migration and has no production point or schedule to unwind. A later production rollout requires a separate operator decision and verified target, authority, encryption, retention, consistency, and restore procedures.
