# State protection

Preserve names durable data, evaluates its protection requirements, and provides inspection and guarded recovery commands. Backup and replication tools retain ownership of their data lifecycles.

The `/home` and `/persist` declarations are plan-only. No production protection, lifecycle owner, repository, or restore into active state is enabled.

## Responsibilities

Den and gen own:

- stable logical State identity;
- reusable StateSlot and ProtectionPolicy records;
- one authoritative live Realization with nested access projections;
- logical Target and Route resolution;
- capability, semantic consistency, fidelity and coverage checks;
- Integration selection and native owner configuration projection.

Lifecycle-owner software owns schedules, snapshots or exports, transfer, retention, pruning, repositories, native catalogs, checks and native restore behavior. `homelab-preserve` inspects the evaluated plan, dispatches one declared owner action, constrains restore to authorized scratch and verifies receipts.

## Implementation entry points

| Purpose | Path |
| --- | --- |
| Gen-schema records and registries | `modules/den/schema/preserve.nix` |
| Gen-scope claim resolution | `modules/den/gen-scope/preserve.nix` |
| Internal zrepl and Restic projectors | `modules/den/gen-scope/preserve-projectors.nix` |
| Den pipe and collection policy | `modules/den/quirks/preserve.nix`, `modules/den/policies/preserve.nix` |
| NixOS document projection | `modules/den/aspects/preserve/collector.nix` |
| Current `/home` and `/persist` declarations | `modules/den/hosts/hvn-hyp1/default.nix` |
| ZFS Realization contribution | `modules/den/aspects/disk/zfs/pool.nix` |
| Coordinator | `pkgs/by-name/homelab-preserve/` |
| Fixture protocol adapter | `pkgs/by-name/homelab-preserve-fixture-adapter/` |
| Direct-ZFS reference adapter | `pkgs/by-name/homelab-preserve-zfs-reference/` |

## Model

StateSlot, State, ProtectionPolicy, Route, Target and Integration are typed identity-bearing registries. Nix declarations use typed object references. Generated manifests use stable public IDs and resolved values.

A State ID does not include its declaration file, host, path, deployment kind, package, Integration, Target or policy. Moving `household/home` to another host changes its Realization but not its State identity.

An enabled State must have exactly one authoritative Realization. Incus disks, container binds, Kubernetes host paths/local volumes and microVM shares remain nested access projections when they expose the same source boundary. `physicalBacking` on an application-native Realization is inventory only and cannot satisfy that State's Routes.

Consistency values are semantic:

- `live`: a traversal with no single-point guarantee;
- `crash`: one crash-consistent point;
- `filesystem`: one filesystem-consistent point;
- `application` or `database`: a stronger owner-proven semantic point.

A Realization supplies source capabilities and boundaries. It does not guarantee retained-point consistency. The selected Integration declares the source capabilities its configured workflow consumes and the consistency/fidelity it actually guarantees. `filesystem-read` alone provides no single-point guarantee.

A Target identifies a logical destination or failure domain. Restic repositories, Borg repositories, ZFS receive datasets, buckets, remotes and credential references live in namespaced Integration+Target native wiring. Multiple Routes to one Target are distinct obligations, not independent disaster copies.

Resolved Routes carry internal owner-emitted `targetBoundaries`: absolute
operation-host `paths`, opaque `nativeLocators`, and the owner-defined
`nativeNamespace` for those locators. This is authorization metadata, not
another Target registry or identity input. A registered projector derives
it from resolved native configuration; an independently configured owner may
supply the same typed data in shared Integration+Target wiring.

Both documents carry required `protectedRealizations` and `protectedTargets`
lists independently of executable States. They retain all authoritative source
contributions and known owner-resolved Target fences, including plan-only
States. Disabling an operation does not delete live data or retained points.

Restore preflight, execute revalidation and receipt verification check these
document-wide fences. Filesystem paths resolve symlink aliases. An opaque
object locator requires a separate authoritative path; `physicalBacking`
cannot supply it. Native Target locators require comparable owner-defined
namespaces. Missing, empty or unusable fences refuse destination authorization;
they do not disappear merely because their owner supports inspection only.
Baseline-only owners can remain inspectable with incomplete Target fences.
Enabled restore integrations require nonempty owner-resolved fences, and owners
repeat native checks immediately before mutation.

