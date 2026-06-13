# Work Log: Align with Sini's Den Architecture

**Date**: 2026-06-06
**Goal**: Align homelab-den with sini's reference configuration structure, eliminate infinite recursion, and establish the fleet/policy/scope-engine foundation.

## Problem Statement

Prior agents made partial progress toward sini's architecture but:
- Left `modules/flake/den.nix` with a `__findFile` hack and commented-out code
- `defaults.nix` references `inputs.self` directly in lambda contexts, causing infinite recursion during `nix flake check`
- Host schema uses static freeform settings instead of dynamic `buildSettingsModule`
- Missing policies (pipes.nix), schema (group.nix), user registry, core user aspects
- Fleet.nix missing `host-to-users` excludes and `intoAttr` guard
- den input was behind sini's revision

## Decisions Made

1. **defaults.nix**: Keep similar structure to sini's, use `den.batteries.primary-user`, `inputs'`, `self'`
2. **Custom nixos config**: Move openssh/vim/stateVersion/deployment/mutableUsers to `core/base` aspect
3. **Settings**: Adopt sini's dynamic `buildSettingsModule` from aspect tree
4. **Users**: Migrate to user registry + ACL (den.users.registry)
5. **flake/den.nix**: Simplify to sini's minimal `imports = [ inputs.den.flakeModule ]`
6. **Batteries**: Adopt primary-user, inputs', self'
7. **Fleet**: Align with sini's excludes and guards

## Completed Work

### Phase 1: Foundation (fix recursion, align structure) ✅

- [x] 1. Create aspirational-work/ log (this file)
- [x] 2. Simplify modules/flake/den.nix → minimal `imports = [ inputs.den.flakeModule ]`
- [x] 3. Rewrite defaults.nix → sini's batteries pattern (primary-user, inputs', self')
- [x] 4. Create core/base aspect for system defaults (openssh, vim, deployment opts, etc.)
- [x] 5. Replace static settings with dynamic buildSettingsModule in schema/host.nix
- [x] 6. Add policies/pipes.nix for cross-host quirk collection
- [x] 7. Add schema/group.nix + update topology.nix
- [x] 8. Add gen-algebra input
- [x] 9. Reorganize aspects to match sini's directory structure:
    - `core/firewall-collector.nix` → `core/network/firewall-collector.nix`
    - `core/secrets-collector.nix` → `core/secrets/collector.nix`
    - `core/sudo.nix` → `core/security/sudo.nix`
    - `core/time.nix` → `core/localization/time.nix`
    - `core/nix.nix` → `core/nix/nix.nix` + `core/nix/stateVersion.nix`

### Phase 2: User System ✅

- [x] 10. Create user registry (users/daniel.nix)
- [x] 11. Create group definitions (groups/default.nix: admins, system-access, server-access)
- [x] 12. Add core/users aspects:
    - `resolved-user-emitter.nix` — emits user data per user scope
    - `users.nix` — enriches NixOS accounts from registry (ACL-driven)
    - `shell.nix` — zsh default shell
    - `home-manager.nix` — HM shared config
    - `root-user.nix` — copies wheel SSH keys to root
- [x] 13. Update host definitions to remove inline users, use registry + system-access-groups

### Phase 3: Fleet Alignment ✅

- [x] 14. Align fleet.nix with sini (host-to-users excludes, intoAttr guard, access groups)
- [x] 15. Updated den input to latest revision on feat/entity-gen-schema-port
- [x] 16. Fixed agenix battery reference to old secrets-collector path

### Verification Results

- `nix flake check --no-build`: **PASSES** (no infinite recursion)
- `nix eval .#nixosConfigurations --apply 'x: builtins.attrNames x'`: **`["builder" "hvn-hyp1"]`** ✅
- Fleet pipeline: **WORKING** — flake → fleet → environment → host instantiation chain functional
- User registry: **WORKING** — ACL-based resolution via fleet.user-access + system-access-groups
- Dynamic settings: **WORKING** — buildSettingsModule auto-discovers from aspect tree

### Remaining Issue (pre-existing, not caused by this work)

- **disko.devices incompatibility**: `disko-zfs` module uses `disko.zfs` API, not `disko.devices`.
  Sini uses standard `inputs.disko`. Need to switch from disko-zfs to
  standard disko (or update pool.nix to use disko-zfs API). This blocks full `nix flake check`
  with build.

## Additional Fixes (same session)

- **disko-zfs + disko.devices**: Added `den.aspects.disk` as includes dependency of `disk.zfs` so
  standard disko is imported alongside disko-zfs. disko-zfs auto-detects standard disko per its docs.
