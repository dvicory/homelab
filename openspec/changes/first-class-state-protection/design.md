## Context

See `proposal.md` for motivation and `specs/state-protection/spec.md` for the proposed contract.

Current repository evidence fixes the Homelab-specific seam:

- Den already treats aspects as behavior and pipes as accumulated aspect data. `persist` is declared as a quirk, emitted by aspects, and consumed by `modules/den/aspects/core/persist-collector.nix`; protection can use the same composition boundary without equating persistence with a completed backup.
- `modules/den/aspects/disk/zfs/pool.nix` declares `rpool/safe/home` mounted at `/home` and `rpool/safe/persist` mounted at `/persist`. `modules/den/aspects/disk/impermanence.nix` marks `/persist` as needed for boot and projects selected paths into it. These declarations, not runtime probing or packet examples, are the source for the first real plan.
- The immutable inputs are Den `5f78bef87047c5ecd632a5a23c9b3718f1de3301`, gen-schema `fd79d909cf5a84be0f902dacf4202044642d44af`, and gen-scope `3bc93dfdb49da9ae06ce84a1d35905a1c138de99`. The selected gen-schema provides identity keys, typed records/references, validators, registries, and codecs. The selected gen-scope provides `mkKind`, `mkKinds`, `mkClaim`, and `resolveClaims`; its cascade owns descending claim expansion, conflict refusal, unresolved work, wiring, and provenance.
- Flake packages are assembled in `modules/flake/packages.nix`; checks are ordinary per-system outputs. `modules/flake/ci.nix` currently groups all checks together, while `.github/workflows/ci.yml` already uses `fail-fast: false` and supports direct check dispatch.
- Before this change, `den-semantics`, `storage-roots-contracts`, and `check-flake-file` build successfully on `aarch64-darwin`. No state-protection model or operation surface exists.

The implementation survey further narrows what Homelab should own:

- Pinned nixpkgs packages zrepl 0.7.0. `services.zrepl.settings` generates its YAML and runs its daemon. zrepl jobs own periodic/manual snapshot policy, incremental and resumable replication planning, sender/receiver holds and bookmarks, conflict handling, pruning, status, and Prometheus metrics. Local push/sink transport already supports a second local pool.
- Pinned restic is 0.19.1. `services.restic.backups` owns systemd timers, optional repository initialization, file or command backup, forget/prune, repository checks, hooks, and a fixed-environment `restic-<name>` wrapper for native operations including snapshot listing and restore.
- Pinned resticprofile is 0.33.1. It owns profile inheritance, schedules, retention, checks, repository copy, status/monitoring, hooks, lock handling, and native Restic commands. It is packaged here but has no NixOS module selected by this repository.
- Pinned borgmatic is 2.1.7. `services.borgmatic` generates and build-validates configuration and supplies the upstream service/timer. Borgmatic owns repository actions, retention, checks, extraction, hooks, filesystem snapshot data sources, and PostgreSQL/MySQL/MariaDB/SQLite dump and restore integration with pinned tools.
- SelfHostBlocks commit `991a496b7cc97a591ad1a4cbd5d7cd6dfd23a3d1` demonstrates request/provider/result contracts. Its ZFS block contributes file and dataset backup requests; Restic and Borg providers project those into existing NixOS modules and return service/restore entry points. This separation is useful evidence, but the current file restore helpers target `/`, and the Sanoid helper performs recursive rollback. Those operations do not meet this change's scratch-only restore boundary, so SelfHostBlocks is not imported wholesale.

Four active Homelab changes overlap the subject but remain read-only. Preserve must not restore disposable cluster state, claim application consistency from a filesystem point, change storage placement, or mark another change's capture tasks complete.

## Goals / Non-Goals

**Goals:**

- Make state declarations genuine Den contributions evaluated through gen-backed identity, references, and claims.
- Keep StateSlot, State, Realization, ProtectionPolicy, Target, Route, Integration, ScratchDestination, and native RecoveryPoint meanings distinct without forcing one registry per noun.
- Validate that selected lifecycle-owner configuration actually covers the declared state and targets.
- Produce a useful non-operational plan for current `/home` and `/persist` plus a fully executable synthetic reference plan.
- Ship the smallest useful `homelab-preserve` inspector, fixed dispatcher, scratch guard, and verifier with easy external adapter registration.
- Prove the adapter and recovery contracts through a deliberately simple direct-ZFS reference adapter in a disposable VM.