A normal compatible State requires no Binding. Optional Bindings contain only irreducible State-specific subpath/include/exclude narrowing, owner selection for an unresolved Route, or namespaced native overrides.

Source paths, required filesystem children and include/exclude selections must be
absolute and contain no empty, `.` or `..` components; `/` is valid. A subpath
is relative and follows the same component rule. Coverage uses the selected
base and includes, with exclusions taking precedence.

Policy precedence models concrete assignment, supplied `selectorPolicies` defaults, then slot suggestion. That precedence is implemented and tested with directly supplied selector inputs; fleet selector discovery and application are deferred and not wired.

## Current inventory

`hvn-hyp1` declares plan-only States `household/home` and `household/persist` as explicit typed State declarations colocated with their operator-natural host configuration, plus matching Realizations contributed by the ZFS aspect. This is colocated declaration, not an implemented inline sugar API. The ZFS aspect explicitly maps them to `rpool/safe/home` and `rpool/safe/persist` from the same evaluated dataset map used by disko.

Both Realizations are non-recursive and expose `filesystem-read`, `zfs-snapshot` and `zfs-send`. Their Routes have no production Target or Integration, so they appear as unresolved and cannot operate. `/persist` uses separate logical host-role semantics from `/home`.

`/persist` deliberately retains the compute state parent
`/var/lib/homelab/compute-1/state`, exposed as `/srv/state` through one required
`rprivate` Incus bind. This access is not a second authoritative source.
Guest root UID 0 maps to host 1000000, Jellyfin UID 751 maps to 1000751,
and shared media GID 505 maps unchanged while UID 505 is shifted. Retained
application paths and identities remain independently declared; a filesystem
point of the parent does not establish application consistency or cover the
separate `/srv/media` boundary. Independent applications retain their state
semantics and native recovery procedures. Persistence through reboot is not
evidence of a retained recovery point.

Inspect the installed generated documents:

```sh
homelab-preserve --manifest /etc/homelab-preserve/desired-inventory.json plan
```

The executable document's `states` list is empty until a separately reviewed configuration enables fully resolved States. Its source and Target safety lists remain present.

## Coordinator commands

Document schema version is `2`; adapter protocol version remains `1`. Old document schemas and missing safety lists are refused rather than treated as empty.

```text
homelab-preserve --manifest FILE plan
homelab-preserve --manifest FILE status [--observe]
homelab-preserve --manifest FILE points STATE
homelab-preserve --manifest FILE run STATE --route ROUTE
homelab-preserve --manifest FILE restore STATE --from ROUTE --point ID --to SCRATCH:NAME [--execute --receipt FILE]
homelab-preserve --manifest FILE verify RECEIPT
```

Add `--json` for machine-readable output. `plan` never starts an adapter. Data operations require an enabled executable State and resolved Route.

`run` invokes one fixed owner-level action. It does not expose coordinator-owned capture, stable-view, protect, release, retry or cleanup stages.

## Adapter protocol

The coordinator starts the adapter path fixed by the executable manifest with argument `protocol`. It sends one bounded JSON request on stdin and reads one bounded response envelope on stdout. Protocol operations are `describe`, `status`, `points`, `run`, `restore` and `verify`.

Every enabled Integration must provide the baseline inspection operations `describe`, `status` and `points` in both its declared `operations` and its runtime adapter capabilities; `run`, `restore` and `verify` remain optional and are checked before dispatch. An Integration missing baseline inspection stays visible in plan-only inventory but cannot become executable.

The coordinator launches each adapter in its own process group. A timeout or wait failure terminates the whole group (SIGTERM, a short bounded grace, then SIGKILL) before output readers are joined, so a backend child holding an inherited pipe cannot keep the coordinator hanging. After the direct adapter exits, residual descendants in the group are also terminated before readers finish. An adapter that deliberately detaches from its group is outside the adapter contract; legitimate asynchronous work belongs to an external service manager.