- **scope-engine acl.nix**: `engine.eval` API changed from `baseNodes` to `roots` parameter.
- **Dynamic settings**: Added `.settings` declarations to `core.nix` (gc.enable), `core.remote-unlock`
  (sshUsers). Fixed mergerfs `settings.options.pools` → `settings.pools`.
- **networking.default**: Added back to `den.schema.host.includes` (needed for nftables, Incus requires it).
- **core aspects in defaults**: Added `core.nix`, `stateVersion`, `time`, `sudo`, `shell`, `home-manager`,
  `root-user` to `den.schema.host.includes` — fundamental aspects every host needs.

### Final Verification

- `nix flake check --no-build` — **PASSES CLEAN** ✅
- `nixosConfigurations` — `["builder", "hvn-hyp1"]` ✅
- No infinite recursion, no missing options, no structural errors

## Files Changed

### New Files
- `aspirational-work/00-alignment-with-sini.md`
- `modules/den/aspects/core/base.nix`
- `modules/den/aspects/core/network/firewall-collector.nix`
- `modules/den/aspects/core/secrets/collector.nix`
- `modules/den/aspects/core/security/sudo.nix`
- `modules/den/aspects/core/localization/time.nix`
- `modules/den/aspects/core/nix/nix.nix`
- `modules/den/aspects/core/nix/stateVersion.nix`
- `modules/den/aspects/core/users/resolved-user-emitter.nix`
- `modules/den/aspects/core/users/users.nix`
- `modules/den/aspects/core/users/shell.nix`
- `modules/den/aspects/core/users/home-manager.nix`
- `modules/den/aspects/core/users/root-user.nix`
- `modules/den/policies/pipes.nix`
- `modules/den/policies/groups.nix`
- `modules/den/policies/access.nix`
- `modules/den/schema/group.nix`
- `modules/den/users/daniel.nix`
- `modules/den/groups/default.nix`

### Modified Files
- `modules/flake/den.nix` — simplified to minimal
- `modules/den/defaults.nix` — rewritten to match sini's batteries
- `modules/den/schema/host.nix` — dynamic buildSettingsModule, identity markers
- `modules/den/schema/topology.nix` — cleaned up
- `modules/den/policies/fleet.nix` — aligned with sini (excludes, guards)
- `modules/den/hosts/hvn-hyp1/default.nix` — removed inline users, added system-access-groups
- `modules/den/hosts/builder/default.nix` — removed inline users, added system-access-groups
- `modules/den/hosts/daniels-2021-mbp/default.nix` — cleaned up
- `modules/den/batteries/agenix.nix` — removed old secrets-collector reference
- `modules/meta/inputs.nix` — added gen-algebra input

### Removed Files
- `modules/den/aspects/core/firewall-collector.nix` (moved to core/network/)
- `modules/den/aspects/core/secrets-collector.nix` (moved to core/secrets/)
- `modules/den/aspects/core/sudo.nix` (moved to core/security/)
- `modules/den/aspects/core/time.nix` (moved to core/localization/)
- `modules/den/aspects/core/nix.nix` (moved to core/nix/)

## Reference Mapping

| homelab-den (before) | sini (target) | Status |
|---|---|---|
| `modules/flake/den.nix` (with __findFile hack) | `modules/den/flake-parts.nix` (minimal) | ✅ Aligned |
| `modules/den/defaults.nix` (inputs.self recursion) | `modules/den/defaults.nix` (sini batteries) | ✅ Aligned |
| `schema/host.nix` static settings | `schema/host.nix` buildSettingsModule | ✅ Aligned |
| `policies/fleet.nix` (missing guards) | `policies/fleet.nix` (excludes + intoAttr) | ✅ Aligned |
| (missing) | `policies/pipes.nix` | ✅ Created |
| (missing) | `schema/group.nix` | ✅ Created |
| inline users on hosts | `users/daniel.nix` registry | ✅ Migrated |
| `aspects/core/firewall-collector.nix` | `aspects/core/network/firewall-collector.nix` | ✅ Reorganized |
| `aspects/core/secrets-collector.nix` | `aspects/core/secrets/collector.nix` | ✅ Reorganized |
| `aspects/core/sudo.nix` | `aspects/core/security/sudo.nix` | ✅ Reorganized |
| `aspects/core/time.nix` | `aspects/core/localization/time.nix` | ✅ Reorganized |
| `aspects/core/nix.nix` | `aspects/core/nix/nix.nix` | ✅ Reorganized |
| den@4200f372 | den@b2bcfd42+ | ✅ Updated |
| disko-zfs (alone) | standard disko | ✅ Fixed (both imported) |
| scope-engine baseNodes | scope-engine roots | ✅ Fixed |
| static host.settings | dynamic buildSettingsModule | ✅ Fixed (settings declared on aspects) |
