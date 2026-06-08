# Den Migration v2: Audit, Roadmap & Concepts

Pre-den baseline: `eea36b4^` (before "Initial den migration")
v1 baseline: `docs/den-migration.md` (superseded)

---

## Contents

- [What Changed from v1](#what-changed-from-v1)
- [Phase 0: Fix Regressions](#phase-0-fix-regressions) — bugs, deploy now
- [Phase 1: User & Group Model](#phase-1-user--group-model) — parametric users, group registry, SSH keys
- [Phase 2: Settings on Aspects](#phase-2-settings-on-aspects) — typed per-host configuration, `hasAspect`
- [Phase 3: Quirks](#phase-3-quirks) — cross-aspect data pipes
- [Phase 4: Rename & Reorganize](#phase-4-rename--reorganize) — file moves, short names
- [Phase 5: Policies](#phase-5-policies) — explicit entity topology, group-based resolution
- [Phase 6: Den-Native Refactors](#phase-6-den-native-refactors) — aspirational
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

---

## What Changed from v1

**Phase reordering** — v1 did file reorganization (Phase 1) before conceptual refactors (Phase 3). v2 does all conceptual work first. Why: editing aspect references across 20+ files after moving them creates painful rebase conflicts. Refactor in-place, then move clean files.

**Short names enabled** — v1 left `inputs.den.namespace "dlab" false`. v2 changes to `true` so aspects use `den.aspects.core.time` instead of `den.aspects."dlab/profile/time"`. This touches every aspect reference; doing it as part of the reorganization phase avoids double-editing.

**Quirks replace bespoke NixOS options** — v1 noted quirks as aspirational (Phase 4). v2 adopts them in Phase 3 for `persist.directories` and optionally `secretRequests`. Why: quirks are den's mechanism for cross-aspect data collection; reimplementing them as NixOS options is fighting the framework.

**Settings on aspects moved earlier** — v1 had settings as aspirational (Phase 4). v2 moves them to Phase 2, immediately after the user model refactor. Expanded to cover both the mechanism and the value proposition (self-documenting aspects, per-host overrides without code changes).

**Group-based user model** — v1 recommended per-user files (pattern A) as sufficient for 1 user. v2 adopts the fleet-demo group registry pattern (pattern B) because the target is 3 users with different access rules across 5-15 systems. The triggering condition for group-based resolution is "different access rules per host," not raw user count.

**`hasAspect` as first-class pattern** — v1 never mentioned it. v2 introduces it alongside settings in Phase 2 as the canonical way to write conditional NixOS config that depends on which aspects a host has.

**`mutual-provider` noted as inert** — v1 listed it as a functional battery. v2 documents that it's a compat shim (cross-entity routing is now built-in to den) and can be removed.

---

## Phase 0: Fix Regressions

These are bugs. Fix and deploy immediately.

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

Without this, chrony's persistent directories are owned by root and chrony can't write logs/drift files.

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

Add these back. Makes troubleshooting SSH unlock in initrd possible.

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

The mergerfs module still exists at `modules/storage/mergerfs.nix` (uses the `dlab` namespace). The hvn-hyp1 aspect never references it. Add the config block.

---

## Phase 1: User & Group Model

**v1 change**: Was Phase 3 §2.1-2.2 in v1. Moved earlier because refactoring the user model touches every host entity and the central `default.nix` — doing it before file reorganization avoids editing moved files twice. Expanded to include the group registry pattern now that the target scale (3 users, 5-15 hosts, different access rules) requires it.

### 1.1 Why This Matters

The hardcoded `users.users.daniel` in `den.default.nixos` is the single biggest structural gap between "den-compatible" and "den-native." It's the same problem as the old `profiles/base.nix`: a global module that bakes in assumptions about one specific user. In den, users are entities — they should be declared independently and resolved onto hosts by policy.

This phase introduces:

1. **Per-user aspect files** — each user declares their own aspect with batteries and NixOS config
2. **Group entities** — groups are entities that carry access semantics
3. **User registry with ACLs** — fleet-demo pattern: declare which groups get access to which systems, policy resolves users
4. **Named SSH keys battery** — replaces the inline lambda in `default.includes`
5. **`primary-user` battery** — replaces hardcoded `extraGroups = [ "wheel" ]`

### 1.2 Target: Users

Three users across the homelab:

| User | Groups | Access |
|------|--------|--------|
| `daniel` | `admins`, `system-access` | Every host |
| `alice` | `developers`, `vm-access` | VMs only, no bare-metal |
| `bob` | `services`, `vm-access` | VMs only, specific service VMs |

### 1.3 Group Entities

**New file:** `modules/aspects/groups/default.nix`

```nix
# Groups are entities that carry access semantics. Users declare membership
# in their registry entry. Hosts declare which groups are granted access.
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

**File:** `modules/schema/host.nix` — add:

```nix
system-access-groups = mkOption {
  type = types.listOf types.str;
  default = [ "system-access" ];
  description = "Groups granted Unix account access on this host";
};
```

Hosts override this in their entity data:

```nix
# hvn-hyp1 (bare-metal hypervisor)
den.hosts.x86_64-linux.hvn-hyp1 = {
  system-access-groups = [ "admins" "system-access" ];
  # ...
};

# testvm (VM)
den.hosts.x86_64-linux.testvm = {
  system-access-groups = [ "admins" "vm-access" "developers" "services" ];
  # ...
};
```

### 1.5 Extend User Schema

**File:** `modules/schema/user.nix` — add `identity` submodule:

```nix
{ lib, ... }:
let
  inherit (lib) mkOption types;

  sshKeyType = types.submodule {
    options = {
      tag = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Tag to categorize the SSH key (e.g., 'laptop', 'yubikey')";
      };
      key = mkOption {
        type = types.str;
        description = "SSH public key string";
      };
    };
  };
in {
  den.schema.user.imports = [
    (_: {
      options = {
        identity = mkOption {
          type = types.submodule {
            options = {
              displayName = mkOption {
                type = types.str;
                default = "";
                description = "Display name for the user";
              };
              email = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Email address for the user";
              };
              sshKeys = mkOption {
                type = types.listOf sshKeyType;
                default = [ ];
                description = "SSH public keys for the user, each with an optional tag";
              };
            };
          };
          default = { };
        };
        system = mkOption {
          type = types.submodule {
            options = {
              uid = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = "User ID for the Unix account";
              };
            };
          };
          default = { };
        };
      };
    })
  ];
}
```

### 1.6 User Registry

**New file:** `modules/aspects/users/registry.nix`

```nix
# User registry with group-based access. Mirrors fleet-demo pattern:
# users declare groups → hosts declare access groups → policy resolves intersection.
{ lib, den, ... }:
let
  inherit (lib) mkOption types;

  registryUserType = types.submodule (
    { name, config, ... }: {
      imports = [ den.schema.user ];
      config._module.args.user = config;
      options = {
        name = mkOption {
          type = types.str;
          default = name;
        };
        userName = mkOption {
          type = types.str;
          default = name;
        };
        groups = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Group memberships for access policy selection";
        };
        primaryUser = mkOption {
          type = types.bool;
          default = false;
          description = "Whether this user is the primary user on their hosts";
        };
      };
    }
  );
in {
  options.den.users.registry = mkOption {
    type = types.attrsOf registryUserType;
    default = { };
    description = "User registry with extended schema for access-based resolution";
  };

  # Users are real entities
  config.den.schema.user.isEntity = true;
}
```

### 1.7 Per-User Aspect Files

**New file:** `modules/aspects/users/daniel.nix`

```nix
# Primary user — present on all hosts with admin access.
{ den, lib, config, ... }: {
  den.users.registry.daniel = {
    groups = [ "admins" ];
    primaryUser = true;
    identity = {
      displayName = "Daniel Vicory";
      email = "daniel@vicory.com";
      sshKeys = [
        { tag = "laptop"; key = "ssh-ed25519 AAAAC3..."; }
        { tag = "desktop"; key = "ssh-ed25519 AAAAC3..."; }
      ];
    };
  };

  den.aspects.daniel = {
    includes = [
      den.batteries.primary-user
      (den.batteries.user-shell "zsh")
      den.aspects.ssh-keys
      den.aspects.daniel.policies.to-hosts
    ];

    nixos = { pkgs, ... }: {
      users.users.daniel.packages = with pkgs; [ git bottom lnav vim ];
    };

    policies.to-hosts = { host, user, ... }:
      lib.optional (host ? users.${user.userName}) (
        den.lib.policy.provide {
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

**New file:** `modules/aspects/users/alice.nix`

```nix
# Secondary user — developers group, VM access only.
{ den, lib, config, ... }: {
  den.users.registry.alice = {
    groups = [ "developers" "vm-access" ];
    identity = {
      displayName = "Alice";
      email = "alice@example.com";
      sshKeys = [
        { tag = "laptop"; key = "ssh-ed25519 AAAAC3..."; }
      ];
    };
  };

  den.aspects.alice = {
    includes = [
      den.aspects.ssh-keys
      den.aspects.alice.policies.to-hosts
    ];

    policies.to-hosts = { host, user, ... }:
      lib.optional (host ? users.${user.userName}) (
        den.lib.policy.provide {
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

### 1.8 Named SSH Keys Battery

**New file:** `modules/aspects/features/ssh-keys.nix`

```nix
# Battery: reads user.identity.sshKeys and populates openssh.authorizedKeys.keys.
# Replaces the inline lambda in den.default.includes.
# Following fleet-demo pattern: ~/src/den/templates/fleet-demo/modules/aspects/users/ssh-keys.nix
{ lib, ... }: {
  den.aspects.ssh-keys = { host, user, ... }: {
    nixos = lib.mkIf (user ? identity.sshKeys && user.identity.sshKeys != []) {
      users.users.${user.userName}.openssh.authorizedKeys.keys =
        map (entry: entry.key) user.identity.sshKeys;
    };
    darwin = lib.mkIf (user ? identity.sshKeys && user.identity.sshKeys != []) {
      users.users.${user.userName}.openssh.authorizedKeys.keys =
        map (entry: entry.key) user.identity.sshKeys;
    };
  };
}
```

### 1.9 Update `den.default.includes`

**File:** `modules/aspects/default.nix`

Replace the inline SSH key lambda with the named battery:

```nix
den.default.includes = [
  den.batteries.hostname
  den.batteries.define-user
  den.aspects.ssh-keys   # ← was anonymous closure, now named battery
];
```

Note: `den.batteries.mutual-provider` is removed — it's an inert compat shim. Cross-entity routing is now built into den's `emitAspectPolicies`.

### 1.10 Remove Hardcoded User from `den.default.nixos`

**File:** `modules/aspects/default.nix` — delete:

- `users.users.daniel` block (lines 85-89)
- `secretRequests."users/daniel/hashedPassword"` entry (lines 79-83)
- `extraGroups = [ "wheel" ]` (handled by `primary-user` battery)

### 1.11 Update Host Entities for Group-Based Access

Each host's entity data needs `system-access-groups` and `users.<name>` declarations:

**File:** `modules/aspects/hosts/builder/default.nix`

```nix
den.hosts.aarch64-linux.builder = {
  system-access-groups = [ "admins" "system-access" ];
  users.daniel = { };
  # ...
};
```

**File:** `modules/aspects/hosts/hvn-hyp1/default.nix`

```nix
den.hosts.x86_64-linux.hvn-hyp1 = {
  system-access-groups = [ "admins" "system-access" ];
  users.daniel = { };
  # ...
};
```

**File:** `modules/aspects/hosts/testvm/default.nix`

```nix
den.hosts.x86_64-linux.testvm = {
  system-access-groups = [ "admins" "vm-access" "developers" "services" ];
  users.daniel = { };
  users.alice = { };
  # ...
};
```

---

## Phase 2: Settings on Aspects

**v1 change**: Was Phase 4 §3.1 in v1 (aspirational). Moved to Phase 2 because `settings` is the mechanism by which aspects become self-documenting and host-configurable. Without it, per-host overrides require conditional NixOS config or forked aspects. With it, a host says `host.settings.hardware.disks.swap.enable = false` and the aspect reads that at runtime.

Also introduces `hasAspect` as the canonical den-native pattern for conditional NixOS config — replacing the current pattern of checking entity data fields (`host.zfs.rootPool != null`) with structural queries (`host.hasAspect den.aspects.hardware.disks`).

### 2.1 Why Settings

Currently, aspects hardcode their behavior or infer it from entity data. Example from `disks.nix`:

```nix
# Current: disks.nix reads host.zfs.rootPool and host.zfs.swap to configure disko.
# Problem: testvm doesn't use ZFS at all, but there's no way for testvm to tell
#          the disk aspect "skip ZFS, use ext4" — it just omits the entity data
#          and the aspect gates everything behind `lib.mkIf (pool != null)`.
```

With settings, the aspect declares what it can configure:

```nix
den.aspects.hardware.disks.settings = {
  options = {
    backend = mkOption {
      type = types.enum [ "zfs" "ext4" ];
      default = "zfs";
      description = "Disk layout backend";
    };
    encryption.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable native ZFS encryption";
    };
    swap.size = mkOption {
      type = types.str;
      default = "8G";
      description = "Swap partition size";
    };
  };
};
```

And hosts configure via entity data:

```nix
den.hosts.x86_64-linux.testvm = {
  settings.hardware.disks = {
    backend = "ext4";
    swap.size = "4G";
  };
};
```

The aspect reads `host.settings.hardware.disks.*` in its NixOS body instead of checking raw entity fields. This means:
- Adding a new host with different disk requirements doesn't require editing the aspect
- Settings are typed — mkOption enforces valid values
- Settings are self-documenting — `nixos-option` or TUI tools can discover what each aspect accepts

### 2.2 Settings Target: Every Aspect That Has Configurable Behavior

| Aspect | Settings to add |
|--------|----------------|
| `disks.nix` | `backend` (zfs/ext4), `encryption.enable`, `swap.size` |
| `networking.nix` | `firewall.enable`, `dns.overTls` |
| `hypervisor.nix` | `incus.enable`, `incus.webUiPort` |
| `time.nix` | `chrony.servers` (list), `chrony.enableNts` |
| `impermanence.nix` | `rollback.enable`, `persistPrefix` |
| `remote-unlock.nix` | `tailscale.authKey`, `hoopsnake.port` |
| `crowdsec.nix` | `bouncer.enable`, `enrollmentKey` |

### 2.3 hasAspect: Conditional NixOS Config Done Right

The den-native way to write "if this host uses ZFS, configure the rollback service" is `host.hasAspect`:

```nix
# Current approach: check entity data (indirect, fragile)
# modules/aspects/profiles/impermanence.nix
nixos = lib.mkIf (host.zfs.rootPool != null) { ... };
```

```nix
# Den-native approach: check structural aspect presence (direct, resilient)
den.aspects.core.impermanence = { host, ... }: {
  nixos = { lib, ... }:
    lib.mkIf (host.hasAspect den.aspects.hardware.disks) {
      # ZFS rollback service, persist mounts, etc.
    };
};
```

**Why it's better:**
- `host.zfs.rootPool != null` is an implementation detail — if the disk aspect changes to use `rootDataset` instead, the check breaks silently
- `host.hasAspect den.aspects.hardware.disks` is a structural query — it asks "does the disk aspect exist on this host?" regardless of the aspect's internal data shape
- Works across indirection — if `disks` is included transitively through a role, `hasAspect` still sees it
- Cycle-safe — `hasAspect` reads from `host.resolved`, which is frozen by the time NixOS bodies evaluate

**Constraint:** `hasAspect` can only be used inside NixOS/Darwin/HomeManager class bodies (the deferred modules). It cannot be used to decide `includes` — that creates a fixed-point cycle. For structural "include or exclude" decisions, use `meta.handleWith` with an fx constraint. See `~/src/den/templates/example/modules/aspects/hasAspect-examples.nix` for 141 lines of worked examples (Pattern 1: reading, Pattern 2: writing, Anti-pattern: includes cycling).

### 2.4 Settings + hasAspect Example: Disks + Impermanence

**Before (current):**

```nix
# disks.nix — reads raw entity fields, gates everything on null check
den.aspects."dlab/profile/disks" = { host, ... }: {
  nixos = lib.mkIf (host.zfs.rootPool != null) {
    # Hardcoded disko config with host.zfs.rootPool.name, host.zfs.rootPool.disk1
  };
};

# impermanence.nix — same null check pattern
den.aspects."dlab/profile/impermanence" = { host, ... }: {
  nixos = lib.mkIf (host.zfs.rootPool != null) {
    # ZFS rollback, persist mounts
  };
};
```

**After:**

```nix
# disks.nix — declares settings, reads them + entity data
den.aspects.hardware.disks.settings = {
  options = {
    backend = mkOption { type = types.enum [ "zfs" "ext4" ]; default = "zfs"; };
    encryption.enable = mkOption { type = types.bool; default = false; };
  };
};

den.aspects.hardware.disks = { host, ... }: {
  nixos = { lib, ... }: let
    settings = host.settings.hardware.disks;
  in lib.mkMerge [
    (lib.mkIf (settings.backend == "zfs") {
      # disko config using host.zfs.rootPool for device layout
    })
    (lib.mkIf (settings.backend == "ext4") {
      # simple ext4 boot config for VMs without ZFS
    })
  ];
};

# impermanence.nix — uses hasAspect instead of null check
den.aspects.core.impermanence = { host, ... }: {
  nixos = { lib, ... }:
    lib.mkIf (host.hasAspect den.aspects.hardware.disks) {
      # Rollback service, persist mounts — works regardless of backend
    };
};
```

### 2.5 Consolidate SSH Enable

**File:** `modules/aspects/profiles/networking.nix` — remove:

```nix
services.openssh.enable = lib.mkDefault true;  # ← DELETE (already in default.nix)
```

This is already set in `modules/aspects/default.nix` alongside the full SSH config.

---

## Phase 3: Quirks

**v1 change**: Was Phase 3 §2.3 in v1 (🟡 "worth adopting") and Phase 4 §3.3 (aspirational). v2 commits to quirks as the primary mechanism for cross-aspect data collection. Replaces the bespoke `persist.directories` NixOS option and evaluates whether `secretRequests` should also become quirk-based.

### 3.1 Why Quirks

Den quirks are a **publish/subscribe pipe system**. Aspects **emit** data into a named pipe. A **collector** aspect subscribes to that pipe and transforms the collected data into actual configuration.

The current `persist.directories` NixOS option works like a quirk (aspects push into it, impermanence reads it), but it's reimplemented as a flat NixOS option. This has two problems:

1. **No typing** — `persist.directories` accepts `types.either types.str types.raw` with no field validation
2. **Not discoverable** — there's no way for a tool to know which aspects contribute to persistence without reading every file

Den quirks solve both: they're declared in the den namespace and aspects reference them by name.

```nix
# No quirk: aspect directly sets a NixOS option
persist.directories = [
  { directory = "/var/lib/incus"; }
];

# With quirk: aspect emits into a typed pipe
pipe.persist = [
  { directory = "/var/lib/incus"; user = "incus"; group = "incus"; }
];
```

### 3.2 Declare Persist Quirk

**New file:** `modules/aspects/quirks/persist.nix`

```nix
# Quirk declaration: defines the persist pipe that aspects emit into.
# The impermanence aspect (collector) reads all pipe.persist emissions
# and merges them into environment.persistence.
{ lib, ... }: {
  den.quirks.persist = {
    description = "Persistent directories and files collected from aspects (host-scoped)";
    type = lib.types.listOf (lib.types.submodule {
      options = {
        directory = lib.mkOption {
          type = lib.types.str;
          description = "Directory path to persist";
        };
        user = lib.mkOption {
          type = lib.types.str;
          default = "root";
          description = "Owner user";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "root";
          description = "Owner group";
        };
        mode = lib.mkOption {
          type = lib.types.str;
          default = "0755";
          description = "Directory mode";
        };
      };
    });
    default = [ ];
  };

  den.quirks.persistHome = {
    description = "Persistent directories and files collected from aspects (user-scoped)";
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
}
```

### 3.3 Update Aspects to Emit into the Persist Quirk

**File:** `modules/aspects/profiles/hypervisor.nix` — replace:

```nix
# Before
persist.directories = [{ directory = "/var/lib/incus"; }];
```

```nix
# After
pipe.persist = [
  { directory = "/var/lib/incus"; user = "incus"; group = "incus"; }
];
```

**File:** `modules/aspects/profiles/time.nix` — replace:

```nix
# Before
persist.directories = [
  { directory = config.services.chrony.directory; }
  { directory = logDir; }
];
```

```nix
# After
pipe.persist = [
  { directory = config.services.chrony.directory; user = chrony; group = chrony; }
  { directory = logDir; user = chrony; group = chrony; }
];
```

**File:** `modules/aspects/profiles/impermanence.nix` — update collector:

```nix
# Before: reads config.persist.directories
environment.persistence."/persist" = {
  directories = map (d: if lib.isString d then { directory = d; } else d) config.persist.directories;
};

# After: reads pipe.persist from quirk collection
# (quirk collection is automatically assembled by den's pipe system;
#  the collector just reads the aggregate)
environment.persistence."/persist" = {
  directories = host.resolved.pipe.persist or [ ];
};
```

### 3.4 Remove the NixOS Option

**File:** `modules/aspects/default.nix` — delete `options.persist.directories`.

### 3.5 Evaluate secretRequests as a Quirk

The existing `secretRequests` → `sops.secrets` / hardcoded mapping is already well-structured. It's a provider-agnostic abstraction with typed fields and two backend providers. This is functionally equivalent to a den quirk.

**Recommendation:** Keep `secretRequests` as-is for now. The implementation is clean and the quirk migration would be a 1:1 rename with no behavioral change. If you add a third secret provider (e.g., agenix, vault), revisit.

### 3.6 Future Quirk Opportunities

| Domain | Quirk Name | What It Collects |
|--------|-----------|-----------------|
| SSH host keys | `ssh-host-keys` | Per-host SSH host key paths → `openssh.hostKeys` |
| Initrd networking | `initrd-networks` | Per-aspect initrd network interfaces → `boot.initrd.network` |
| System packages | `base-packages` | Per-aspect package lists → `environment.systemPackages` |

---

## Phase 4: Rename & Reorganize

**v1 change**: Was Phase 1 and Phase 2 §1.2 in v1. Moved AFTER all conceptual work (Phases 1-3) so files are clean and stable before they're moved. Short names are enabled as part of this phase since every aspect reference is being rewritten anyway.

### 4.1 Problems with Current Layout

| Issue | Current | Problem |
|-------|---------|---------|
| Everything under `aspects/` | `aspects/default.nix`, `aspects/nix/`, `aspects/profiles/`, `aspects/secrets/`, `aspects/services/`, `aspects/hosts/` | Grab-bag with no structure. Schema, lib, nix, and security are separate top-level dirs |
| `profiles/` naming is legacy | `aspects/profiles/time.nix`, `aspects/profiles/disks.nix` | Term "profile" is from old DSL, not den-native |
| Host entity + aspect mixed | `aspects/hosts/builder/default.nix` has both `den.hosts.*` and `den.aspects.builder` | Should be separate concerns |
| Stale pre-den files | `modules/lib/`, `modules/nix/`, `modules/hosts/_*`, `modules/storage/` | Confusing, should be cleaned up to their final homes |
| Nix daemon config is buried | `aspects/nix/default.nix` uses `den.default.nixos` but lives under `aspects/` | It's a core system config, not an entity aspect |
| Long namespace prefixes | `den.aspects."dlab/profile/time"` | Redundant `dlab/` prefix when namespace already handles namespacing |

### 4.2 Enable Short Names

**File:** `modules/namespace.nix` — change:

```nix
# Before
{ inputs, ... }: inputs.den.namespace "dlab" false

# After
{ inputs, ... }: inputs.den.namespace "dlab" true  # flake-exposed → short names
```

This enables `den.aspects.core.time` instead of `den.aspects."dlab/profile/time"`.

### 4.3 Aspect Naming Convention

| Current (v1) | Target (v2) | Why |
|---|---|---|
| `den.aspects."dlab/profile/time"` | `den.aspects.core.time` | System concern, not a "profile" |
| `den.aspects."dlab/profile/networking"` | `den.aspects.networking.default` | Already functional, rename |
| `den.aspects."dlab/profile/disks"` | `den.aspects.hardware.disks` | Disk config is hardware |
| `den.aspects."dlab/profile/impermanence"` | `den.aspects.core.impermanence` | Core system property |
| `den.aspects."dlab/services/crowdsec"` | `den.aspects.services.crowdsec` | Makes sense, keep category |
| `den.aspects."dlab/profile/server"` | `den.aspects.roles.server` | "Server" is a role |
| `den.aspects."dlab/profile/hypervisor"` | `den.aspects.hardware.hypervisor` | Incus is hardware virt |
| `den.aspects."dlab/profile/facter"` | `den.aspects.core.facter` | Hardware detection, core |
| `den.aspects."dlab/profile/remote-unlock"` | `den.aspects.core.remote-unlock` | initrd feature, core |
| `den.aspects."dlab/secrets/sops"` | `den.aspects.secrets.sops` | Keep category |
| `den.aspects."dlab/secrets/hardcoded"` | `den.aspects.secrets.hardcoded` | Keep category |

Categories (following sini's grouping):
- `core/` — essential system config (time, nix, ssh, impermanence, facter, remote-unlock)
- `hardware/` — hardware-specific (disks, hypervisor)
- `networking/` — networking (networkd, firewall, DNS)
- `services/` — daemons (crowdsec)
- `roles/` — composite profiles (server)
- `secrets/` — secret providers (sops, hardcoded)
- `features/` — cross-cutting features (ssh-keys)
- `users/` — user entity files + registry
- `groups/` — group entity files
- `quirks/` — quirk declarations

### 4.4 Target Directory Structure

```
modules/
  den/                              ← ALL den-related config (was modules/aspects/ + scattered)
    defaults.nix                     ← den.default + den.default.includes + den.default.nixos
    flake-parts.nix                  ← den integration + manual output bridge (was nix/den.nix + modules/flake/den.nix)
    schema/
      host.nix                       ← den.schema.host (zfs, networking, system-access-groups, settings)
      user.nix                       ← den.schema.user (identity, system, classes)
    aspects/
      core/
        time.nix                     ← chrony NTS (was profiles/time.nix)
        nix.nix                      ← Nix daemon config (was aspects/nix/default.nix)
        ssh.nix                      ← services.openssh + host key config (was inline in default.nixos)
        sudo.nix                     ← sudo-rs (was modules/security/sudo.nix)
        facter.nix                   ← nixos-facter (was profiles/facter.nix)
        impermanence.nix             ← environment.persistence + ZFS rollback (was profiles/impermanence.nix)
        remote-unlock.nix            ← Hoopsnake initrd (was profiles/remote-unlock.nix)
      features/
        ssh-keys.nix                 ← Battery: user SSH keys → openssh.authorizedKeys (was inline lambda)
      secrets/
        sops.nix                     ← secretRequests → sops-nix mapper (was aspects/secrets/sops.nix)
        hardcoded.nix                ← hardcoded secret provider (was aspects/secrets/hardcoded.nix)
      services/
        crowdsec.nix                 ← crowdsec + provides.bouncer (was aspects/services/crowdsec.nix)
      hardware/
        disks.nix                    ← disko ZFS + ext4 (was profiles/disks.nix)
        hypervisor.nix               ← Incus (was profiles/hypervisor.nix)
      networking/
        default.nix                  ← systemd-networkd, nftables, resolved (was profiles/networking.nix)
      roles/
        server.nix                   ← composite: crowdsec + bouncer (was profiles/server.nix)
      users/
        registry.nix                 ← den.users.registry option + types
        daniel.nix                   ← per-user aspect + registry entry
        alice.nix                    ← per-user aspect + registry entry
        bob.nix                      ← per-user aspect + registry entry
      groups/
        default.nix                  ← den.groups.* entity declarations
      quirks/
        persist.nix                  ← persist + persistHome pipe declarations
    hosts/
      builder.nix                    ← host entity + den.aspects.builder (was hosts/builder/default.nix)
      hvn-hyp1.nix                   ← host entity + den.aspects.hvn-hyp1
      daniels-2021-mbp.nix           ← host entity + den.aspects.daniels-2021-mbp
      testvm.nix                     ← host entity + den.aspects.testvm

  meta/                              ← flake-parts modules (unchanged)
    flake-parts.nix
    inputs.nix                        ← updated: add groups.nix, users/*, quirks/* to auto-imports
    pkgs.nix
    systems.nix

  flake/                             ← flake-parts addons (unchanged)
    deploy-rs.nix
    formatter.nix
    sops.nix

  packages/                          ← unchanged
    initrd.nix
    install-on-envoy.nix

  storage/                           ← non-den NixOS modules
    mergerfs.nix

  tests/                             ← unchanged
    default.nix
```

### 4.5 Migration Steps

Move files one at a time with `git mv` to preserve history:

```bash
# 1. Create new directory tree
mkdir -p modules/den/aspects/{core,features,secrets,services,hardware,networking,roles,users,groups,quirks}
mkdir -p modules/den/{hosts,schema}

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

# 6. Move hardware
git mv modules/aspects/profiles/hypervisor.nix      modules/den/aspects/hardware/hypervisor.nix
git mv modules/aspects/profiles/disks.nix            modules/den/aspects/hardware/disks.nix

# 7. Move networking
git mv modules/aspects/profiles/networking.nix       modules/den/aspects/networking/default.nix

# 8. Move roles
git mv modules/aspects/profiles/server.nix           modules/den/aspects/roles/server.nix

# 9. Move hosts (flatten — no more default.nix nesting)
git mv modules/aspects/hosts/builder/default.nix            modules/den/hosts/builder.nix
git mv modules/aspects/hosts/hvn-hyp1/default.nix           modules/den/hosts/hvn-hyp1.nix
git mv modules/aspects/hosts/daniels-2021-mbp/default.nix   modules/den/hosts/daniels-2021-mbp.nix
git mv modules/aspects/hosts/testvm/default.nix             modules/den/hosts/testvm.nix

# 10. Move defaults + namespace
git mv modules/aspects/default.nix  modules/den/defaults.nix
git mv modules/namespace.nix        modules/den/namespace.nix

# 11. Move nix config options (non-den NixOS module, was at modules/nix/)
# These 5 files set flake-parts options, not den entity data.
# Move them under meta/ or leave as-is — they're already in the flake-parts auto-import path.
# Decision: leave in modules/nix/ since they set global nix options, not den config.

# 12. Create new files (Phase 1-3 artifacts, already created in earlier phases)
# modules/den/aspects/features/ssh-keys.nix
# modules/den/aspects/users/registry.nix
# modules/den/aspects/users/daniel.nix
# modules/den/aspects/users/alice.nix
# modules/den/aspects/groups/default.nix
# modules/den/aspects/quirks/persist.nix

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
# Keep modules/nix/* — they set flake-parts nixConfig, not den entity data

# 15. Regenerate flake
nix run .#write-flake --impure
```

### 4.6 Update All Aspect References

After the file moves and namespace change, update every reference:

| Old reference | New reference |
|---|---|
| `den.aspects."dlab/profile/time"` | `den.aspects.core.time` |
| `den.aspects."dlab/profile/networking"` | `den.aspects.networking.default` |
| `den.aspects."dlab/profile/disks"` | `den.aspects.hardware.disks` |
| `den.aspects."dlab/profile/impermanence"` | `den.aspects.core.impermanence` |
| `den.aspects."dlab/profile/facter"` | `den.aspects.core.facter` |
| `den.aspects."dlab/profile/remote-unlock"` | `den.aspects.core.remote-unlock` |
| `den.aspects."dlab/profile/server"` | `den.aspects.roles.server` |
| `den.aspects."dlab/profile/hypervisor"` | `den.aspects.hardware.hypervisor` |
| `den.aspects."dlab/services/crowdsec"` | `den.aspects.services.crowdsec` |
| `den.aspects."dlab/secrets/sops"` | `den.aspects.secrets.sops` |
| `den.aspects."dlab/secrets/hardcoded"` | `den.aspects.secrets.hardcoded` |

Files that contain references to update:

- `modules/den/defaults.nix` (was `aspects/default.nix`) — `den.schema.host.includes`, `den.default.includes`
- `modules/den/hosts/builder.nix` — `includes` list
- `modules/den/hosts/hvn-hyp1.nix` — `includes` list
- `modules/den/hosts/testvm.nix` — `includes` list
- `modules/den/hosts/daniels-2021-mbp.nix` — `includes` list
- `modules/den/aspects/roles/server.nix` — `includes` reference to crowdsec
- `modules/den/aspects/core/remote-unlock.nix` — any internal aspect references

---

## Phase 5: Policies

**v1 change**: Was implicit/unaddressed in v1. v2 adds a dedicated phase because the group-based user model (Phase 1) requires policy-driven resolution. Policies are how den answers "which users go on which hosts?"

### 5.1 What Policies Are

Policies are functions that resolve entities onto other entities. They run during den's entity resolution phase and produce the final aspect tree for each entity.

Den ships with a default `host-to-users` policy (`modules/policies/core.nix`) that auto-includes user aspects on any host that declares `users.<name>`. This is what makes `den.hosts.*.builder.users.daniel = { }` work: den sees the user declaration in the host entity and auto-includes the `daniel` aspect (and any sub-aspects like `daniel.policies.to-hosts`).

For simple setups (1 user, all hosts), the default policy is sufficient. For the homelab's target scale (3 users with different access rules), explicit policies provide:

1. **Group-based resolution** — "any user in group `vm-access` gets an account on hosts that grant `vm-access`"
2. **No per-host user lists** — you don't manually add `users.alice = { }` to each VM host entity
3. **Single source of truth** — user group membership lives in the user registry, host access grants live on the host entity, policy connects them

### 5.2 Fleet-Demo Policy Reference

The fleet-demo at `~/src/den/templates/fleet-demo/modules/policies/fleet.nix` (98 lines) demonstrates the full policy tree:

```
flake → fleet → environment → host → user
```

| Policy | File | What it does |
|--------|------|-------------|
| `to-fleet` | `fleet.nix` | Creates the fleet entity |
| `fleet-to-envs` | `fleet.nix` | Fans out fleet into environments (dev, prod, etc.) |
| `env-to-hosts` | `fleet.nix` | Resolves which hosts belong to which environment |
| `host-to-users` | `core.nix` (default) | Resolves users on each host |
| `env-users` | `users.nix` | Resolves users by environment group match |
| `host-users` | `users.nix` | Resolves users by host-specific group match |

For the homelab, the relevant policies are:
- `host-to-users` — already exists (den default), handles "daniel goes on every host that declares him"
- `env-users` or `host-users` — new, handles "alice goes on hosts that grant `vm-access` + `developers`"

### 5.3 Host-Users Policy (Group-Based Resolution)

**New file:** `modules/den/policies/users.nix`

```nix
# Group-based user resolution policy.
# Matches users from the registry against host system-access-groups.
# A user gets an account on a host if any of their groups intersect
# the host's system-access-groups.
{ lib, den, config, ... }:
let
  registry = config.den.users.registry or { };

  matchUsers = hostAccessGroups:
    lib.filter (name:
      let userGroups = registry.${name}.groups or [ ];
      in builtins.any (g: lib.elem g hostAccessGroups) userGroups
    ) (builtins.attrNames registry);

in {
  # Replace the default host-to-users policy with group-based resolution.
  # The default policy would auto-include users listed in host.users.*
  # This policy instead resolves users whose groups match host.system-access-groups.
  #
  # To exclude the default policy, we disable it via the schema. The default
  # host-to-users policy is wired in den.schema.host.includes in core.nix,
  # so we need to either override that or use a policy that runs after it.
  #
  # Simpler approach for the homelab: keep the default host-to-users policy
  # (which requires explicit users.<name> on each host) and add host-access-groups
  # as entity data. The policy below runs AFTER default resolution and adds
  # additional users found via group matching.
  den.policies.group-users = { host, ... }:
    let
      accessGroups = host.system-access-groups or [ ];
      matched = matchUsers accessGroups;
      # Exclude the primary user (daniel) who's already resolved by default policy
      additional = lib.subtractLists [ "daniel" ] matched;
    in map (name: den.lib.policy.resolve.to "user" { user = registry.${name}; }) additional;
}
```

**Alternative: Replace the default policy entirely**

```nix
# In modules/den/policies/users.nix, also set:
config.den.schema.host.includes = lib.mkForce [
  # Remove the default host-to-users policy from core.nix
  # and replace with group-based resolution
  den.policies.group-users
];
```

### 5.4 Policy Recommendation for the Homelab

For the homelab's scale (3 users, 5-15 hosts), the simplest approach:

1. **Keep the default `host-to-users` policy** — daniel is declared explicitly on every host entity
2. **Add a group-based supplementary policy** — secondary users are resolved via group intersection
3. **Explicit `users.<name> = { }` on host entities** — acts as documentation of which users are expected

This avoids the complexity of sini's scope-engine/ACL system while still getting the benefits of group-based resolution for secondary users.

Trigger point for upgrading to full fleet-demo policy tree: when you have 5+ secondary users OR when you introduce environment entities (distinct dev/staging/prod environments with different access rules).

---

## Phase 6: Den-Native Refactors

Aspirational. Postpone until Phases 0-5 are deployed and stable.

### 6.1 Dynamic Settings Discovery (sini-inspired) 🐚

Sini's `settingsType` in `schema/host.nix` (lines 195-218) auto-discovers aspects that declare `.settings` and creates a nested submodule type mirroring the aspect tree. This means `host.settings.hardware.disks.backend` has the correct type without any manual wiring.

The homelab's current approach (manually listing settings options on each aspect) works for 4 hosts but becomes tedious at 15+. Adopt the dynamic discovery pattern once the aspect tree stabilizes.

**Reference:** `~/src/den-examples/sini/modules/den/schema/host.nix`

### 6.2 Environment Entities (sini-inspired) 🐚

Sini's environments model domains, networks, and certificates at the environment level. For the homelab, this would mean:

```nix
den.environments.home = {
  domain = "home.vicory.com";
  timezone = "America/Chicago";
  networks.lan.cidr = "192.168.65.0/24";
  settings.hardware.disks.encryption.enable = true;
};
```

Environments cascade defaults to all hosts within them, which eliminates repetition when 10 VMs share the same domain, timezone, and encryption preference. Not needed until you have distinct environments (e.g., "home" vs "lab" vs "edge").

### 6.3 Scope Engine Settings Cascade (sini-inspired) 🐚

Sini's scope engine allows nested settings overrides: environment defaults → host overrides → user overrides. This powers complex configurations where a host inherits environment-level defaults but can override specific values.

**Reference:** `~/src/den-examples/sini/modules/den/scope-engine/`

---

## Migration Reference

| Den Path | Purpose | Phase | Status |
|----------|---------|-------|--------|
| `den.default.nixos` | Global NixOS defaults | — | ✅ SSH, mutableUsers, stateVersion, emergencyAccess |
| `den.default.includes` | Global batteries | 1 | ✅ hostname, define-user, ssh-keys |
| `den.schema.host` | Host entity metadata | 1, 2 | 🔜 Add `system-access-groups`, `settings.*` |
| `den.schema.host.includes` | Auto-applied aspects | — | ✅ core.time, networking.default |
| `den.schema.user` | User entity metadata | 1 | 🔜 Add `identity` submodule, `system.uid` |
| `den.schema.user.isEntity` | Users as real entities | 1 | 🔜 Set to `true` via registry |
| `den.aspects.core.*` | Core system aspects | 4 | 🔜 Renamed from `dlab/profile/*` |
| `den.aspects.hardware.*` | Hardware-specific aspects | 4 | 🔜 Renamed from `dlab/profile/disks`, `hypervisor` |
| `den.aspects.networking.*` | Networking aspects | 4 | 🔜 Renamed from `dlab/profile/networking` |
| `den.aspects.services.crowdsec` | Crowdsec + bouncer | — | ✅ With `provides.bouncer` |
| `den.aspects.secrets.*` | Secret providers | — | ✅ sops + hardcoded |
| `den.aspects.features.ssh-keys` | SSH keys battery | 1 | 🔴 New file to create |
| `den.aspects.roles.server` | Composite server role | 4 | 🔜 Renamed from `dlab/profile/server` |
| `den.aspects.quirks.persist` | Persistence pipe | 3 | 🔴 New file to create |
| `den.users.registry` | User declarations | 1 | 🔴 New file to create |
| `den.groups.*` | Group entities | 1 | 🔴 New file to create |
| `den.policies.group-users` | Group-based user resolution | 5 | 🟡 New file (defer if default policy suffices) |
| `den.batteries.define-user` | User account creation | 1 | ✅ In `den.default.includes` |
| `den.batteries.hostname` | Hostname from entity | — | ✅ In `den.default.includes` |
| `den.batteries.primary-user` | Admin user (wheel+networkmanager) | 1 | 🔜 Added via per-user `includes` |
| `den.batteries.user-shell` | Default shell | 1 | 🔜 Added via per-user `includes` |
| `den.batteries.mutual-provider` | Inert compat shim | 1 | 🟡 Remove from `default.includes` |
| `den.quirks.*` | Cross-aspect data pipes | 3 | 🔴 Not yet adopted |
| `host.hasAspect` | Structural aspect detection | 2 | 🔴 Not yet used (replace null checks) |
| `host.settings.*` | Per-host typed configuration | 2 | 🔴 Not yet adopted |

---

## Cross-Example Findings (9 den users surveyed)

Surveyed: sini, Codys-Wright, talianappin, zakuciael, hydeik, esselius, michaelBelsanti, Paul1365972, and the den example template.

### What everyone agrees on

| Pattern | Used by | Confirmed? |
|---------|---------|:---:|
| Per-file user aspects | All 9 | Yes — users are separate files/namespace entries |
| Per-file host aspects | All 9 | Yes — hosts are separate files |
| `den.default.nixos` for global defaults | All 9 | Yes |
| Batteries for common patterns | All 9 | Yes — `define-user`, `primary-user`, `hostname` |
| File hierarchy by function not type | All 9 | Yes — no one uses `profiles/` naming anymore |

### What's unique to the homelab (re-evaluated for v2)

| Homelab pattern | What everyone else does | v2 Decision |
|-----------------|------------------------|-------------|
| `secretRequests` abstraction | Set `sops.secrets` directly in parametric aspects | Keep — it's a clean provider-agnostic layer. Revisit as quirk if adding third provider. |
| `neededForUsers` on password secrets | Others use `hashedPassword` directly | Keep — SOPS file is more secure than hash in nix store. |
| `den.hosts.*.users.*.sshKeys` entity field | Per-user files with SSH keys declared inline | **Replaced** — SSH keys move to user registry `identity.sshKeys`. Named battery reads them. |

### User model: Group-based (fleet-demo / sini pattern)

**Decision for v2: Group-based user registry (pattern B)**

```nix
# User declares groups in registry
den.users.registry.alice.groups = [ "developers" "vm-access" ];

# Host declares access groups
den.hosts.x86_64-linux.testvm.system-access-groups = [ "admins" "vm-access" "developers" ];

# Policy resolves intersection automatically
# Alice gets an account on testvm because "vm-access" and "developers" overlap
```

**Why not per-user files alone:** While per-user files (pattern A) handle the aspect declaration side, group-based resolution eliminates the need to manually list `users.<name> = { }` on every host entity. For 3 users across 5-15 hosts with different access rules, this is the difference between "add a user to 2 groups in the registry" and "add `users.alice = { }` to 8 different host entities."

**Trigger point for upgrading:** When you need different access levels within the same group (e.g., "developers can SSH but not sudo"), add sini's scope-engine/ACL pattern.

---

## Den Source & Examples Guide

| Location | What's There |
|----------|--------------|
| `~/src/den/modules/aspects/batteries/*.nix` | Battery implementations (primary-user, define-user, user-shell, hostname) |
| `~/src/den/modules/policies/core.nix` | Default host-to-users resolution policy |
| `~/src/den/modules/compat/mutual-provider-shim.nix` | Inert compat shim (cross-entity routing is now built-in) |
| `~/src/den/templates/example/modules/aspects/alice.nix` | Per-user aspect with batteries + cross-scope policy |
| `~/src/den/templates/example/modules/aspects/hasAspect-examples.nix` | `hasAspect` + `oneOfAspects` worked examples (141 lines) |
| `~/src/den/templates/example/modules/aspects/defaults.nix` | Global defaults with scope guard warnings |
| `~/src/den/templates/example/modules/aspects/igloo.nix` | Host aspect with cross-scope user policy |
| `~/src/den/templates/fleet-demo/modules/aspects/users/ssh-keys.nix` | SSH keys as a formal battery (23 lines) |
| `~/src/den/templates/fleet-demo/modules/users.nix` | User registry with group-based resolution (139 lines) |
| `~/src/den/templates/fleet-demo/modules/policies/fleet.nix` | Policy-driven entity topology (98 lines) |
| `~/src/den-examples/sini/modules/den/users/sini.nix` | User registry entry with rich schema |
| `~/src/den-examples/sini/modules/den/policies/users.nix` | Full user registry type + ACL policies (120 lines) |
| `~/src/den-examples/sini/modules/den/quirks/impermanence.nix` | Quirk-based persist directory collection |
| `~/src/den-examples/sini/modules/den/schema/host.nix` | Advanced host schema (channels, interfaces, settings, dynamic settingsType) |
| `~/src/den-examples/sini/modules/den/schema/environment.nix` | Environment entity schema (networks, certificates, domains) |
| `~/src/den-examples/sini/modules/den/schema/user.nix` | Extended user schema (identity, system, SSH keys) |
| `~/src/den-examples/sini/modules/den/policies/fleet.nix` | Full policy tree with environments |

---

## Concept Deep-Dives

### hasAspect: When and Why

**The 95% case — Reading:** Use `host.hasAspect` inside NixOS/Darwin/HomeManager bodies to branch on whether a companion aspect is structurally present on the same host. Cycle-safe because the body evaluates at `evalModules` time, after the aspect tree is frozen.

```nix
# ✅ Correct: inside a class body
den.aspects.core.impermanence = { host, ... }: {
  nixos = { lib, ... }:
    lib.mkIf (host.hasAspect den.aspects.hardware.disks) {
      # disk-aware impermanence config
    };
};
```

**The 5% case — Writing:** Use `meta.handleWith` and fx constraints (`exclude`, `substitute`, `filter`) to decide which aspects belong in the tree at resolution time.

```nix
# ✅ Correct: structural decision at meta level
den.aspects.secrets-bundle = {
  includes = [ den.aspects.secrets.sops den.aspects.secrets.agenix ];
  meta.handleWith = den.lib.aspects.fx.constraints.exclude den.aspects.secrets.agenix;
};
```

**Anti-pattern — Never use `hasAspect` in `includes`:**

```nix
# ❌ INFINITE RECURSION: includes depends on resolved tree which depends on includes
den.aspects.broken = { host, ... }: {
  includes = if host.hasAspect den.aspects.foo then [ ... ] else [ ... ];
};
```

**Reference:** `~/src/den/templates/example/modules/aspects/hasAspect-examples.nix` (141 lines)

### Quirks vs. NixOS Options

| Concern | NixOS Option | Den Quirk |
|---------|-------------|-----------|
| Declaration | `mkOption` in a module's `options` block | `den.quirks.<name> = { type, description, default }` |
| Emission | `config.<option> = [ value ]` (merge semantics) | `pipe.<quirkName> = [ value ]` (collect semantics) |
| Collection | `config.<option>` (same namespace as emission) | Collector reads the assembled pipe (separation of emit/collect) |
| Composability | Modules must know the option name and module path | Aspects reference the quirk by name, no module coupling |
| Tool discoverability | Requires NixOS option search | Quirks are in the den namespace, inspectable via `den.quirks` |

**When to use a quirk:**
- Multiple independent aspects contribute to the same collection (persist directories, firewall rules, system packages)
- The collector aspect should not need to import every contributor module
- The data has structure (typed submodules with validation)

**When to use a NixOS option:**
- Single aspect, single consumer
- The data is flat (list of strings, single value)
- You'll migrate to a quirk later when the pattern proves itself

### Settings: The Value Proposition

Settings transform aspects from "code that does things" to "self-documenting modules that hosts configure." Without settings:

```nix
# Host has no way to say "don't use ZFS on me" without editing the aspect
den.hosts.x86_64-linux.testvm = { zfs.rootPool = null; };  # implicit: null = skip
```

With settings:

```nix
# Host explicitly declares intent
den.hosts.x86_64-linux.testvm = {
  settings.hardware.disks = { backend = "ext4"; swap.size = "4G"; };
};

# Aspect reads settings, not raw entity fields
den.aspects.hardware.disks = { host, ... }: {
  nixos = { lib, ... }: let
    s = host.settings.hardware.disks;
  in ...
};
```

This means:
- **Adding a host** with different requirements never requires editing aspect code
- **Discovering what an aspect accepts** is a tool query (`nixos-option den.aspects.hardware.disks.settings`), not a code search
- **Validation** happens at the option level, with proper error messages
- **Defaults** are owned by the aspect, not duplicated across host entities

### Policy Resolution Flow

```
          ┌─────────┐
          │  Flake  │
          └────┬────┘
               │ to-fleet policy
          ┌────▼────┐
          │  Fleet  │
          └────┬────┘
               │ fleet-to-envs policy         (skip if no environments)
          ┌────▼────────┐
          │ Environments │
          └────┬────────┘
               │ env-to-hosts policy
          ┌────▼────┐
          │  Hosts  │
          └────┬────┘
               │ host-to-users OR group-users policy
          ┌────▼────┐
          │  Users  │
          └─────────┘
```

For the homelab, the tree is:

```
Flake → Hosts (auto-resolved from den.hosts.*)
         → Users: default host-to-users (daniel is explicit on each host)
                 + group-users (alice, bob resolved by group intersection)
```

No fleet or environment entities needed at current scale.

---

## Quick Start

1. **Phase 0** — fix bugs, deploy immediately
2. **Phase 1** — parametric users, groups, SSH keys battery, remove hardcoded user
3. **Phase 2** — add settings to aspects, replace null checks with `hasAspect`
4. **Phase 3** — declare quirks, migrate `persist.directories` to `pipe.persist`
5. **Phase 4** — file moves, namespace `true`, `nix run .#write-flake --impure`, verify builds
6. **Phase 5** — group-based user resolution policy (if needed before Phase 4 deploy)
7. **Phase 6** — aspirational