**Non-Goals:**

- Building a production backup or replication engine or replacing zrepl, Restic/resticprofile, Borg/borgmatic, Sanoid, or application-native exporters.
- Owning production scheduling, pruning, retention, incremental chains, replication cursors/holds, resumability, receiver lifecycle, repository management, database dumping, or restore into active state.
- Choosing or enabling a production lifecycle owner, target, cadence, retention policy, key boundary, or topology in M1.
- Changing nixidy, compute lifecycle, existing OpenSpec changes, or independently developed application internals.

## Decisions

### Record lifecycle ownership as the architecture decision

Create the new `state-protection` capability rather than broadening `storage-foundations`. Add ADR-0009 for the architecture-significant choice: Den/gen owns stable logical identity, policy and target resolution, coverage validation, and capability wiring; selected mature tools retain backup/replication lifecycle ownership; a small operation surface safely dispatches and verifies their native operations.

The ADR will relate to ADR-0006 and ADR-0008 without modifying them. It will link this active change, not treat its delta spec as current authority.

*Alternatives considered:* adding requirements to `storage-foundations` would make logical state and recovery semantics appear to be physical-storage lifecycle. Extending `reliable-household-services` would make a fleet-wide capability application-specific. A new general backup engine would duplicate mature lifecycle owners.

### Use a Den pipe and the smallest useful gen-schema record set

Declare a `preserve` quirk. Aspects contribute state-protection fragments; a collector evaluates and compiles them. This mirrors the persistence collector while preserving the distinction between reboot persistence and recoverable protection.

The semantic model retains these meanings:

- StateSlot is a reusable registry describing data kind, required semantic consistency/fidelity, and any genuinely required application payload format without fixing runtime authorization or backup-engine container formats.
- State gives one concrete logical resource its stable `stateId`, typed StateSlot reference, and instance policy.
- Realization describes the one authoritative live capability boundary. Incus, container, Kubernetes, and microVM paths are nested access projections when they expose that same boundary.
- ProtectionPolicy is a reusable registry selecting required Routes; each Route has its own stable identity, names a logical Target, may select an Integration, and states only genuine semantic outcome constraints.
- Target describes a logical destination, purpose, or failure domain without embedding a Restic/Borg repository, ZFS receive dataset, bucket, remote, credential, or native retained-point format.
- Integration describes one externally implemented lifecycle owner or bounded reference adapter through identity, required source capabilities, actual configured consistency/fidelity guarantees, exceptional kind constraints, native retained-point representation, and a packaged adapter reference.
- Shared Integration+Target wiring declares reusable owner-native destination/credential configuration once; optional Binding adds only irreducible State+Route source narrowing, unresolved-Route Integration selection, or namespaced native overrides.
- ScratchDestination constrains M1 recovery output; scratch-only authorization is not StateSlot semantics.

Use gen-schema registries for independently reusable and referenced StateSlot, State, ProtectionPolicy, Route, Target, and Integration values. Keep Realization, nested access projections, non-authoritative `physicalBacking`, Binding, and ScratchDestination as typed nested/list data unless implementation proves another independent identity is required. Typed object references are used inside Nix; generated manifests carry stable public IDs and resolved values. State identity is keyed only by `stateId`; declaration module, Realization, path, package, lifecycle owner, software version, selector result, and policy do not enter it.

M1 keeps explicit State declarations colocated with the natural host or aspect and lets deployment aspects contribute matching Realizations. `/home` and `/persist` remain explicit typed States beside `hvn-hyp1`; this is colocated declaration, not a separate inline sugar API. Future host/aspect-local sugar may mint the same global typed State plus Realization model, but is deferred unless implementation remains trivial. Any such sugar must reject incompatible duplicate States and preserve `stateId` across host or module movement.