Adapters map the owner's native catalog into target-qualified points. A point records State, Route, Target, owner and immutable native identity; scope; achieved semantic consistency; explicit achieved fidelity; backend-native retained representation; optional semantic payload representation; completion; verification evidence; and optional opaque namespaced producer provenance.

Before a point is listed or restored, the coordinator validates its completion, consistency and fidelity against the resolved StateSlot and Route requirements and the selected Integration's configured fidelity guarantees. A point weaker than its resolved plan, or missing evidence, is rejected rather than advertised.

`points` returns a per-Route report: each resolved Route carries `status`, its validated points, and on failure a structured State/Route-scoped error. A capability, adapter or evidence failure on one Route does not hide points observed on other Routes, and the command still exits successfully because the report truthfully contains the failed Route evidence. Exact-route restore stays fail-closed: a failed point query or validation on the selected Route aborts the restore.

Producer provenance cannot select an executable and does not affect State identity. The currently configured compatible adapter always performs operations.

An adapter must:

- reject unsupported protocol versions and operations;
- advertise only exercised capabilities;
- keep bulk data out of JSON;
- return structured errors with operator-safe summaries (raw backend output stays on adapter stderr);
- preserve the owner's native point identity;
- enforce owner-specific destination and representation constraints before mutation.

## External Integration example

A public Integration declares identity, capabilities, guarantees and its packaged adapter. It does not contain a Nix projector function.

```nix
den.preserve.integrations.example = {
  integrationId = "example";
  owner = "example-owner";
  adapter = "${pkgs.example-adapter}/bin/example-adapter";
  operations = [ "describe" "status" "points" "run" ];
  dataKinds = [ "filesystem" ];
  requiredSourceCapabilities = [ "filesystem-read" ];
  guaranteedConsistency = "live";
  fidelityGuarantees = [ "posix-filesystem" ];
  payloadRepresentation = null;
  nativePointRepresentations = [ "example.point/v1" ];
};
```

Declare the logical Target separately and wire the owner's native destination once:

```nix
den.preserve.integrationTargets = [ {
  integration = den.preserve.integrations.example;
  target = den.preserve.targets.colo;
  native.example = {
    repository = "example:archive";
    credentialFile = "/run/credentials/example";
  };
} ];
```

Register the Nix projector in internal implementation code under `config.fleet.preserve.projectors.<integrationId>`. The generic resolver and Rust coordinator must not gain an owner-name switch. A new zrepl, Restic/resticprofile or borgmatic Integration should require declarations, one internal native projector and a thin owner-level adapter—not a coordinator workflow change.

Projector registration is optional for an independently configured external
owner exposed only through its adapter. When a projector is registered, its
resolved inputs and output must validate before an enabled executable plan
can be published; plan-only inventory reports an invalid projection rather
than implying operational configuration. Adapter availability remains checked
during runtime invocation, not by filesystem probes during pure evaluation.

The zrepl projector owns job identity, job type and source dataset filters;
native overrides cannot replace those derived values. It requires a nonempty
native source locator and refuses subpath/include/exclude narrowing it cannot
faithfully express.

Both built-in projectors reject Binding changes to shared destinations,
credentials and lifecycle settings. Restic's State-scoped `native.restic.tags`
remain overridable and become escaped `--tag` entries in the pinned NixOS
module's `extraBackupArgs`. Opaque external native fields remain the selected
owner's responsibility.

Restic subpaths must be relative, with no empty, dot or parent components.
Includes must be absolute paths inside the authoritative Realization.
These are lexical checks during pure evaluation, not live filesystem probes.

The Restic projector emits physical fences for absolute local repository
paths (including `local:/...`) and qualified native fences for backend
repository locators. It does not guess the meaning of a relative repository
or read a runtime `repositoryFile`; such cases need explicit owner-emitted
fences before they can coexist with a restore operation.

## Scratch restore authorization

Scratch restore requires:

- an explicitly named immutable native point;
- an adapter advertising explicit scratch restore;
- a configured ScratchDestination;
- one safe new destination component;
- an absent path and native destination;
- no overlap with any declared active Realization or retained Target;
- compatible payload/native representation and fidelity;
- a new receipt path for execution.

