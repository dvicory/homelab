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
| 3: Quirks | deferred | 2026-05-25 | Fork-gated. Kept persist.directories NixOS option |
| 4: Rename & Reorganize | completed | 2026-05-25 | modules/den/ namespace, slash notation for hasAspect |
| 5: Group-Based Users | skipped | 2026-05-25 | Optional; 2-host/1-user setup doesn't need it |
| 6: Fork-Gated | blocked | | Requires sini/den fork |

## Current File Layout (post-Phase 4)

```
modules/
├── den/
│   ├── defaults.nix               — den.default + schema includes + user companions
│   ├── aspects/
│   │   ├── core/
│   │   │   ├── nix.nix             — den.aspects."core/nix"
│   │   │   ├── time.nix            — den.aspects."core/time"
│   │   │   ├── facter.nix          — den.aspects."core/facter"
│   │   │   ├── remote-unlock.nix   — den.aspects."core/remote-unlock" (per-user sshUsers setting)
│   │   │   └── sudo.nix            — flake module (not yet converted to aspect)
│   │   ├── disk/
│   │   │   ├── zfs.nix             — den.aspects."disk/zfs"
│   │   │   └── impermanence.nix    — den.aspects."disk/impermanence"
│   │   ├── hardware/
│   │   │   └── hypervisor.nix      — den.aspects."hardware/hypervisor"
│   │   ├── networking/
│   │   │   └── default.nix         — den.aspects."networking/default"
│   │   ├── roles/
│   │   │   └── server.nix          — den.aspects."roles/server"
│   │   ├── secrets/
│   │   │   ├── sops.nix            — den.aspects."secrets/sops"
│   │   │   └── hardcoded.nix       — den.aspects."secrets/hardcoded"
│   │   └── services/
│   │       ├── crowdsec.nix        — den.aspects."services/crowdsec"
│   │       └── mergerfs.nix        — den.aspects."services/mergerfs"
│   ├── hosts/
│   │   ├── builder/                — entity+aspect, secrets.yaml, ssh.pub, facter.json, keys
│   │   ├── hvn-hyp1/               — entity+aspect, secrets.yaml, ssh.pub, facter.json, keys
│   │   └── daniels-2021-mbp/       — entity+aspect (darwin, no secrets)
│   └── schema/
│       ├── host.nix                — zfs, networking, settings submodule
│       └── user.nix                — sshKeys, extraGroups, packages
├── flake/
│   ├── den.nix                     — output bridge (was: nix/den.nix)
│   ├── deploy-rs.nix
│   ├── formatter.nix
│   └── sops.nix
├── meta/
│   ├── flake-parts.nix             — import-tree [ ./modules ]
│   ├── inputs.nix
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

### Phase 0
- **Mergerfs**: Flake modules imported via `imports` don't work for den hosts — `nix/den.nix` only passes `host.mainModule` to `nixosSystem`. Converted to native `den.aspects."services/mergerfs"` with `settings.options.pools` for typed entity data.
- **SSH host keys**: `hostKeys = lib.mkForce []` was in `den.default.nixos` (applied to all hosts). Moved to impermanence aspect so non-impermanent hosts get normal SSH key generation.

### Phase 1
- **Schema**: `den.schema.host.users` already declared by den core (`host.nix:47`). User fields go on `den.schema.user` (`sshKeys`, `extraGroups`, `packages`).
- **Entity vs NixOS context**: Bare functions in `den.schema.host.includes` do NOT contribute nixos bodies on `denful/den` main. Working approach: `den.default.includes` lambdas with `{ host, user }` args (same pattern as `den.batteries.define-user`).
- **SOPS paths**: Must hardcode `/run/secrets-for-users/users/<name>/hashedPassword` (entity context can't access NixOS `config.sops.secrets`).
- **Conditional secrets**: `builtins.pathExists (inputs.self + "/modules/den/hosts/${host.name}/secrets.yaml")` gates `secretRequests` and `hashedPasswordFile` per host.

### Phase 2
- **Settings submodule**: `den.schema.host.options.settings` with `freeformType` allows both typed options and aspect-level settings (like `services.mergerfs.pools`).
- **hasAspect**: Replaces `host.zfs.rootPool != null` checks with `host.hasAspect den.aspects."disk/zfs"`.

### Phase 3
- **Quirk pipes**: `den.quirks` registers but quirk pipe collection doesn't flow on `denful/den` main. Requires the `sini/den` fork.
- **`den.batteries.forward`**: Doesn't register custom classes on mainline den. Also requires fork.
- **Working approach**: Keep `persist.directories` NixOS option. Aspects emit `persist.directories = [...]`, impermanence reads `config.persist.directories`.

### Phase 4
- **Slash notation required**: `den.aspects."disk/zfs"` not `den.aspects.disk.zfs`. Dot notation creates nested attrsets; `lazyAttrsOf` processes nested keys as content wrappers without `name`/`meta`, breaking `hasAspect`. Slash notation creates flat keys that get full aspect identity.
- **Upstream den**: Templates and CI tests use dot notation for single-word names, slash for multi-word. Sini fork adds automatic nesting resolution.
- **Host data paths**: Updated from `modules/hosts/<name>/` to `modules/den/hosts/<name>/`. SOPS path `../../hosts/<name>/secrets.yaml` still resolves correctly (source and target both moved deeper by same amount).

### Remote-unlock
- Uses `host.settings.core.remote-unlock.sshUsers` (array of usernames, defaults to `[ "daniel" ]`) to select which users' SSH keys to include in the initrd authorized_keys file.
- Setting is declareable via the `settings` submodule's `freeformType` — no explicit option declaration needed.

## Active Commits on Branch

```
4ec812a fix: remote-unlock iterates all host users, not hardcoded daniel
1ead9b2 docs: add Phase 4 addendum — dot vs slash notation for hasAspect
4b6b3f5 fix: use slash notation for aspect names + update host paths
432b663 refactor: reorganize modules/ into den/ namespace (Phase 4)
33aee9a docs: add Phase 3 addendum — quirks/forward need den fork
510ae9e refactor: keep persist.directories NixOS option, add incus ownership
9b86718 fix: Phase 0 regressions
95a1a1e fix(mergerfs): convert to den-native aspect
678f9d8 fix: mergerfs den-native conversion + testvm host keys
```

## Adversarial Review Items

All items addressed. See commit `7b0b0a6`.

## Fork-Gated Work: What Unlocks With `sini/den`

The den fork `github:sini/den/feat/entity-gen-schema-port` is a foundational rewrite of
aspect/entity resolution, key classification, and pipe assembly. Switching enables:

### How to switch

```
# In flake.nix (or modules/meta/inputs.nix), change:
#   den.url = "github:denful/den";
# To:
#   den.url = "github:sini/den/feat/entity-gen-schema-port";
# Then:
nix flake lock --update-input den
nix run .#write-flake --impure
```

### Unlocked work per phase

| Phase | Item | What Changes |
|-------|------|-------------|
| 4 | Dot notation | `den.aspects.disk.zfs` works for hasAspect. Global sed to replace all `den.aspects."core/nix"` → `den.aspects.core.nix`. Remove the slash-notation workaround. |
| 3 | Quirk pipes | `den.quirks.persist` → collectors receive `persist` param. Aspects emit `persist = [...]` instead of `persist.directories = [...]`. Remove `persist.directories` NixOS option. Add firewall collector. See v7 Phase 3 code. |
| 3 | `den.batteries.forward` | Custom classes register correctly. Create `persistForward`/`cacheForward` classes with `options ? environment.persistence` guard. Alternative to quirk pipes. |
| 6 | Dynamic settingsType | Auto-discovers aspect `.settings` declarations. Replace manual `options.settings` block. See v7 6.1. |
| 6 | Environment entities | `den.environments.home`, `den.environments.vms`. Cascading defaults. |
| 6 | Settings cascade | `aspect → environment → host → user` precedence. See v7 6.2-6.3. |

### Phase 5 (Optional, no fork required)

Group-based user model. Requires user registry, group entities, resolution policy.
Only needed when per-host user duplication becomes unwieldy (3+ users across 4+ hosts).
Not yet implemented — skipped as optional. sini reference files mapped in v7 Phase 5.

### Files already staged for fork switch

The v6 Phase 3 code (quirk declarations, collectors, aspect updates) exists in the
migration doc but was NOT committed — the quirk/collector files were created and then
removed when testing showed they didn't work. An agent should follow v7's Phase 3
spec to create them fresh after the fork switch.