Stored recovery evidence carries the public `stateId` directly. Recovery points distinguish any semantic payload representation required by StateSlot/application semantics from the Integration-owned backend-native retained-point representation. A filesystem payload can live in OpenZFS, Restic, or Borg native representations without changing StateSlot; a PostgreSQL logical/custom dump may itself be stored inside a repository representation. Recovery points may also carry optional opaque producer provenance under namespaced keys. Preserve retains and displays this data but does not interpret it generically or include it in `stateId`.

The ZFS pool aspect will define its dataset map once and use that same value for disko and explicit host-local State/Realization contributions. It will emit plan-only `household/home` and `household/persist` with direct dataset-to-State association, actual dataset/path bindings, non-recursive scope, unresolved production Targets/Integrations, and application-consistency caveats. `/home` and `/persist` may use separate StateSlots, with `/persist` representing logical host-role state. The aspect performs no runtime probe and uses no namespace-plus-basename State lookup convention.

*Alternatives considered:* a standalone attrset facade would not participate in Den/gen composition. One registry per noun adds indirection without independent identity. Automatically translating every persistence entry would invent protection boundaries and consistency guarantees.

### Resolve policy, coverage, and lifecycle-owner capability through gen-scope claims

Policy resolution models three precedence inputs: concrete State assignment, supplied selector-policy defaults, then reusable slot suggestion. A level that yields multiple distinct policies fails, and a higher level replaces rather than unions lower choices. M1 tests the precedence semantics by supplying `selectorPolicies` directly; fleet selector discovery and application are not wired and remain deferred. A disposable policy is explicit and contains no routes.

Use a small demand cascade rather than a handwritten recursive resolver:

1. A state-protection claim resolves typed StateSlot and ProtectionPolicy references, the authoritative Realization, and emits one route-obligation claim per typed Route.
2. A route-obligation claim resolves its logical Target and shared Integration+Target native wiring, validates the selected Integration's required source capabilities and configured semantic guarantees against the Realization and policy outcome, applies an optional Binding only when irreducible State-specific wiring exists, and selects exactly one capable Integration unless the Route or Binding explicitly selects one.

Matching is capability-first: a Restic-style Integration requiring `filesystem-read` can consume host-path, ZFS-dataset, container-exposed, or other Realizations providing that capability. A mutable traversal using only `filesystem-read` guarantees `live`, meaning no single-point view; it cannot silently satisfy a StateSlot requiring `crash`, `filesystem`, `application`, or `database`. Stronger guarantees require a configured lifecycle-owner workflow that consumes capabilities sufficient to establish them. Realization-kind constraints are exceptional and must be justified by a native requirement such as ZFS snapshot/send requiring a ZFS dataset. Preserve does not orchestrate snapshot stages to strengthen a weaker owner workflow.

Generic consistency uses only `live` for a traversal with no single-point guarantee, `crash` for one crash-consistent point, `filesystem` for a filesystem-consistent point, and `application` or justified `database` for stronger semantic guarantees. Mechanism and format names stay in source capabilities, optional semantic payload representation, Integration-owned native retained-point representation, or namespaced fidelity. StateSlots do not enumerate backup-engine containers, and Routes do not repeat an Integration's native output format merely because they select it.

Each route obligation is identified by existing State and Route gen identities. Do not require callers to construct a delimiter-encoded Binding key; hash canonical State+Route identities only if a later persistent obligation ID is actually needed. Two explicitly required Routes remain distinct when they share a Target or Integration, but multiple Routes to one Target/failure domain are not reported as independent disaster copies. One Route with several capable Integrations remains one ambiguous obligation until Route or Binding selection chooses one.

Typed internal Integration+Target wiring declares reusable native destination, credential reference, and shared owner configuration once. A normal State whose Policy selects a Route and whose Realization supplies the required capabilities needs no Binding. An optional Binding references State and Route only when it adds irreducible source narrowing, unresolved-Route Integration selection, or namespaced native overrides. Target comes from Route; base source locator/path and capabilities come from Realization; selected Integration comes from Route when fixed. Duplicate or contradictory repeats fail rather than silently redirecting owner configuration.

