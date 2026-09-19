# State protection

This document describes the M1 state-protection interface. M1 does not enable production protection, choose a production lifecycle owner, provision a repository, or authorize restore into active state.

## Responsibilities

Den and gen own:

- stable logical State identity;
- reusable StateSlot and ProtectionPolicy records;
- one authoritative live Realization with nested access projections;
- logical Target and Route resolution;
- capability, semantic consistency, fidelity and coverage checks;
- Integration selection and native owner configuration projection.

Lifecycle-owner software owns schedules, snapshots or exports, transfer, retention, pruning, repositories, native catalogs, checks and native restore behavior. `homelab-preserve` inspects the evaluated plan, dispatches one declared owner action, constrains M1 restore to scratch and verifies receipts.

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

A normal compatible State requires no Binding. Optional Bindings contain only irreducible State-specific subpath/include/exclude narrowing, owner selection for an unresolved Route, or namespaced native overrides.

Policy precedence models concrete assignment, supplied `selectorPolicies` defaults, then slot suggestion. That precedence is implemented and tested with directly supplied selector inputs; fleet selector discovery and application are deferred and not wired.

## Current inventory

`hvn-hyp1` declares plan-only States `household/home` and `household/persist` as explicit typed State declarations colocated with their operator-natural host configuration, plus matching Realizations contributed by the ZFS aspect. This is colocated declaration, not an implemented inline sugar API. The ZFS aspect explicitly maps them to `rpool/safe/home` and `rpool/safe/persist` from the same evaluated dataset map used by disko.

Both Realizations are non-recursive and expose `filesystem-read`, `zfs-snapshot` and `zfs-send`. Their Routes have no production Target or Integration, so they appear as unresolved and cannot operate. `/persist` uses separate logical host-role semantics from `/home`.

Inspect the installed generated documents:

```sh
homelab-preserve --manifest /etc/homelab-preserve/desired-inventory.json plan
```

The executable document is empty until a separately reviewed configuration enables fully resolved States.

## Coordinator commands

Protocol and document schema version are both `1`.

```text
homelab-preserve --manifest FILE plan
homelab-preserve --manifest FILE status [--observe]
homelab-preserve --manifest FILE points STATE
homelab-preserve --manifest FILE run STATE --route ROUTE
homelab-preserve --manifest FILE restore STATE --from ROUTE --point ID --to SCRATCH:NAME
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

## M1 restore authorization

M1 restore requires:

- an explicitly named immutable native point;
- an adapter advertising explicit scratch restore;
- a configured ScratchDestination;
- one safe new destination component;
- an absent path and native destination;
- no overlap with the active source or retained Target;
- compatible payload/native representation and fidelity;
- a new receipt path for execution.

Preflight does not mutate. Execute repeats safety checks immediately before the adapter operation. `--force` is unsupported. Restore into an original path, filesystem root or active State is not authorized by M1. Future production restore requires a separate contract; it does not change StateSlot identity.

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