Preflight is coordinator-scoped: it checks the destination component, filesystem path and declared boundaries, inspects adapter capabilities, and selects/validates the exact native point. It does not invoke the adapter's native restore checks and does not prove that a native dataset is absent or its mount/share properties are safe. Its JSON report declares `checkedScope = "coordinator"` and that native checks remain required during execution; no mutation is performed.

Execute repeats coordinator safety checks immediately before the adapter operation. The adapter then checks native destination absence and safe native properties before mutation. `--force` is unsupported. Restore into an original path, filesystem root or active State is not authorized. Production restore requires a separate contract; it does not change StateSlot identity.

An existing dangling symlink is an existing destination, not free scratch.
Execution exclusively reserves a new receipt file before dispatching restore
and writes through that reserved handle. Relative receipt paths are supported;
existing files or dangling receipt symlinks refuse execution before mutation.
Use a stable, operator-owned receipt directory.

If dispatch or receipt writing fails, the reserved file remains, possibly
empty or partial. It is not a valid recovery receipt. Inspect the scratch
result before retrying and choose a new receipt path; Preserve does not delete
failed reservations or roll back the owner's native changes.

Receipts bind the exact retained native point and capture identity to the
restore result. Verification rechecks the receipt's destination against the
current ScratchDestination, safe name, canonical path, native locator and
all current source/Target fences. A receipt cannot grant new destination
authority. The synthetic external adapter discovers its retained catalog
rather than regenerating point metadata from current configuration.

The fixture adapter resolves `native.targetRoot` aliases canonically before
containment checks. Catalog writes use an exclusively created unique temporary
file in the catalog directory followed by atomic replacement; planted
predictable symlinks or hardlinks cannot redirect that write.

## Direct-ZFS reference adapter

`homelab-preserve-zfs-reference` is a fixture-only conformance adapter. It is absent from production Den aspects.

For one synthetic dataset it can:

1. create one non-recursive snapshot;
2. retain the local snapshot;
3. perform one full `zfs send`/`zfs receive` to a second fixture pool;
4. discover complete points from native GUIDs and ZFS user properties;
5. restore an exact snapshot into a new allowlisted scratch dataset;
6. check native mapping and detect divergence with `zfs diff`.

It refuses non-reference manifests, out-of-root dataset locators, overlapping source/receiver/scratch roots, hostile mount/share properties, incomplete points, existing destinations and unsafe receive properties. Receiver metadata supports point discovery and restore after source loss.

Verification checks the restored snapshot's actual GUID, mounted state, and
safe mount/share properties, not only its recorded mapping. The fixture
rehearses both local and receiver points; losing the source leaves a visible
local-Route failure while receiver discovery and recovery remain usable.
Scratch cleanup is checked independently against unchanged retained points.

It does not implement schedules, pruning, retention, incremental sends, resumability, bookmarks, cursors, holds, journals, retries, receiver lifecycle, repository management, rollback, `receive -F`, application consistency or active-state replacement. Passing its VM test is not evidence that direct ZFS is a production lifecycle owner.

## Checks

Fast synthetic checks:

```sh
nix build .#checks.<system>.preserve-model
nix build .#checks.<system>.preserve-protocol
```

Repository inventory contract:

```sh
nix build .#checks.<system>.preserve-inventory-contracts
```

Linux/KVM ZFS conformance:

```sh
nix build .#checks.x86_64-linux.preserve-zfs-reference
```

The VM uses disposable pools, synthetic data and an independent oracle. It does not require Incus, Kubernetes, credentials, homelab access, external repositories or production lifecycle owners.

Nix's hosted inventory places the model/protocol/inventory checks in the fast
aggregate and gives `preserve-zfs-reference` its own native x86_64 Linux/KVM
runner. No Preserve name filter or duplicate CI group selects them. The ZFS
fixture is not scheduled on hosted ARM emulation or Darwin. Direct dispatch of
`preserve-zfs-reference` uses the same registered, capability-checked VM path;
separate evaluation/build processes and the one-runtime-suite cap retain the
runner memory safeguards.
