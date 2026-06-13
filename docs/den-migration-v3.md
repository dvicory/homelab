# Den Migration v3: Audit, Roadmap & Concepts

Pre-den baseline: `eea36b4^` (before "Initial den migration")
v2 baseline: `docs/den-migration-v2.md` (superseded)

---

## Contents

- [What Changed from v2](#what-changed-from-v2)
- [Fork Dependency Map](#fork-dependency-map)
- [Phase 0: Fix Regressions](#phase-0-fix-regressions) — bugs, deploy now
- [Phase 1: User & Group Model](#phase-1-user--group-model) — parametric users, group registry, SSH keys, auto-include policy
- [Phase 2: Settings on Aspects](#phase-2-settings-on-aspects) — typed per-host configuration, `hasAspect`
- [Phase 3: Quirks](#phase-3-quirks) — cross-aspect data pipes with collectors
- [Phase 4: Rename & Reorganize](#phase-4-rename--reorganize) — file moves, short names, sini-aligned categories
- [Phase 5: Policies](#phase-5-policies) — group-based user resolution, fleet-demo policy patterns
- [Phase 6: Den-Native Refactors](#phase-6-den-native-refactors) — aspirational (environment entities, settings cascade)
- [Migration Reference](#migration-reference)
- [Cross-Example Findings](#cross-example-findings-9-den-users-surveyed)
- [Den Source & Examples Guide](#den-source--examples-guide)
- [Concept Deep-Dives](#concept-deep-dives)

---

## Legend

| Icon | Meaning |
|------|---------|
| 🔴 | Bug / regression (blocking) |
| 🟡 | Working but suboptimal |
| ✅ | Correctly migrated |
| ➕ | New capability post-den |
| 🐚 | Pattern from sini's config |
| 🛡 | Pattern from fleet-demo |
| ⚠️ | Requires sini/den fork — see [Fork Dependency Map](#fork-dependency-map) |

---

## What Changed from v2

**"profile" dropped entirely.** No den example, template, or battery uses the word "profile" as a category name, aspect name, or directory name. It's fossilized DSL terminology. v3 replaces all occurrences with sini-aligned functional categories.

**Sini deep-dive incorporated.** v3 integrates patterns from sini's `feat/entity-gen-schema-port` branch — the most mature real-world den config (8 hosts, 12 users, 216 aspects, 13 categories, 22 quirk pipes, 25 policies). Key adoptions: `resolved-user-emitter` quirk, `den.schema.user.includes` auto-include policy, collector aspects wired via `den.schema.host.includes`, and `os` class shorthand.

**Fork dependency tracking.** Every feature is annotated with whether it requires sini's den fork (`github:sini/den/feat/entity-gen-schema-port`) or works with mainline `github:denful/den`. The fork adds gen-schema, scope-engine, and `reservedKeys`. The homelab avoids all fork dependencies — every actionable phase uses core den features only.

**Category re-alignment.** v2 mapped disks to `hardware/`. v3 follows sini: disks/filsystems go in `disk/`, hardware enablement (hypervisor) stays in `hardware/`. This is consistent with sini's 13-category taxonomy.

**Phase 6 no longer aspirational.** Phase 6 becomes the convergence path: environments, settings cascade, and dynamic settingsType. These are explicitly marked as fork-dependent and gated on `github:sini/den/feat/entity-gen-schema-port` merging into mainline.

**Recap: naming prefix eliminated.** v2 already eliminated the `dlab/` prefix from aspect names. v3 confirms: zero examples use a provider namespace prefix on aspect names. Aspect names are functional (`core.time`, `disk.zfs`), not provider-scoped (`dlab/profile/time`).

---

## Fork Dependency Map

The homelab uses `github:denful/den` (mainline). sini uses `github:sini/den/feat/entity-gen-schema-port` (fork). Features are annotated per-phase with their fork requirements.

| Feature | Dependency | Status in homelab |
|---|---|---|
| Quirks (`pipe.*`, `den.quirks.*`, collectors) | ✅ Core den | Used in Phase 3 |
| `den.schema.*.includes` / `excludes` | ✅ Core den | Used in Phases 1, 3, 5 |
| `den.lib.policy.mkPolicy`, `.include`, `.provide`, `.resolve.to` | ✅ Core den | Used in Phases 1, 5 |
| `host.hasAspect` | ✅ Core den | Used in Phase 2 |
| `os` class shorthand | ✅ Core den | Used in Phase 2 |
| Manual settings on `den.schema.host` (function pattern) | ✅ Core den | Used in Phase 2 |
| `den.reservedKeys` | ❌ Fork only | Not needed — skip declaring `den.quirks.settings` to avoid collision |
| Dynamic `settingsType` auto-discovery | ❌ Fork only | Skip — declare settings manually (Phase 6 upgrade path) |
| `scope-engine` settings cascade | ❌ Fork only | Skip — flat host-only settings sufficient (Phase 6 upgrade path) |
| `scope-engine` ACL | ❌ Fork only | Not needed |
| `gen-schema` methods/refs | ❌ Fork only | Blocks environment entities — Phase 6 gated |
| `gen.mkValidator` | ❌ Fork only | Skip — nice-to-have, not essential |
| `den.lib.policy.instantiate` | ❌ Fork only | Homelab uses manual `nix/den.nix` output bridge instead |

**Bottom line:** Every actionable phase (0-5) uses core den features only. Phase 6 is aspirational and gated on the fork merging.

---

## Phase 0: Fix Regressions

These are bugs. Fix and deploy immediately. (Unchanged from v2.)

### 0.1 Nix GC unconfigured

**File:** `modules/aspects/nix/default.nix:40-43`

```nix
# gc = {
#   automatic = lib.mkDefault true;
#   options = lib.mkDefault "--delete-older-than 14d";
# };
```

Uncomment. Without this the store grows unboundedly.

---

### 0.2 Missing base packages + vim

**File:** `modules/aspects/default.nix`

Old `profiles/base.nix` had:

```nix
environment.systemPackages = with pkgs; [ bottom lnav git ];
programs.vim.enable = lib.mkDefault true;
```

None of these are configured in the new system.

---

### 0.3 Chrony persist directories missing `user`/`group`

**File:** `modules/aspects/profiles/time.nix:52-55`

```nix
persist.directories = [
  { directory = config.services.chrony.directory; }    # ← missing inherit user group;
  { directory = logDir; }                              # ← missing inherit user group;
];
```

Both `user` and `group` are already bound in the let block. Add `inherit user group;` to both.

---

### 0.4 Initrd `extraBin` missing for remote unlock

**File:** `modules/aspects/profiles/remote-unlock.nix`

Old had debugging tools in initrd:

```nix
boot.initrd.systemd.extraBin = {
  ping = "${pkgs.iputils}/bin/ping";
  trip  = "${pkgs.trippy}/bin/trip";
  ip    = "${pkgs.iproute2}/bin/ip";
  vi    = "${pkgs.vim}/bin/vi";
};
```

Add these back.

---

### 0.5 MergerFS not wired for hvn-hyp1

**File:** `modules/aspects/hosts/hvn-hyp1/default.nix`

Old config had:

```nix
dlab.storage.mergerfs."/mnt/storage/media" = {
  branches = [
    "/mnt/storage-clear/media1"
    "/mnt/storage-clear/media3"
  ];
};
```

The mergerfs module still exists at `modules/storage/mergerfs.nix`. The hvn-hyp1 aspect never references it. Add the config block.

---

## Phase 1: User & Group Model

**v3 changes from v2**: Added `den.schema.user.includes` with auto-include policy (sini pattern), `resolved-user-emitter` quirk (sini pattern), `os` class shorthand. Fork status: all core den.

### 1.1 Why This Matters

The hardcoded `users.users.daniel` in `den.default.nixos` is the single biggest structural gap. In den, users are entities — they should be declared independently and resolved onto hosts by policy.

This phase introduces:

1. **Per-user aspect files** with batteries and NixOS config
2. **Group entities** that carry access semantics
3. **User registry** with group-based ACL resolution
4. **`resolved-user-emitter` quirk** — emits metadata per user for host-level collectors
5. **Auto-include policy** — `den.aspects.<host>.<user>` sub-aspects auto-included
6. **Named SSH keys battery** — replaces inline lambda in `default.includes`
7. **`primary-user` battery** — replaces `extraGroups = [ "wheel" ]`

### 1.2 Target: Users

| User | Groups | Access |
|------|--------|--------|
| `daniel` | `admins`, `system-access` | Every host |
| `alice` | `developers`, `vm-access` | VMs only |
| `bob` | `services`, `vm-access` | Specific service VMs |

### 1.3 Group Entities

**New file:** `modules/aspects/groups/default.nix`

```nix
{ den, ... }: {
  den.groups = {
    admins.description = "Full administrative access to all systems";
    system-access.description = "Unix account on bare-metal hosts";
    vm-access.description = "Unix account on VMs";
    developers.description = "Development environment access";
    services.description = "Service-specific VM access";
  };
}
```

### 1.4 Extend Host Schema for Group Access

**File:** `modules/schema/host.nix` — add `system-access-groups`:

```nix
den.schema.host = { host, lib, ... }: {
  options.zfs = { /* ... existing ... */ };
  options.networking = { /* ... existing ... */ };

  options.system-access-groups = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ "system-access" ];
    description = "Groups granted Unix account access on this host";
  };
};
```

### 1.5 Extend User Schema

**File:** `modules/schema/user.nix` — add `identity` and `system` submodules:

```nix
{ lib, ... }: {
  den.schema.user = { user, ... }: {
    imports = [
      (_: {
        options = {
          identity = lib.mkOption {
            type = lib.types.submodule {
              options = {
                displayName = lib.mkOption { type = lib.types.str; default = ""; };
                email = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
                sshKeys = lib.mkOption {
                  type = lib.types.listOf (lib.types.submodule {
                    options = {
                      tag = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
                      key = lib.mkOption { type = lib.types.str; };
                    };
                  });
                  default = [ ];
                };
              };
            };
            default = { };
          };
          system = lib.mkOption {
            type = lib.types.submodule {
              options = {
                uid = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
              };
            };
            default = { };
          };
        };
      })
    ];
  };
}
```

Note: The `imports` pattern within schema is core den. It's the standard NixOS `imports` mechanism applied to entity schema submodules — not the gen-schema `den.schema.host.imports` pattern.

### 1.6 User Registry

**New file:** `modules/aspects/users/registry.nix`

```nix
{ lib, den, ... }:
let inherit (lib) mkOption types;

  registryUserType = types.submodule (
    { name, config, ... }: {
      imports = [ den.schema.user ];
      config._module.args.user = config;
      options = {
        name = mkOption { type = types.str; default = name; };
        userName = mkOption { type = types.str; default = name; };
        groups = mkOption { type = types.listOf types.str; default = [ ]; };
        primaryUser = mkOption { type = types.bool; default = false; };
      };
    }
  );
in {
  options.den.users.registry = mkOption {
    type = types.attrsOf registryUserType;
    default = { };
  };

  config.den.schema.user.isEntity = true;  # ✅ core den
}
```

### 1.7 Per-User Aspect Files

**New file:** `modules/aspects/users/daniel.nix`

```nix
{ den, lib, config, ... }: {
  den.users.registry.daniel = {
    groups = [ "admins" ];
    primaryUser = true;
    identity = {
      displayName = "Daniel Vicory";
      email = "daniel@vicory.com";
      sshKeys = [
        { tag = "laptop"; key = "ssh-ed25519 AAAAC3..."; }
      ];
    };
  };

  den.aspects.daniel = {
    includes = [
      den.batteries.primary-user
      (den.batteries.user-shell "zsh")
      den.aspects.features.ssh-keys
      den.aspects.daniel.policies.to-hosts
    ];

    nixos = { pkgs, ... }: {
      users.users.daniel.packages = with pkgs; [ git bottom lnav vim ];
    };

    policies.to-hosts = { host, user, ... }:     # ✅ core den
      lib.optional (host ? users.${user.userName}) (
        den.lib.policy.provide {                  # ✅ core den
          class = "nixos";
          module = {
            users.users.${user.userName} = {
              hashedPasswordFile = config.sops.secrets."${user.userName}/hashedPassword".path;
              isNormalUser = true;
            };
          };
        }
      );
  };
}
```

### 1.8 Resolved User Emitter Quirk (sini pattern) 🐚

**New file:** `modules/aspects/core/resolved-user-emitter.nix`

```nix
# Emits resolved-user metadata at user scope.
# Collected at host scope so host-level aspects (persistHome, firewall)
# can enumerate all users on a given host.
_: {
  den.aspects.core.resolved-user-emitter = {
    resolved-users = { user, ... }: {             # ✅ core den (quirk pipe)
      name = user.name;
      uid = user.system.uid or null;
      groups = user.groups or [ ];
      sshKeys = map (k: k.key) (user.identity.sshKeys or [ ]);
    };
  };
}
```

### 1.9 Auto-Include Policy (sini pattern) 🐚

**File:** `modules/aspects/default.nix` — add to `den.schema.user.includes`:

```nix
den.schema.user.includes = [                        # ✅ core den
  den.aspects.core.resolved-user-emitter

  # Auto-include den.aspects.<host>.<user> if it exists
  (den.lib.policy.mkPolicy "user-aspect-auto-include"   # ✅ core den
    ({ host, user, ... }:
      lib.optional
        (den.aspects ? ${host.name} && den.aspects.${host.name} ? ${user.name})
        (den.lib.policy.include den.aspects.${host.name}.${user.name})  # ✅ core den
    )
  )
];
```

This is the mechanism that makes per-host per-user customization work. Without it, `den.aspects.builder.daniel` would exist in the aspect tree but never be included in builder's scope. With it, den auto-discovers and includes it.

### 1.10 Named SSH Keys Battery (fleet-demo pattern) 🛡

**New file:** `modules/aspects/features/ssh-keys.nix`

```nix
{ lib, ... }: {
  den.aspects.features.ssh-keys = { host, user, ... }: {
    os = lib.mkIf (user ? identity.sshKeys && user.identity.sshKeys != []) {  # ✅ core den (os class)
      users.users.${user.userName}.openssh.authorizedKeys.keys =
        map (entry: entry.key) user.identity.sshKeys;
    };
  };
}
```

Note the `os` class: applies to both NixOS and Darwin in a single declaration. Core den feature.

### 1.11 Update `den.default.includes`

**File:** `modules/aspects/default.nix`

```nix
den.default.includes = [
  den.batteries.hostname
  den.batteries.define-user
  den.aspects.features.ssh-keys       # was anonymous closure
];
# den.batteries.mutual-provider removed — inert compat shim
```

### 1.12 Remove Hardcoded User from `den.default.nixos`

**File:** `modules/aspects/default.nix` — delete:

- `users.users.daniel` block
- `secretRequests."users/daniel/hashedPassword"` entry
- `extraGroups = [ "wheel" ]` (now handled by `primary-user` battery)

### 1.13 Update Host Entities

```nix
den.hosts.x86_64-linux.hvn-hyp1 = {
  system-access-groups = [ "admins" "system-access" ];
  users.daniel = { };
  # ...
};

den.hosts.x86_64-linux.testvm = {
  system-access-groups = [ "admins" "vm-access" "developers" "services" ];
  users.daniel = { };
  users.alice = { };
  # ...
};
```

---

## Phase 2: Settings on Aspects

**v3 changes from v2**: `os` class shorthand, manual settings (not dyn-settingsType), clarified fork dependency (manual approach is core den, dynamicType is fork). Settings declared via the same function pattern used today for `zfs.rootPool`.

### 2.1 Why Settings

Currently, aspects infer behavior from raw entity data. Example from `disks.nix`:

```nix
# Current: checks entity data directly
nixos = lib.mkIf (host.zfs.rootPool != null) { ... };
```

With settings, the aspect declares what it can configure, and hosts set values:

```nix
# host entity
den.hosts.x86_64-linux.testvm.settings.disk.backend = "ext4";

# aspect reads
host.settings.disk.backend
```

This means: adding a host with different disk requirements never requires editing the aspect.

### 2.2 Manual Settings: Core Den Approach

Because dynamic `settingsType` auto-discovery requires the fork, declare settings manually on `den.schema.host` using the same function pattern used today for `zfs.rootPool`:

**File:** `modules/schema/host.nix` — add:

```nix
den.schema.host = { host, lib, ... }: {
  options.zfs = { /* ... existing ... */ };
  options.networking = { /* ... existing ... */ };
  options.system-access-groups = { /* ... from Phase 1 ... */ };

  # Manual settings — one entry per aspect
  options.settings = lib.mkOption {
    type = lib.types.submodule {
      options = {
        disk.backend = lib.mkOption {
          type = lib.types.enum [ "zfs" "ext4" ];
          default = "zfs";
          description = "Disk layout backend";
        };
        disk.encryption.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        disk.swap.size = lib.mkOption {
          type = lib.types.str;
          default = "8G";
        };
        networking.firewall.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        networking.dns.overTls = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        hypervisor.incus.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        hypervisor.incus.webUiPort = lib.mkOption {
          type = lib.types.int;
          default = 8443;
        };
        time.chrony.servers = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "time.cloudflare.com" "time.google.com" ];
        };
        time.chrony.enableNts = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        core.impermanence.rollback.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        core.remote-unlock.tailscale.authKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
      };
    };
    default = { };
  };
};
```

### 2.3 Settings Target: Every Aspect

| Aspect | Settings path |
|--------|--------------|
| `disks.nix` | `settings.disk.*` |
| `networking.nix` | `settings.networking.*` |
| `hypervisor.nix` | `settings.hypervisor.*` |
| `time.nix` | `settings.time.*` |
| `impermanence.nix` | `settings.core.impermanence.*` |
| `remote-unlock.nix` | `settings.core.remote-unlock.*` |

### 2.4 hasAspect: Conditional NixOS Config

**Before (current, indirect):**

```nix
# modules/aspects/profiles/impermanence.nix
nixos = lib.mkIf (host.zfs.rootPool != null) { ... };
```

**After (den-native, structural):**

```nix
# modules/den/aspects/core/impermanence.nix
den.aspects.core.impermanence = { host, ... }: {
  nixos = { lib, ... }:
    lib.mkIf (host.hasAspect den.aspects.disk.zfs) {  # ✅ core den
      # ZFS rollback service, persist mounts
    };
};
```

Why `host.hasAspect` is better:
- `host.zfs.rootPool != null` is an implementation detail — breaks if the disk aspect changes
- `host.hasAspect den.aspects.disk.zfs` is structural — asks "does the ZFS disk aspect exist on this host?"
- Works across indirection (roles, composite aspects)
- Cycle-safe inside class bodies (NixOS, Darwin, HomeManager)

**Constraint:** Never use `hasAspect` in `includes`. Use `meta.handleWith` + fx constraints for structural tree decisions.

**Reference:** `~/src/den/templates/example/modules/aspects/hasAspect-examples.nix` (141 lines)

### 2.5 `os` Class Shorthand

sini's `core/nix.nix:4` uses `os = { nix = { ... }; }` for config that applies to both NixOS and Darwin:

```nix
den.aspects.core.nix = {
  os.nix.settings.experimental-features = [ "flakes" "nix-command" ];  # ✅ core den
  nixos.nix.gc.dates = "05:00";
  darwin.nix.gc.interval = { Hour = 5; Minute = 0; };
};
```

Adopt this in `ssh-keys.nix`, `nix.nix`, and any aspect that needs both-platform config.

### 2.6 Consolidate SSH Enable

**File:** `modules/aspects/profiles/networking.nix` — remove:

```nix
services.openssh.enable = lib.mkDefault true;  # ← DELETE (already in default.nix)
```

---

## Phase 3: Quirks

**v3 changes from v2**: Added `resolved-user-emitter` collector wiring, `firewall-collector` for nftables, `persistHome` for user-scoped persistence, clarified that `den.reservedKeys` is fork-only (skip it, workaround: don't declare `den.quirks.settings`). Fork status: all quirk pipes and collectors are core den.

### 3.1 Why Quirks

Den quirks are a publish/subscribe pipe system. Aspects **emit** into a named pipe. A **collector** aspect subscribes and merges into actual configuration.

The current `persist.directories` NixOS option is a reimplementation of this concept. Replacing it with quirks:
- Gives typed validation per pipe entry
- Makes which aspects contribute to persistence discoverable
- Decouples emitters from the collector

### 3.2 Declare Quirk Types

**New file:** `modules/aspects/quirks/persist.nix`

```nix
{ lib, ... }: {
  den.quirks.persist = {                              # ✅ core den
    description = "Persistent directories/files from aspects (host-scoped)";
    type = lib.types.listOf (lib.types.submodule {
      options = {
        directory = lib.mkOption { type = lib.types.str; };
        user = lib.mkOption { type = lib.types.str; default = "root"; };
        group = lib.mkOption { type = lib.types.str; default = "root"; };
        mode = lib.mkOption { type = lib.types.str; default = "0755"; };
      };
    });
    default = [ ];
  };

  den.quirks.persistHome = {                          # ✅ core den
    description = "Persistent directories/files from aspects (user-scoped)";
    type = lib.types.listOf (lib.types.submodule {
      options = {
        directory = lib.mkOption { type = lib.types.str; };
        user = lib.mkOption { type = lib.types.str; };
        group = lib.mkOption { type = lib.types.str; };
        mode = lib.mkOption { type = lib.types.str; default = "0755"; };
      };
    });
    default = [ ];
  };

  den.quirks.cache = {                                # ✅ core den
    description = "Cache directories (host-scoped, separate from persist for wipe semantics)";
    type = lib.types.listOf (lib.types.submodule {
      options = {
        directory = lib.mkOption { type = lib.types.str; };
        user = lib.mkOption { type = lib.types.str; default = "root"; };
        group = lib.mkOption { type = lib.types.str; default = "root"; };
        mode = lib.mkOption { type = lib.types.str; default = "0755"; };
      };
    });
    default = [ ];
  };

  den.quirks.firewall = {                             # ✅ core den
    description = "Firewall rules collected from aspects";
    type = lib.types.listOf lib.types.raw;
    default = [ ];
  };

  den.quirks.resolved-users = {                       # ✅ core den
    description = "Resolved user metadata from user scope (used by host collectors)";
    type = lib.types.listOf (lib.types.submodule {
      options = {
        name = lib.mkOption { type = lib.types.str; };
        uid = lib.mkOption { type = lib.types.nullOr lib.types.int; };
        groups = lib.mkOption { type = lib.types.listOf lib.types.str; };
        sshKeys = lib.mkOption { type = lib.types.listOf lib.types.str; };
      };
    });
    default = [ ];
  };
}
```

### 3.3 Update Aspects to Emit into Quirks

**File:** `modules/aspects/profiles/hypervisor.nix`

```nix
# Before
persist.directories = [{ directory = "/var/lib/incus"; }];

# After
pipe.persist = [                                     # ✅ core den
  { directory = "/var/lib/incus"; user = "incus"; group = "incus"; }
];
```

**File:** `modules/aspects/profiles/time.nix`

```nix
# After
pipe.persist = [                                     # ✅ core den
  { directory = config.services.chrony.directory; user = chrony; group = chrony; }
  { directory = logDir; user = chrony; group = chrony; }
];
```

### 3.4 Collector Aspects

Collectors read aggregated pipe data and transform it into configuration. Wire them in `den.schema.host.includes` so they fire on every host — not per-host `includes`.

**New file:** `modules/aspects/core/persist-collector.nix`

```nix
_: {
  den.aspects.core.persist-collector = {
    nixos = { persist, cache, lib, ... }: let           # ✅ core den (pipe args)
      mergePersist = entries: {
        directories = lib.unique (lib.concatMap (e: e.directories or [ ]) entries);
        files = lib.unique (lib.concatMap (e: e.files or [ ]) entries);
      };
    in {
      environment.persistence."/persist" = mergePersist persist;
      environment.persistence."/cache" = mergePersist cache;
    };
  };
}
```

**New file:** `modules/aspects/core/firewall-collector.nix`

```nix
_: {
  den.aspects.core.firewall-collector = {
    nixos = { firewall, lib, ... }: lib.mkMerge firewall;  # ✅ core den
  };
}
```

### 3.5 Wire Collectors

**File:** `modules/aspects/default.nix` — add to `den.schema.host.includes`:

```nix
den.schema.host.includes = [                           # ✅ core den
  den.aspects.core.time
  den.aspects.networking.default
  den.aspects.core.persist-collector                   # NEW
  den.aspects.core.firewall-collector                  # NEW
];
```

Collectors belong in `schema.host.includes`, not in per-host `includes`. This ensures they fire on every host without manual enumeration.

### 3.6 Remove the NixOS Option

**File:** `modules/aspects/default.nix` — delete `options.persist.directories`.

### 3.7 Fork Consideration: `den.reservedKeys` ⚠️

sini's `defaults.nix:4` uses `den.reservedKeys = [ "settings" ]` to prevent `den.quirks.settings` from colliding with aspect `.settings` data. This doesn't exist in mainline den.

**Workaround:** Don't declare `den.quirks.settings`. Without it, `settings` is an unregistered key and won't be treated as a pipe. Aspect `.settings` attributes are just data and pass through untouched.

---

## Phase 4: Rename & Reorganize

**v3 changes from v2**: Aligned category names with sini's 13-category taxonomy. Disks moved from `hardware/` to `disk/`. Hypervisor stays in `hardware/`. All "profile" references eliminated. No fork dependencies.

### 4.1 Drop "profile" Entirely

Survey of every den example, template, and battery — zero use the word "profile" as a naming convention. It's a relic of the old DSL. Naming now follows sini's functional categories:

- `core/` — essential system config (time, nix, impermanence, facter, remote-unlock, resolved-users, collectors)
- `disk/` — filesystems and impermanence (zfs, ext4) — **new category, moved from hardware**
- `hardware/` — hardware enablement (hypervisor, GPU, CPU)
- `networking/` — networking (networkd, firewall, DNS)
- `services/` — daemons (crowdsec)
- `roles/` — composite profiles (server, vm)
- `secrets/` — secret providers (sops, hardcoded)
- `features/` — cross-cutting features (ssh-keys)
- `users/` — user entity files + registry
- `groups/` — group entity files
- `quirks/` — quirk declarations

### 4.2 Enable Short Names

**File:** `modules/namespace.nix` — change:

```nix
# Before
{ inputs, ... }: inputs.den.namespace "dlab" false

# After
{ inputs, ... }: inputs.den.namespace "dlab" true      # ✅ core den
```

This enables `den.aspects.core.time` instead of `den.aspects."dlab/profile/time"`.

### 4.3 Aspect Name Map

| Current (v1/v2) | Target (v3) | Category |
|---|---|---|
| `den.aspects."dlab/profile/time"` | `den.aspects.core.time` | core |
| `den.aspects."dlab/profile/networking"` | `den.aspects.networking.default` | networking |
| `den.aspects."dlab/profile/impermanence"` | `den.aspects.core.impermanence` | core |
| `den.aspects."dlab/profile/disks"` | `den.aspects.disk.zfs` | disk |
| — (new) | `den.aspects.disk.ext4` | disk |
| `den.aspects."dlab/profile/hypervisor"` | `den.aspects.hardware.hypervisor` | hardware |
| `den.aspects."dlab/profile/facter"` | `den.aspects.core.facter` | core |
| `den.aspects."dlab/profile/remote-unlock"` | `den.aspects.core.remote-unlock` | core |
| `den.aspects."dlab/profile/server"` | `den.aspects.roles.server` | roles |
| `den.aspects."dlab/services/crowdsec"` | `den.aspects.services.crowdsec` | services |
| `den.aspects."dlab/secrets/sops"` | `den.aspects.secrets.sops` | secrets |
| `den.aspects."dlab/secrets/hardcoded"` | `den.aspects.secrets.hardcoded` | secrets |
| `den.aspects.nix` (core) | `den.aspects.core.nix` | core |
| `modules/security/sudo.nix` | `den.aspects.core.sudo` | core |
| — (new) | `den.aspects.features.ssh-keys` | features |
| — (new) | `den.aspects.core.resolved-user-emitter` | core |
| — (new) | `den.aspects.core.persist-collector` | core |
| — (new) | `den.aspects.core.firewall-collector` | core |
| — (new) | `den.aspects.disk.zfs` (extracted from disks.nix) | disk |
| — (new) | `den.aspects.disk.ext4` (for VMs) | disk |
| — (new) | `den.aspects.roles.vm` (testvm composite) | roles |
| — (new) | `den.aspects.quirks.*` | quirks |
| — (new) | `den.aspects.users.daniel` | users |
| — (new) | `den.aspects.users.alice` | users |
| — (new) | `den.aspects.groups.default` | groups |

### 4.4 Split Disks into `disk.zfs` + `disk.ext4`

**Why:** sini splits `disk/zfs.nix`, `disk/btrfs.nix`, `disk/xfs.nix` — one aspect per filesystem backend. The current monolithic `disks.nix` gates everything on `host.zfs.rootPool != null`, forcing VMs to either get ZFS or nothing. Splitting lets testvm include `disk.ext4` without dragging in ZFS disko config.

```nix
# modules/den/aspects/disk/zfs.nix
den.aspects.disk.zfs = { host, ... }: {
  nixos = { lib, ... }: let
    pool = host.zfs.rootPool;
  in lib.mkIf (pool != null) {
    # disko ZFS config using pool.name, pool.disk1
  };
};

# modules/den/aspects/disk/ext4.nix
den.aspects.disk.ext4 = { host, ... }: {
  nixos = {
    # Simple ext4 root on /dev/vda for VMs
  };
};
```

### 4.5 Target Directory Structure

```
modules/
  den/                              ← ALL den-related config
    defaults.nix                     ← den.default + den.default.includes + den.default.nixos + den.schema.user.includes
    flake-parts.nix                  ← den integration + manual output bridge
    schema/
      host.nix                       ← zfs, networking, system-access-groups, settings
      user.nix                       ← identity, system, mainGroup, classes
      default.nix                    ← schema imports (if needed)
    aspects/
      core/
        time.nix                     ← chrony NTS
        nix.nix                      ← Nix daemon config
        ssh.nix                      ← services.openssh + host key config (extracted from defaults.nix)
        sudo.nix                     ← sudo-rs
        facter.nix                   ← nixos-facter
        impermanence.nix             ← environment.persistence + ZFS rollback (uses hasAspect)
        remote-unlock.nix            ← Hoopsnake initrd
        resolved-user-emitter.nix    ← quirk: emits resolved-user per user
        persist-collector.nix        ← quirk: collects pipe.persist + pipe.cache → environment.persistence
        firewall-collector.nix       ← quirk: collects pipe.firewall → lib.mkMerge
      features/
        ssh-keys.nix                 ← Battery: SSH keys → openssh.authorizedKeys
      secrets/
        sops.nix                     ← secretRequests → sops-nix mapper
        hardcoded.nix                ← hardcoded secret provider
      services/
        crowdsec.nix                 ← crowdsec + provides.bouncer
      disk/
        zfs.nix                      ← disko ZFS (was profiles/disks.nix, ZFS portion)
        ext4.nix                     ← ext4 root for VMs
      hardware/
        hypervisor.nix               ← Incus
      networking/
        default.nix                  ← systemd-networkd, nftables, resolved
      roles/
        server.nix                   ← composite: crowdsec + bouncer
        vm.nix                       ← composite: ext4 disk + vm-access networking
      users/
        registry.nix                 ← den.users.registry option + types
        daniel.nix                   ← per-user aspect + registry entry
        alice.nix                    ← per-user aspect + registry entry
        bob.nix                      ← per-user aspect + registry entry
      groups/
        default.nix                  ← den.groups.* entity declarations
      quirks/
        persist.nix                  ← persist + persistHome + cache + firewall + resolved-users declarations
    hosts/
      builder.nix                    ← host entity + den.aspects.builder
      hvn-hyp1.nix                   ← host entity + den.aspects.hvn-hyp1
      daniels-2021-mbp.nix           ← host entity + den.aspects.daniels-2021-mbp
      testvm.nix                     ← host entity + den.aspects.testvm
    policies/
      users.nix                      ← group-based user resolution policy (Phase 5)

  meta/                              ← flake-parts modules (unchanged)
    flake-parts.nix
    inputs.nix
    pkgs.nix
    systems.nix

  flake/                             ← flake-parts addons
    deploy-rs.nix
    formatter.nix
    sops.nix

  nix/                               ← Nix daemon global config (unchanged)
    caches.nix, flakes.nix, optimise.nix, sensible.nix, unfree.nix

  packages/                          ← unchanged
  storage/                           ← non-den NixOS modules (mergerfs.nix)
  tests/                             ← unchanged
```

### 4.6 Migration Steps

Move files with `git mv` to preserve history:

```bash
# 1. Create new directory tree
mkdir -p modules/den/aspects/{core,features,secrets,services,disk,hardware,networking,roles,users,groups,quirks}
mkdir -p modules/den/{hosts,schema,policies}

# 2. Move schema files
git mv modules/schema/host.nix modules/den/schema/host.nix
git mv modules/schema/user.nix modules/den/schema/user.nix

# 3. Move core aspects
git mv modules/aspects/profiles/time.nix             modules/den/aspects/core/time.nix
git mv modules/aspects/profiles/facter.nix            modules/den/aspects/core/facter.nix
git mv modules/aspects/profiles/impermanence.nix     modules/den/aspects/core/impermanence.nix
git mv modules/aspects/profiles/remote-unlock.nix    modules/den/aspects/core/remote-unlock.nix
git mv modules/aspects/nix/default.nix               modules/den/aspects/core/nix.nix
git mv modules/security/sudo.nix                     modules/den/aspects/core/sudo.nix

# 4. Move secrets
git mv modules/aspects/secrets/sops.nix             modules/den/aspects/secrets/sops.nix
git mv modules/aspects/secrets/hardcoded.nix        modules/den/aspects/secrets/hardcoded.nix

# 5. Move services
git mv modules/aspects/services/crowdsec.nix        modules/den/aspects/services/crowdsec.nix

# 6. Move disk (split from profiles/disks.nix — this is a new file, not a move)
#    Create disk/zfs.nix and disk/ext4.nix as new files, then:
git rm modules/aspects/profiles/disks.nix

# 7. Move hardware
git mv modules/aspects/profiles/hypervisor.nix      modules/den/aspects/hardware/hypervisor.nix

# 8. Move networking
git mv modules/aspects/profiles/networking.nix       modules/den/aspects/networking/default.nix

# 9. Move roles
git mv modules/aspects/profiles/server.nix           modules/den/aspects/roles/server.nix

# 10. Move hosts (flatten)
git mv modules/aspects/hosts/builder/default.nix            modules/den/hosts/builder.nix
git mv modules/aspects/hosts/hvn-hyp1/default.nix           modules/den/hosts/hvn-hyp1.nix
git mv modules/aspects/hosts/daniels-2021-mbp/default.nix   modules/den/hosts/daniels-2021-mbp.nix
git mv modules/aspects/hosts/testvm/default.nix             modules/den/hosts/testvm.nix

# 11. Move defaults + namespace
git mv modules/aspects/default.nix  modules/den/defaults.nix
git mv modules/namespace.nix        modules/den/namespace.nix

# 12. Create new files (Phase 1-3 artifacts)
# modules/den/aspects/features/ssh-keys.nix
# modules/den/aspects/users/registry.nix
# modules/den/aspects/users/daniel.nix
# modules/den/aspects/users/alice.nix
# modules/den/aspects/groups/default.nix
# modules/den/aspects/quirks/persist.nix
# modules/den/aspects/core/resolved-user-emitter.nix
# modules/den/aspects/core/persist-collector.nix
# modules/den/aspects/core/firewall-collector.nix
# modules/den/aspects/disk/zfs.nix
# modules/den/aspects/disk/ext4.nix
# modules/den/aspects/roles/vm.nix
# modules/den/policies/users.nix

# 13. Clean up empty directories
rmdir modules/aspects/{hosts/builder,hosts/hvn-hyp1,hosts/daniels-2021-mbp,hosts/testvm,hosts}
rmdir modules/aspects/{profiles,secrets,services,nix}
rmdir modules/aspects
rmdir modules/schema
rmdir modules/security

# 14. Remove stale pre-den files
git rm modules/lib/asserts.nix modules/lib/default.nix modules/lib/dlab.nix modules/lib/dsl.nix modules/lib/utilities.nix
git rm modules/hosts/builder/_configuration.nix modules/hosts/hvn-hyp1/_configuration.nix
git rm modules/hosts/daniels-2021-mbp/_configuration.nix modules/hosts/testvm/_default.nix

# 15. Regenerate flake
nix run .#write-flake --impure
```

### 4.7 Update All Aspect References

After file moves and namespace change, update every reference (in host includes, role composites, and schema wiring):

| Old reference | New reference |
|---|---|
| `den.aspects."dlab/profile/time"` | `den.aspects.core.time` |
| `den.aspects."dlab/profile/networking"` | `den.aspects.networking.default` |
| `den.aspects."dlab/profile/impermanence"` | `den.aspects.core.impermanence` |
| `den.aspects."dlab/profile/facter"` | `den.aspects.core.facter` |
| `den.aspects."dlab/profile/remote-unlock"` | `den.aspects.core.remote-unlock` |
| `den.aspects."dlab/profile/disks"` | `den.aspects.disk.zfs` (bare-metal) or `den.aspects.disk.ext4` (VMs) |
| `den.aspects."dlab/profile/server"` | `den.aspects.roles.server` |
| `den.aspects."dlab/profile/hypervisor"` | `den.aspects.hardware.hypervisor` |
| `den.aspects."dlab/services/crowdsec"` | `den.aspects.services.crowdsec` |
| `den.aspects."dlab/secrets/sops"` | `den.aspects.secrets.sops` |
| `den.aspects."dlab/secrets/hardcoded"` | `den.aspects.secrets.hardcoded` |

---

## Phase 5: Policies

**v3 changes from v2**: Complete fleet-demo policy replacement. The default `host-to-users` policy is excluded and fully replaced with group-based resolution. Added `den.schema.host.excludes` to remove the default policy (core den feature). No fork dependencies.

### 5.1 What Policies Are

Policies are functions that resolve entities onto other entities. Den ships with a default `host-to-users` policy (`modules/policies/core.nix`) that auto-includes user aspects on hosts that declare `users.<name>`. For the homelab's requirement (different access rules per host, group-based resolution), this default policy is replaced.

### 5.2 Group-Based User Resolution Policy

**New file:** `modules/den/policies/users.nix`

```nix
{ lib, den, config, ... }:
let
  inherit (den.lib.policy) resolve;  # ✅ core den
  registry = config.den.users.registry or { };

  matchUsers = hostAccessGroups:
    builtins.attrValues (
      lib.filterAttrs (name: user:
        let userGroups = user.groups or [ ];
        in builtins.any (g: lib.elem g hostAccessGroups) userGroups
      ) registry
    );
in {
  # Replace default host-to-users with group-based resolution.
  den.schema.host.excludes = [ den.policies.host-to-users ];  # ✅ core den

  den.policies.group-users = { host, ... }:                   # ✅ core den
    let
      accessGroups = host.system-access-groups or [ ];
      matched = matchUsers accessGroups;
    in map (user: resolve.to "user" { inherit user; }) (builtins.attrValues matched);
}
```

With this policy, you no longer need `users.daniel = { }` on every host entity. A user gets an account on a host when their group memberships intersect the host's `system-access-groups`.

### 5.3 Fleet-Demo Policy Tree Reference

For reference, sini's full policy tree (`fleet → environment → host → user`) is documented in `modules/den/policies/fleet.nix`. The homelab doesn't need this complexity yet. Trigger point: when you introduce environment entities with distinct access rules.

---

## Phase 6: Den-Native Refactors

### ⚠️ Fork-Gated

All features in this phase require `github:sini/den/feat/entity-gen-schema-port`. They are documented here for when the fork merges into mainline `github:denful/den`.

### 6.1 Dynamic `settingsType` (sini pattern) 🐚 ⚠️

**Requires:** Fork (`den.schema.host.imports` + `den.lib.aspects.fx.keyClassification`)

Currently, settings are declared manually in `schema/host.nix` as shown in Phase 2. The dynamic approach auto-discovers settings by walking `den.aspects`:

```nix
# modules/den/schema/host.nix (with fork)
den.schema.host.imports = [
  ({ config, den, lib, ... }: {
    options.settings = lib.mkOption {
      type = lib.types.submodule {
        options = buildSettingsModule (den.aspects or { });
      };
    };
  })
];
```

This means adding `.settings.options.*` to any aspect automatically creates the corresponding option on host entities — no manual schema wiring needed.

### 6.2 Environment Entities (sini pattern) 🐚 ⚠️

**Requires:** Fork (`gen-schema` entity types with methods/refs)

```nix
den.environments.home = {
  domain = "home.vicory.com";
  timezone = "America/Chicago";
  networks.lan.cidr = "192.168.65.0/24";
  settings.disk.encryption.enable = true;       # cascade to all home hosts
  settings.disk.backend = "zfs";
};

den.environments.vms = {
  settings.disk.encryption.enable = false;       # no encryption on VMs
  settings.disk.backend = "ext4";
};
```

With the fork, environments cascade settings via scope-engine, and the policy system resolves which hosts belong to which environment.

### 6.3 Settings Cascade (scope-engine) 🐚 ⚠️

**Requires:** Fork (`github:sini/scope-engine`)

Resolves settings with precedence: **aspect defaults → environment → host → user**. This means a host can inherit environment-level defaults and override specific values:

```nix
# Environment: all VMs use ext4
den.environments.vms.settings.disk.backend = "ext4";

# Override: one VM uses ZFS for testing
den.hosts.x86_64-linux.testvm-zfs.settings.disk.backend = "zfs";
```

---

## Migration Reference

| Den Path | Purpose | Phase | Fork? | Status |
|----------|---------|-------|-------|--------|
| `den.default.nixos` | Global NixOS defaults | — | ✅ | ✅ SSH, mutableUsers, stateVersion, emergencyAccess |
| `den.default.includes` | Global batteries | 1 | ✅ | ✅ hostname, define-user, ssh-keys battery |
| `den.schema.host` | Host entity metadata | 1,2 | ✅ | 🔜 Add `system-access-groups`, `settings.*` |
| `den.schema.host.includes` | Auto-applied aspects | 1,3 | ✅ | 🔜 core.time, networking.default, persist-collector, firewall-collector |
| `den.schema.host.excludes` | Excluded policies | 5 | ✅ | 🔜 Exclude default host-to-users |
| `den.schema.user` | User entity metadata | 1 | ✅ | 🔜 Add `identity`, `system` submodules |
| `den.schema.user.isEntity` | Users as real entities | 1 | ✅ | 🔜 Set to `true` via registry |
| `den.schema.user.includes` | Auto-include policies | 1 | ✅ | 🔜 resolved-user-emitter + auto-include |
| `den.aspects.core.*` | Core system aspects | 4 | ✅ | 🔜 9 aspects (time, nix, ssh, sudo, facter, impermanence, remote-unlock, resolved-user-emitter, collectors) |
| `den.aspects.disk.*` | Filesystem aspects | 4 | ✅ | 🔜 zfs + ext4 (split from monolithic disks.nix) |
| `den.aspects.hardware.*` | Hardware enablement | 4 | ✅ | 🔜 hypervisor |
| `den.aspects.networking.*` | Networking | 4 | ✅ | 🔜 default |
| `den.aspects.services.*` | Service daemons | 4 | ✅ | ✅ crowdsec + provides.bouncer |
| `den.aspects.secrets.*` | Secret providers | 4 | ✅ | ✅ sops + hardcoded |
| `den.aspects.roles.*` | Composite roles | 4 | ✅ | 🔜 server, vm |
| `den.aspects.features.*` | Cross-cutting features | 1,4 | ✅ | 🔜 ssh-keys battery |
| `den.aspects.users.*` | Per-user aspects | 1 | ✅ | 🔴 daniel, alice (new files) |
| `den.aspects.groups.*` | Group entities | 1 | ✅ | 🔴 default (new file) |
| `den.aspects.quirks.*` | Quirk declarations | 3 | ✅ | 🔴 persist (new file) |
| `den.users.registry` | User declarations | 1 | ✅ | 🔴 New file |
| `den.groups.*` | Group entities | 1 | ✅ | 🔴 New file |
| `den.policies.group-users` | Group-based resolution | 5 | ✅ | 🟡 Replace default host-to-users |
| `den.batteries.define-user` | User account creation | 1 | ✅ | ✅ In `den.default.includes` |
| `den.batteries.hostname` | Hostname from entity | — | ✅ | ✅ In `den.default.includes` |
| `den.batteries.primary-user` | Admin user (wheel+networkmanager) | 1 | ✅ | 🔜 Added via per-user `includes` |
| `den.batteries.user-shell` | Default shell | 1 | ✅ | 🔜 Added via per-user `includes` |
| `den.batteries.mutual-provider` | Inert compat shim | 1 | ✅ | 🟡 Removed from `default.includes` |
| `den.quirks.*` | Cross-aspect data pipes | 3 | ✅ | 🔴 persist, persistHome, cache, firewall, resolved-users |
| `den.reservedKeys` | Reserved keys for pipe safety | 6 | ❌ | 🔴 Fork-gated |
| `host.hasAspect` | Structural aspect detection | 2 | ✅ | 🔴 Replace null checks |
| `host.settings.*` | Per-host typed configuration | 2 | ✅ | 🔴 Manual schema wiring (no fork) |
| `os` class | Cross-platform shorthand | 2 | ✅ | 🔜 Adopt in ssh-keys, nix aspects |
| Dynamic `settingsType` | Auto-discovered settings | 6 | ❌ | 🔴 Fork-gated |
| Environment entities | Env-level defaults/scope | 6 | ❌ | 🔴 Fork-gated |
| `scope-engine` | Settings cascade + ACL | 6 | ❌ | 🔴 Fork-gated |

---

## Cross-Example Findings (9 den users surveyed)

Surveyed: sini, Codys-Wright, talianappin, zakuciael, hydeik, esselius, michaelBelsanti, Paul1365972, and the den example template.

### What everyone agrees on

| Pattern | Used by | Confirmed? |
|---------|---------|:---:|
| Per-file user aspects | All 9 | Yes |
| Per-file host aspects | All 9 | Yes |
| `den.default.nixos` for global defaults | All 9 | Yes |
| Batteries for common patterns | All 9 | Yes |
| File hierarchy by function not type | All 9 | Yes |
| No "profile" in any aspect name | All 9 | Yes — zero occurrences |

### User model: Group-based (fleet-demo / sini pattern) 🛡 🐚

```nix
# User declares groups in registry
den.users.registry.alice.groups = [ "developers" "vm-access" ];

# Host declares access groups
den.hosts.x86_64-linux.testvm.system-access-groups = [ "admins" "vm-access" ];

# Group-users policy resolves intersection
# Alice gets an account on testvm because "vm-access" overlaps
```

### Naming Conventions Survey

| Example | Uses "profile"? | Top-level categories |
|---------|:---:|---|
| `den/templates/example` | No | Flat + `eg/` namespace |
| `den/templates/fleet-demo` | No | `features/`, `hosts/`, `users/` |
| `den/templates/ci` | No | `features/`, `test-support/` |
| `den-examples/sini` | No | `apps/`, `core/`, `desktop/`, `devshell/`, `disk/`, `hardware/`, `kubernetes/`, `network/`, `roles/`, `secrets/`, `services/`, `system/`, `virtualization/` |
| `den-examples/Codys-Wright` | No | Flat |
| `den-examples/Paul1365972` | No | `desktop/`, `media-server/`, `rpi/`, `tools/` |
| `den/modules/aspects` (built-in) | No | `batteries/` |
| **All others (5 repos)** | N/A | No `modules/aspects/` dir (pre-aspect pattern) |

---

## Den Source & Examples Guide

| Location | What's There |
|----------|--------------|
| `~/src/den/modules/aspects/batteries/*.nix` | Battery implementations |
| `~/src/den/modules/policies/core.nix` | Default host-to-users resolution policy |
| `~/src/den/modules/compat/mutual-provider-shim.nix` | Inert compat shim |
| `~/src/den/nix/lib/aspects/fx/assemble-pipes.nix` | Quirk pipe assembly (804 lines) |
| `~/src/den/nix/lib/aspects/fx/key-classification.nix` | Pipe key classification |
| `~/src/den/templates/example/modules/aspects/alice.nix` | Per-user aspect with batteries + cross-scope policy |
| `~/src/den/templates/example/modules/aspects/hasAspect-examples.nix` | `hasAspect` + `oneOfAspects` worked examples (141 lines) |
| `~/src/den/templates/example/modules/aspects/defaults.nix` | Global defaults with scope guard warnings |
| `~/src/den/templates/fleet-demo/modules/aspects/users/ssh-keys.nix` | SSH keys as a formal battery (23 lines) |
| `~/src/den/templates/fleet-demo/modules/users.nix` | User registry with group-based resolution (139 lines) |
| `~/src/den/templates/fleet-demo/modules/policies/fleet.nix` | Policy-driven entity topology (98 lines) |
| `~/src/den-examples/sini/modules/den/defaults.nix` | Sini defaults: reservedKeys, schema.includes wiring, auto-include policy |
| `~/src/den-examples/sini/modules/den/aspects/core/resolved-user-emitter.nix` | Quirk: emits resolved-user per user (14 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/persist-collector.nix` | Collector: pipe.persist + pipe.cache → environment.persistence |
| `~/src/den-examples/sini/modules/den/aspects/core/firewall-collector.nix` | Collector: pipe.firewall → lib.mkMerge (5 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/nix.nix` | Aspect with `os` class shorthand |
| `~/src/den-examples/sini/modules/den/users/sini.nix` | User registry entry with rich schema |
| `~/src/den-examples/sini/modules/den/policies/users.nix` | Full user registry type + ACL policies (120 lines) |
| `~/src/den-examples/sini/modules/den/policies/fleet.nix` | Full policy tree (89 lines) |
| `~/src/den-examples/sini/modules/den/quirks/impermanence.nix` | Quirk-based persist directory collection |
| `~/src/den-examples/sini/modules/den/schema/host.nix` | Advanced host schema with dynamic settingsType (364 lines) |
| `~/src/den-examples/sini/modules/den/schema/environment.nix` | Environment entity schema (341 lines) |
| `~/src/den-examples/sini/modules/den/schema/user.nix` | Extended user schema (103 lines) |
| `~/src/den-examples/sini/modules/den/scope-engine/settings.nix` | Settings cascade scope graph (147 lines) |
| `~/src/den-examples/sini/modules/den/hosts/bitstream.nix` | Host entity with settings and role includes |

---

## Concept Deep-Dives

### hasAspect: When and Why

**The 95% case — Reading:** Use `host.hasAspect` inside NixOS/Darwin/HomeManager bodies to branch on whether a companion aspect is structurally present. Cycle-safe.

```nix
# ✅ Correct: inside a class body
den.aspects.core.impermanence = { host, ... }: {
  nixos = { lib, ... }:
    lib.mkIf (host.hasAspect den.aspects.disk.zfs) {
      # ZFS-specific impermanence config
    };
};
```

**The 5% case — Writing:** Use `meta.handleWith` + fx constraints to decide which aspects belong in the tree.

```nix
# ✅ Correct: structural decision at meta level
den.aspects.secrets-bundle = {
  includes = [ den.aspects.secrets.sops den.aspects.secrets.agenix ];
  meta.handleWith = den.lib.aspects.fx.constraints.exclude den.aspects.secrets.agenix;
};
```

**Anti-pattern — Never use `hasAspect` in `includes`:** Infinite recursion.

### Quirks: How Collectors Get Their Data

The flow for a quirk like `persist`:

1. **Declaration:** `den.quirks.persist = { type = ...; default = []; }` — registered as a pipe name
2. **Emission:** Aspect writes `pipe.persist = [ { directory = "/var/lib/incus"; ... } ]`
3. **Assembly:** den's `assemblePipes.nix` collects all `pipe.persist` values across aspects for each entity scope
4. **Delivery:** The collector aspect (`persist-collector.nix`) receives the assembled list via function args: `{ persist, cache, lib, ... }`
5. **Transformation:** Collector merges into `environment.persistence."/persist"`

This is why quirk collectors need to be declared in `den.schema.host.includes` — they need to fire at every host scope to receive the assembled pipe data.

### How Users Reach Hosts: The Full Resolution Chain

```
1. den.users.registry.daniel = { groups = [ "admins" ]; identity = { ... }; }
2. den.hosts.x86_64-linux.builder.system-access-groups = [ "admins" ]
3. den.policies.group-users fires at host scope:
   - Reads host.system-access-groups → [ "admins" ]
   - Matches registry users whose groups intersect → [ daniel ]
   - Calls resolve.to "user" for each match
4. User entity is created with registry data
5. den.schema.user.includes runs:
   a. resolved-user-emitter: emits quirk entry per user
   b. auto-include: checks den.aspects.builder.daniel (per-host override)
6. den.aspects.daniel.policies.to-hosts fires:
   - Checks host ? users.daniel → true
   - den.lib.policy.provide pushes NixOS config (password, shell, etc.)
7. define-user battery creates the Unix account
8. primary-user battery adds wheel + networkmanager groups
9. ssh-keys battery populates authorizedKeys from identity.sshKeys
```

### Settings: Core Den vs Fork Approach

| Approach | Declared in | Auto-discovery | Fork? | Scale limit |
|---|---|---|---|---|
| Manual (v3 Phase 2) | `schema/host.nix` — function pattern `options.settings.*` | No | No | ~10 aspects (manual wiring OK) |
| Dynamic (v3 Phase 6) | Aspect `.settings.options.*` → auto-wired by `settingsType` | Yes | Yes | Unlimited |

Manual is sufficient for the homelab's 7-aspect scale. The dynamic approach becomes valuable when aspects proliferate (sini has 216).

---

## Quick Start

1. **Phase 0** — fix bugs, deploy immediately
2. **Phase 1** — parametric users, groups, registry, ssh-keys battery, auto-include policy
3. **Phase 2** — manual settings on schema.host, `hasAspect` replacements, `os` shorthand
4. **Phase 3** — declare quirks, migrate `persist.directories` to quirk pipes, add collectors
5. **Phase 4** — file moves, split disks, short names, `nix run .#write-flake --impure`
6. **Phase 5** — replace default host-to-users with group-based policy
7. **Phase 6** — fork-gated: wait for `feat/entity-gen-schema-port` to land in mainline