The route result records logical Target, owner identity, native operation granularity, native point identity shape, achieved semantic consistency/fidelity, optional payload representation, and Integration-owned native retained-point representation. Application-native `physicalBacking` is inventory only and cannot satisfy Routes or capability matching unless separately modeled as a State. A lifecycle owner's atomic job remains one operation; the cascade does not turn it into runtime stages.

Run the same claims in inventory and executable modes. Inventory mode materializes typed gaps and marks incomplete State non-operational. Executable mode fails for missing/duplicate Realizations, source coverage or capability gaps, missing logical Targets, contradictory Bindings, unsupported operations/consistency/fidelity, and ambiguous Integrations. JSON projection deep-forces these checks.

*Alternatives considered:* a recursive resolver would duplicate gen-scope. A global lenient switch would let invalid enabled state escape strict compilation.

### Treat mature tools as lifecycle owners, not low-level drivers

A production Integration publicly describes identity, required source capabilities, actual configured semantic guarantees, exceptional constraints, native retained-point representation, and a packaged owner-level adapter. Typed internal Integration+Target wiring records shared native destination/credential configuration once, and typed internal Nix projector registration maps a resolved State, Realization, Route, logical Target, optional Binding overrides, and Integration into native owner configuration. Projector functions are implementation code rather than public Integration data or manifest content. Adding an Integration must not require a generic resolver or Rust coordinator backend switch, and projection does not orchestrate the owner's internals.

The expected mappings are:

- zrepl: a ZFS-capable Realization plus Integration-owned native destination data become filesystem filters, job identity, transport, receiver root, snapshot/replication policy, and owner-native status. zrepl owns snapshot names, incremental planning, cursors, holds, retries, pruning, and its OpenZFS retained-point representation.
- NixOS Restic: any Realization providing `filesystem-read` can supply derived base `paths`; shared Restic+Target wiring provides repository, timer, prune/check, tag, and credential-reference configuration once, while optional Binding narrows subpaths/includes/excludes or overrides an irreducible State-specific value. A mutable traversal guarantees only `live`; a stronger stable-view workflow must be provided and declared by its lifecycle owner. The generated service and wrapper own backup and the Restic native snapshot representation.
- resticprofile: the same capabilities and logical Target become profiles and groups only if its extra scheduling/status/copy behavior is selected as the owner. Do not configure both it and the NixOS Restic service for the same Route.
- borgmatic: filesystem-read or database-export capabilities can select file, filesystem-snapshot, or database data sources; borgmatic owns dumps, repository operations, checks, retention, extraction, restore semantics, and native archive representation. Native repository and data-source details remain Integration-owned rather than changing logical Target or StateSlot identity.

M1 records and tests representative owner capability declarations and typed internal projector registration for inactive `services.zrepl.settings` and `services.restic.backups` outputs. One fixture gives a ZFS Realization `filesystem-read`, `zfs-snapshot`, and `zfs-send`; separate Routes resolve native ZFS and Restic Integrations from that same source, proving capability-first matching while retaining each configured workflow's actual consistency. Projectors derive base source values from Realization, shared native destination/lifecycle values from Integration+Target wiring, and optional State-specific narrowing/overrides from Binding. StateSlots and Routes do not enumerate owner-native retained-point containers merely because an Integration is selected. M1 does not enable any mature owner for `/home` or `/persist`. Multiple Routes to one logical Target do not prove failure-domain independence. Production owner selection requires a later OpenSpec/ADR review only if it changes a durable boundary; ordinary concrete configuration remains Nix-owned.

*Alternatives considered:* invoking `zfs send`, `restic backup`, or `pg_dump` as low-level steps inside Preserve would silently take ownership from the software designed to coordinate those steps.

### Keep the external adapter contract small and owner-oriented

Retain a versioned, language-independent executable boundary so Rust, Go, Python, or generated wrappers can integrate without linking into the coordinator. Protocol version 1 uses a bounded JSON request and response with request ID, typed result, and structured error. Adapter stderr is bounded diagnostic input and is not copied into default coordinator output. Structured adapter errors contain only operator-safe summaries; raw owner stderr and backend command output remain out of those summaries.

