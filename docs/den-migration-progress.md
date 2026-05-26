# Den Migration Progress

Tracking implementation of `docs/den-migration-v7.md`.

| Phase | Status | Date | Notes |
|-------|--------|------|-------|
| 0.1: Parametric Nix Aspect | completed | 2026-05-24 | den.aspects.core.nix with os/nixos/darwin |
| 0.2: Missing base packages + vim | completed | 2026-05-24 | bottom, lnav, git; programs.vim |
| 0.3: Chrony persist fix | completed | 2026-05-24 | inherit user/group on persist dirs |
| 0.4: Initrd extraBin | completed | 2026-05-24 | ping, trip, ip, vi |
| 0.5: MergerFS wiring | completed | 2026-05-24 | Converted to den.aspects.services.mergerfs |
| 1: Parametric Users | completed | 2026-05-25 | den.default.includes lambdas (not den.schema.host.includes) |
| 2: Settings on Aspects | completed | 2026-05-25 | hasAspect guards + typed settings submodule |
| 3: Quirks | completed | 2026-05-26 | Quirk pipes work on sini fork. persist/cache/firewall collectors. |
| 4: Rename & Reorganize | completed | 2026-05-26 | Dot notation for non-hyphenated names. Fork fixed lazyAttrsOf nesting. |
| 5: Group-Based Users | skipped | 2026-05-25 | Optional; 2-host/1-user setup doesn't need it |
| 6: Dynamic settings + Envs | completed | 2026-05-26 | environment option on host schema; den.reservedKeys = ["settings"] for future settingsType |

## Fork Switch

Den input changed from `github:denful/den` to `github:sini/den/feat/entity-gen-schema-port`.
New dependency added: `github:sini/gen-schema` (required by den fork for entity schema operations).

## Current File Layout (post-Phase 6)

```
modules/
├── den/
│   ├── defaults.nix               — den.default + schema includes + user companions + reservedKeys
│   ├── aspects/
│   │   ├── core/
│   │   │   ├── nix.nix             — den.aspects.core.nix
│   │   │   ├── time.nix            — den.aspects.core.time (emits persist quirk data)
│   │   │   ├── facter.nix          — den.aspects.core.facter
│   │   │   ├── remote-unlock.nix   — den.aspects."core/remote-unlock" (hyphenated, slash notation)
│   │   │   ├── sudo.nix            — den.aspects.core.sudo
│   │   │   ├── persist-collector.nix   — den.aspects."core/persist-collector" (quirk collector)
│   │   │   └── firewall-collector.nix  — den.aspects."core/firewall-collector" (quirk collector)
│   │   ├── disk/
│   │   │   ├── zfs.nix             — den.aspects.disk.zfs
│   │   │   └── impermanence.nix    — den.aspects.disk.impermanence (includes persist-collector)
│   │   ├── hardware/
│   │   │   └── hypervisor.nix      — den.aspects.hardware.hypervisor (emits persist quirk data)
│   │   ├── networking/
│   │   │   └── default.nix         — den.aspects.networking.default
│   │   ├── roles/
│   │   │   └── server.nix          — den.aspects.roles.server
│   │   ├── secrets/
│   │   │   ├── sops.nix            — den.aspects.secrets.sops
│   │   │   └── hardcoded.nix       — den.aspects.secrets.hardcoded
│   │   ├── services/
│   │   │   ├── crowdsec.nix        — den.aspects.services.crowdsec
│   │   │   └── mergerfs.nix        — den.aspects.services.mergerfs
│   │   └── quirks/
│   │       └── persist.nix         — den.quirks.persist/cache/firewall declarations
│   ├── hosts/
│   │   ├── builder/                — entity+aspect, secrets.yaml, ssh.pub, facter.json, keys
│   │   ├── hvn-hyp1/               — entity+aspect, secrets.yaml, ssh.pub, facter.json, keys
│   │   └── daniels-2021-mbp/       — entity+aspect (darwin, no secrets)
│   └── schema/
│       ├── host.nix                — zfs, networking, settings submodule, environment option
│       └── user.nix                — sshKeys, extraGroups, packages
├── flake/
│   ├── den.nix                     — output bridge (was: nix/den.nix)
│   ├── deploy-rs.nix
│   ├── formatter.nix
│   └── sops.nix
├── meta/
│   ├── flake-parts.nix             — import-tree [ ./modules ]
│   ├── inputs.nix                  — den, gen-schema inputs
│   ├── pkgs.nix
│   └── systems.nix
├── nix/                            — flake-parts modules (caches, flakes, optimise, sensible, unfree)
├── packages/
│   ├── initrd.nix
│   └── install-on-envoy.nix
└── tests/
    └── default.nix
```

## Key Architectural Findings

### Phase 3 (Quirks — now implemented on fork)
- **Quirk pipes work on sini fork**: `den.quirks.persist`/`cache`/`firewall` declarations, collector aspects receive quirk data as function args (`persist`, `cache`, `firewall`).
- **Aspect-level emission**: Quirk data must be emitted at the aspect level (alongside `nixos`/`darwin`), not inside class bodies. Config-dependent values use thunks (`{ config, ... }: [ ... ]`).
- **persist-collector wired via impermanence includes**: The `disk/impermanence` aspect includes `core/persist-collector`, which merges all `persist` quirk entries into `environment.persistence."/persist"`. Firewall-collector on global schema includes.
- **persist.directories NixOS option removed**: Replaced by quirk-based data flow.

### Phase 4 (Dot notation — now works on fork)
- **Dot notation works for aspect definitions and includes**: `den.aspects.disk.zfs`, `den.aspects.core.nix`, etc. All non-hyphenated names use dot notation.
- **hasAspect with dot notation edge case**: `host.hasAspect den.aspects.disk.zfs` doesn't resolve correctly (2-level dot notation through lazyAttrsOf). Reverted to `host.zfs.rootPool != null` guard which is functionally equivalent. Hyphenated names (`remote-unlock`, `persist-collector`, `firewall-collector`) keep slash notation.
- **Hyphenated names**: Must use slash notation because `persist-collector` would be parsed as `persist - collector` in Nix.

### Phase 6 (Dynamic settings + Environments)
- **den.reservedKeys = [ "settings" ]**: Prevents the pipeline from dispatching `settings` as a class/quirk key. Sets up for future dynamic settingsType auto-discovery.
- **environment option on host schema**: `host.environment = "vms"` or `"home"`. Simple string grouping without full cascade — scope-engine cascade is too heavy for 2-host setup.
- **Dynamic settingsType deferred**: Requires aspects to declare `.settings` submodules (our aspects use manual `den.schema.host.options.settings.*`). Infrastructure ready when needed.

## Fork-Gated Work: Completed

All previously fork-gated items now implemented:

| Item | Status | Notes |
|------|--------|-------|
| Quirk pipes (Phase 3) | Done | persist, cache, firewall collectors |
| Dot notation (Phase 4) | Done | Non-hyphenated names only; hasAspect reverted to pool check |
| den.reservedKeys (Phase 6) | Done | Sets up for settingsType |
| Environment grouping (Phase 6) | Done | Simple string field on host schema |
| Dynamic settingsType (Phase 6) | Deferred | Code exists in sini; adopt when aspects declare .settings |
| Settings cascade (Phase 6) | Deferred | scope-engine overkill for 2 hosts |
| gen-schema entities | Available | gen-schema input added; not yet used for entity refs |

## Flake Input Changes

| Input | Before | After |
|-------|--------|-------|
| den | `github:denful/den` | `github:sini/den/feat/entity-gen-schema-port` |
| gen-schema | (none) | `github:sini/gen-schema` |