The common operation vocabulary is `describe`, `status`, `points`, `run`, `restore`, and `verify`. Every enabled Integration must provide the baseline inspection set `describe`, `status`, and `points`; `run`, `restore`, and `verify` remain optional:

- `run` dispatches one fixed owner-level action, such as starting a configured systemd backup job or waking a replication job.
- `points` maps the owner's native catalog into target-qualified evidence without replacing native identity.
- `restore` and `verify` exist only when that adapter can enforce the declared scratch and fidelity boundary.

Nix executable resolution checks the declared baseline operations, and Rust checks the adapter's `describe` response before invoking inspection. Integrations lacking baseline inspection remain visible in plan-only inventory but cannot become executable.

An adapter may add a namespaced owner payload and optional operations. The common protocol does not require `capture`, `protect`, `release`, retry, cleanup, or stream-handle stages. Bulk data never enters JSON. Manifest configuration fixes the executable and allowed operation; retained provenance cannot redirect execution.

Launch each adapter in its own process group. Timeout or coordinator cancellation terminates the full group, waits for exit, and then joins bounded output readers. This covers ordinary Restic, Borg, ZFS, and wrapper descendants instead of killing only the direct adapter PID; a child that deliberately escapes the configured process group is outside the adapter contract.

A small separately packaged fixture adapter proves registration without coordinator changes. Its behavior is test evidence, not a production backup implementation.

*Alternatives considered:* direct backend switches in the coordinator make each new owner a core change. A protocol that standardizes internal workflow would recreate the backup engine this boundary excludes.

### Limit `homelab-preserve` to inspection, safe dispatch, and verification

The coordinator reads two schema-versioned documents generated from one model:

- `desired-inventory` contains planned states, policy intent, realization and coverage, selected or missing lifecycle owner, route status, and structured issues.
- `executable-plan` contains only enabled, strictly resolved states, fixed adapters, targets, owner actions, point identity rules, and scratch capabilities.

The user surface is `plan`, `status`, `points <state>`, `run <state> --route <route>`, `restore <state> --from <route> --point <native-id> --to <scratch>:<new-name>`, and `verify <receipt>`, with human and JSON output. `points` returns one State report containing a result for every resolved Route; each result carries either validated points or a structured Route error, so one unavailable owner cannot hide another owner's usable evidence. `run` performs no cross-route transaction. Restore defaults to preflight and requires explicit execution.

The Rust code validates documents, fixes point selection, dispatches one adapter process group with bounded IO and timeout, enforces common scratch constraints, stores a restore receipt, and reports evidence. Native points carry explicit achieved fidelity as well as consistency. Before listing or restore, Rust validates both against the resolved StateSlot and Route requirements and the selected Integration's configured guarantee using the same small consistency relation as Nix. It contains no scheduler, retention logic, repository catalog, capture journal, retry engine, ZFS replication planner, or database compatibility table.

*Alternatives considered:* a coordinator-managed multi-route capture operation would need owner-specific compensation, retry, and lifetime semantics. Nix expressions at runtime would make Nix a restore control plane.

### Keep a direct-ZFS adapter only as a conformance reference

Package the direct implementation as `homelab-preserve-zfs-reference` and mark it fixture-only in both manifest and output. It demonstrates the minimum adapter contract against synthetic disposable pools:

1. create one non-recursive snapshot of the configured synthetic dataset;
2. retain that source snapshot and perform one full `zfs send`/`zfs receive` into a fresh second-pool fixture dataset;
3. enumerate target-qualified points using ZFS-native names/GUIDs and compact namespaced user properties for this adapter's mapping;
4. restore an exact point into a new child under an allowlisted scratch root; and
5. report native checks while an independent test oracle verifies bytes and metadata.

This adapter intentionally has no schedule, pruning, retention, incremental sends, resume tokens, replication cursor, long-lived hold management, receiver daemon, production credential model, operation journal, or general retry/cleanup framework. The VM test owns fixture setup and teardown. A failed full receive is not advertised as complete; no claim is made that the adapter is suitable for production.

The receiver's ZFS snapshot and native properties contain enough information for discovery after source-pool and coordinator-cache loss. This is one backend-native way to meet the durability invariant, not a universal Preserve metadata requirement.

*Alternatives considered:* using only mocks would not prove native recovery. Growing the adapter into a reliable production replicator would duplicate zrepl and violate the lifecycle boundary.

### Constrain scratch restore independently of owner defaults

For M1, a ScratchDestination contains an allowlisted native parent and mount root. This is coordinator authorization policy, not StateSlot semantics. The requested new name is a validated component, not an arbitrary command or path. Preflight and execute both verify destination absence, containment, source/Target non-aliasing, semantic payload and native retained-point representation compatibility, and safe native mount/share properties. Any future production or active-state restore requires a separate contract and authority model rather than changing StateSlot identity or semantics.

Use an owner's native explicit target option where it satisfies these checks. A thin owner-specific helper may fill only the missing scratch operation. Root-targeted SelfHostBlocks restore helpers and recursive rollback are evidence that a provider result cannot be accepted without this safety check.

The restore receipt fixes the native point and destination. Adapter verification reports its native scope; the VM oracle independently checks known fixture content and metadata and detects deliberate post-restore alteration.

### Keep model/protocol checks separate from the ZFS VM

Fast checks cover gen identity/reference behavior, policy and claim resolution, coverage mismatch, strict plan behavior, lifecycle-owner capability selection, manifest serialization, adapter versioning, process-group bounds, point consistency/fidelity, destination validation, and fixture adapter registration. Representative zrepl and Restic projections also evaluate through their pinned NixOS module option schemas with services disabled; raw attrset-shape checks alone are insufficient integration evidence.

The Linux-only VM uses two small virtual disks and synthetic data. It invokes the shipped coordinator and reference adapter, captures two versions, restores the explicitly selected older point twice, removes the source pool and local cache before receiver discovery, exercises unsafe destinations and incomplete receive handling, and uses an independent oracle for fidelity. It imports no production host, Incus, Kubernetes, external repository, or network service.

Expose the fast Preserve checks and ZFS VM as distinct `ciJobs.<system>` derivations and therefore distinct GitHub Actions matrix entries. Do not rely on derivation metadata that the workflow never reads. Keep unrelated checks in their existing parallel matrix entries, and do not hide failures with `continue-on-error`.

## Risks / Trade-offs

- [The pinned gen APIs may support a simpler or different record/ref shape than expected] → prove the smallest model in a focused evaluation fixture before multiplying registries.
- [A generic adapter vocabulary can drift back into workflow orchestration] → keep only owner-level operations common; owner-internal stages remain namespaced or invisible.
- [Mature owner outputs differ and may not expose complete point evidence] → advertise only mapped evidence that the integration can prove; unsupported point or restore operations remain unresolved.
- [The reference ZFS adapter may be mistaken for production tooling] → use an explicit `-reference` name, fixture-only manifest flag, no host inclusion, and documentation that names excluded lifecycle behavior.
- [The new Den pipe and pool contribution touch files near concurrent storage work] → keep model code additive, factor only the existing dataset value needed to avoid duplication, and do not edit active change artifacts.
- [Root inside the disposable VM has broad ZFS authority] → restrict configured fixture roots and state clearly that the test does not establish production least privilege.
- [The requested workspace is nested under another Git checkout] → use `path:$PWD` flake references for local evidence.

## Migration Plan

1. Update and validate this change and record ADR-0009 without modifying existing active changes.
2. Implement the minimal Den/gen model, owner-capability resolution, real plan-only inventory, strict fixture plan, and fast checks.
3. Implement the small coordinator and owner-oriented external adapter contract.
4. Implement the fixture-only direct-ZFS reference adapter and independent two-pool VM acceptance.
5. Add independent CI and maintained owner-integration, protocol, safety, and adapter documentation.
6. Run supported checks and report any Linux-builder or VM blocker precisely.

The change is additive and leaves all real states plan-only. Rollback removes the model, packages, checks, and documents; it performs no migration and has no production schedule, repository, point, or receiver lifecycle to unwind. Production owner selection, policy values, targets, credentials, and rollout remain separate operator decisions.
