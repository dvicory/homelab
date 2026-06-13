# Den Migration v4: Audit, Roadmap & Concepts

Pre-den baseline: `eea36b4^` (before "Initial den migration")
v3 baseline: `docs/den-migration-v3.md` (superseded)

---

## Contents

- [What Changed from v3](#what-changed-from-v3)
- [Fork Dependency Map](#fork-dependency-map)
- [How `den.schema.host` Function + `.includes` Coexist](#how-denschemahost-function--includes-coexist)
- [Phase 0: Fix Regressions](#phase-0-fix-regressions)
- [Phase 1: User & Group Model](#phase-1-user--group-model)
- [Phase 2: Settings on Aspects](#phase-2-settings-on-aspects)
- [Phase 3: Quirks](#phase-3-quirks)
- [Phase 4: Rename & Reorganize](#phase-4-rename--reorganize)
- [Phase 5: Policies](#phase-5-policies)
- [Phase 6: Den-Native Refactors](#phase-6-den-native-refactors)
- [Host Directory Structure](#host-directory-structure)
- [Migration Reference](#migration-reference)
- [Den Source & Examples Guide](#den-source--examples-guide)
- [Concept Deep-Dives](#concept-deep-dives)
- [Verification Guidelines](#verification-guidelines)

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

## What Changed from v3

**Host data files co-located.** v3 moved entity aspect files but left host data (`secrets.yaml`, `facter.json`, `ssh.pub`, `known_hosts`, host keys) stranded in `modules/hosts/`. v4 adopts per-host folders under `modules/den/hosts/<name>/` containing both the entity+aspect file (`default.nix`) and all data files. This eliminates fragile relative-path calculations in SOPS and facter config: both use `../../hosts/<name>/...` which works identically from the old and new file locations.

**Mergerfs as a den aspect.** `modules/storage/mergerfs.nix` (228 lines) is a non-den NixOS module using the old `dlab.storage.mergerfs` option path. v4 converts it to `den.aspects.services.mergerfs` with a `provides` sub-aspect for branch watching. This eliminates the last remaining `dlab.*` NixOS option prefix outside the den entity system.

**Schema function pattern explained.** v3 used `den.schema.host = { host, lib, ... }: { options = ...; }` (function pattern) and `den.schema.host.includes = [ ... ]` (attribute pattern) in separate modules without explaining how they coexist. v4 documents the mechanism: `den.schema` is a `lib.types.submodule` with `freeformType = lib.types.lazyAttrsOf lib.types.deferredModule`. The function is stored as the deferred module value, while `.includes` and `.imports` are data attributes on the same submodule. Both coexist because of lazy freeform merging.

**Verification guidelines appendix.** Each phase now has a `verify` step: the specific command and expected result to confirm the phase is correct before proceeding to the next phase.

**`shared/secrets.yaml` documented.** The CrowdSec enrollment key lives in `shared/secrets.yaml` at the repo root. It's explicitly noted as out-of-scope for this migration but acknowledged for completeness.

**Nix config refactored as den aspect (sini pattern).** Phase 0.1 converts `modules/aspects/nix/default.nix` from `den.default.nixos` to `den.aspects.core.nix` using `os`/`nixos`/`darwin` class bodies. GC becomes a per-host settings option (`settings.core.nix.gc.enable`, default `true`). Builder disables it. Also incorporates sini's daemon scheduling and OOM prevention patterns.

**Verification uses local eval + deploy prompt model.** I run `nix flake check` and `nix eval` locally, then prompt you to deploy. The appendix provides a per-phase commit+deploy table and deploy order.

---

## Fork Dependency Map

| Feature | Dependency | Status in homelab |
|---|---|---|
| Quirks (`pipe.*`, `den.quirks.*`, collectors) | ✅ Core den | Used in Phase 3 |
| `den.schema.*.includes` / `excludes` | ✅ Core den | Used in Phases 1, 3, 5 |
| `den.lib.policy.mkPolicy`, `.include`, `.provide`, `.resolve.to` | ✅ Core den | Used in Phases 1, 5 |
| `host.hasAspect` | ✅ Core den | Used in Phase 2 |
| `os` class shorthand | ✅ Core den | Used in Phase 2 |
| Manual settings on `den.schema.host` (function pattern) | ✅ Core den | Used in Phase 2 |
| Schema function + `.includes` coexistence | ✅ Core den | See [How `den.schema.host`...](#how-denschemahost-function--includes-coexist) |
| `den.reservedKeys` | ❌ Fork only | Not needed — skip `den.quirks.settings` |
| Dynamic `settingsType` auto-discovery | ❌ Fork only | Phase 6 gated |
| `scope-engine` settings cascade | ❌ Fork only | Phase 6 gated |
| `scope-engine` ACL | ❌ Fork only | Not needed |
| `gen-schema` methods/refs | ❌ Fork only | Blocks environment entities |
| `gen.mkValidator` | ❌ Fork only | Not essential |
| `den.lib.policy.instantiate` | ❌ Fork only | Homelab uses manual `nix/den.nix` output bridge |

**Bottom line:** Every actionable phase (0-5) uses core den features only. Phase 6 is aspirational and gated on the fork merging into mainline `github:denful/den`.

---

## How `den.schema.host` Function + `.includes` Coexist

The homelab uses two patterns on `den.schema.host` from different modules:

```nix
# modules/den/schema/host.nix
den.schema.host = { host, lib, ... }: {
  options.zfs = { ... };
  options.networking = { ... };
};
```

```nix
# modules/den/defaults.nix
den.schema.host.includes = [
  den.aspects.core.time
  den.aspects.networking.default
];
```

This works because `den.schema` is declared by the den framework as a `lib.types.submodule` with `freeformType = lib.types.lazyAttrsOf lib.types.deferredModule` (`namespace-types.nix:13`). Each entity kind key (e.g., `host`, `user`) is a lazy submodule entry.

- The function `{ host, lib, ... }: { options = ...; }` is stored as the **deferred module value** for the `host` submodule entry. It's later passed to the entity submodule via `imports = [ den.schema.host ]` (`entities/host.nix:31`).
- `.includes` and `.imports` are **data attributes** on the same submodule entry, read by den's entity resolution layer (`resolve-entity.nix:21-22`).

Because both live under the same lazy submodule key, Nix's module system merges them without conflict: the function is the submodule value, and `.includes`/`.imports` are freeform attributes. No special merge logic is needed — this is standard NixOS submodule behavior.

For `den.schema.user`, use the same pattern:

```nix
# modules/den/schema/user.nix
den.schema.user = { user, ... }: {
  imports = [
    (_: {
      options.identity = { ... };
      options.system = { ... };
    })
  ];
};
```

```nix
# modules/den/defaults.nix
den.schema.user.includes = [
  den.aspects.core.resolved-user-emitter
  (den.lib.policy.mkPolicy "user-aspect-auto-include" { ... })
];
```

---

## Phase 0: Fix Regressions

Fix and deploy immediately.

### 0.1 Nix Config: Convert to Den Aspect + GC as Setting (sini pattern) 🐚

**Current problem:** The nix daemon config lives in `den.default.nixos` at `modules/aspects/nix/default.nix` — the same anti-pattern as the hardcoded user. GC is commented out entirely. sini's approach (`modules/den/aspects/core/nix.nix`, 111 lines) uses a proper den aspect with `os`/`nixos`/`darwin` class bodies, platform-specific config, and OOM prevention via systemd slices.

**Target:** Convert to `den.aspects.core.nix` with GC controlled by a settings option. GC defaults `true` per host; builder disables it.

**File:** `modules/aspects/nix/default.nix` — replace entire file:

```nix
{ lib, config, ... }: {
  den.aspects.core.nix = {
    # Platform-agnostic: both NixOS and Darwin
    os = {
      nix.settings = {
        experimental-features = [ "nix-command" "flakes" ];
        substituters = [
          "https://cache.nixos.org/"
          "https://nix-community.cachix.org"
          "https://cache.garnix.io"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        ];
        connect-timeout = 5;
        log-lines = 50;
        min-free = 128000000;
        max-free = 1000000000;
        download-buffer-size = 524288000;
        auto-optimise-store = true;
        builders-use-substitutes = true;
        fallback = true;
        keep-outputs = true;
        keep-derivations = true;
      };

      nix.gc = lib.mkIf config.settings.core.nix.gc.enable {
        automatic = true;
        options = "--delete-older-than 14d";
      };
    };

    # NixOS-only: trusted users, daemon scheduling, OOM prevention
    nixos = _: {
      nix = {
        settings = {
          trusted-users = [ "root" "@wheel" ];
          allowed-users = [ "root" "@wheel" ];
        };
        gc.dates = "05:00";
        daemonCPUSchedPolicy = lib.mkDefault "batch";
        daemonIOSchedClass = lib.mkDefault "idle";
        daemonIOSchedPriority = lib.mkDefault 7;
      };

      systemd = {
        slices."nix-daemon".sliceConfig = {
          ManagedOOMMemoryPressure = "kill";
          ManagedOOMMemoryPressureLimit = "50%";
        };
        services."nix-daemon".serviceConfig = {
          Slice = "nix-daemon.slice";
          OOMScoreAdjust = lib.mkDefault 250;
        };
        services.nix-gc.serviceConfig = {
          CPUSchedulingPolicy = "batch";
          IOSchedulingClass = "idle";
          IOSchedulingPriority = 7;
        };
      };
    };

    # Darwin-only: macOS uses @admin group + interval scheduling
    darwin = {
      nix.settings = {
        trusted-users = [ "root" "@admin" ];
        allowed-users = [ "root" "@admin" ];
      };
      nix.gc.interval = { Hour = 5; Minute = 0; };
    };
  };

  # GC toggle: default on for all hosts. Builder disables in its entity data.
  den.schema.host.options.settings.core.nix.gc.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable automatic nix store garbage collection";
  };

  # Unfree package allowlist (migrated from old location)
  den.schema.host.options.nix.allowedUnfree = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
  };
}
```

**File:** `modules/den/hosts/builder/default.nix` — add:

```nix
den.hosts.aarch64-linux.builder = {
  settings.core.nix.gc.enable = false;
  # ... existing entity data
};
```

**Commit:**

```
fix: convert nix config to den aspect with GC as per-host setting

Replace den.default.nixos nix config with den.aspects.core.nix.
Adopts sini patterns: os class for cross-platform defaults,
nixos class for Linux-specific daemon scheduling and OOM prevention,
darwin class for macOS trusted users.

GC is now a settings option (default true). Builder disables it
because its small disk is managed via impermanence rollbacks.

New settings path: settings.core.nix.gc.enable
```

**Deploy:** `deploy .#builder -- --impure` then any other host. GC timer should be inactive on builder, active elsewhere.

---

### 0.2 Missing base packages + vim

**File:** `modules/aspects/default.nix`

Add to the NixOS section under `config`:

```nix
environment.systemPackages = with pkgs; [ bottom lnav git ];
programs.vim.enable = lib.mkDefault true;
```

**Commit:**

```
fix: restore missing base packages and vim from pre-den config

git, bottom, lnav were in old profiles/base.nix but never migrated.
vim was lib.mkDefault true.
```

**Deploy:** `deploy .#builder -- --impure` and verify packages installed.

---

### 0.3 Chrony persist directories missing `user`/`group`

**File:** `modules/aspects/profiles/time.nix:52-55`

```nix
persist.directories = [
  { directory = config.services.chrony.directory; inherit user group; }
  { directory = logDir; inherit user group; }
];
```

**Commit:**

```
fix(chrony): add user/group ownership to persist directories

Without this chrony can't write logs or drift files because
persist directories default to root ownership.
```

**Deploy:** `deploy .#builder -- --impure` and verify chrony directory ownership.

---

### 0.4 Initrd `extraBin` missing

**File:** `modules/aspects/profiles/remote-unlock.nix`

```nix
boot.initrd.systemd.extraBin = {
  ping = "${pkgs.iputils}/bin/ping";
  trip  = "${pkgs.trippy}/bin/trip";
  ip    = "${pkgs.iproute2}/bin/ip";
  vi    = "${pkgs.vim}/bin/vi";
};
```

**Commit:**

```
fix(remote-unlock): restore initrd debugging tools

ping, trip, ip, and vi were in old initrd extraBin but never
migrated to the den aspect. Required for SSH unlock troubleshooting.
```

**Deploy:** `deploy .#hvn-hyp1 -- --impure` and verify initrd tools are present after reboot.

---

### 0.5 MergerFS not wired for hvn-hyp1

**File:** `modules/aspects/hosts/hvn-hyp1/default.nix`

Add the mergerfs config block. The mergerfs module will be converted to a den aspect in Phase 4, but for Phase 0, use the existing NixOS module at `modules/storage/mergerfs.nix`:

```nix
den.aspects.hvn-hyp1.nixos = { config, ... }: {
  imports = [ ../../../storage/mergerfs.nix ];
  dlab.storage.mergerfs."/mnt/storage/media" = {
    branches = [
      "/mnt/storage-clear/media1"
      "/mnt/storage-clear/media3"
    ];
  };
};
```

**Commit:**

```
fix(hvn-hyp1): wire mergerfs storage pool

mergerfs module existed but was never included in the hvn-hyp1
den aspect after migration. Adds /mnt/storage/media pool.
```

**Deploy:** `deploy .#hvn-hyp1 -- --impure` and verify mergerfs pool mounts.

---

## Phase 1: User & Group Model

No fork dependencies. All core den.

### 1.1 Target: Users

| User | Groups | Access |
|------|--------|--------|
| `daniel` | `admins`, `system-access` | Every host |
| `alice` | `developers`, `vm-access` | VMs only |
| `bob` | `services`, `vm-access` | Service VMs |

### 1.2 Group Entities

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

### 1.3 Extend Host Schema

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

### 1.4 Extend User Schema

**File:** `modules/schema/user.nix`:

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
              options.uid = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
            };
            default = { };
          };
        };
      })
    ];
  };
}
```

### 1.5 User Registry

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
  config.den.schema.user.isEntity = true;
}
```

### 1.6 Per-User Aspect: daniel

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

### 1.7 Per-User Aspect: alice

**New file:** `modules/aspects/users/alice.nix` (same pattern, groups `[ "developers" "vm-access" ]`)

### 1.8 Resolved User Emitter Quirk (sini pattern) 🐚

**New file:** `modules/aspects/core/resolved-user-emitter.nix`

```nix
_: {
  den.aspects.core.resolved-user-emitter = {
    resolved-users = { user, ... }: {
      name = user.name;
      uid = user.system.uid or null;
      groups = user.groups or [ ];
      sshKeys = map (k: k.key) (user.identity.sshKeys or [ ]);
    };
  };
}
```

### 1.9 Auto-Include Policy (sini pattern) 🐚

**File:** `modules/aspects/default.nix` — add:

```nix
den.schema.user.includes = [
  den.aspects.core.resolved-user-emitter

  (den.lib.policy.mkPolicy "user-aspect-auto-include"
    ({ host, user, ... }:
      lib.optional
        (den.aspects ? ${host.name} && den.aspects.${host.name} ? ${user.name})
        (den.lib.policy.include den.aspects.${host.name}.${user.name})
    )
  )
];
```

### 1.10 Named SSH Keys Battery (fleet-demo pattern) 🛡

**New file:** `modules/aspects/features/ssh-keys.nix`

```nix
{ lib, ... }: {
  den.aspects.features.ssh-keys = { host, user, ... }: {
    os = lib.mkIf (user ? identity.sshKeys && user.identity.sshKeys != []) {
      users.users.${user.userName}.openssh.authorizedKeys.keys =
        map (entry: entry.key) user.identity.sshKeys;
    };
  };
}
```

### 1.11 Update `den.default.includes`

**File:** `modules/aspects/default.nix`

```nix
den.default.includes = [
  den.batteries.hostname
  den.batteries.define-user
  den.aspects.features.ssh-keys
];
# den.batteries.mutual-provider removed — inert compat shim
```

### 1.12 Remove Hardcoded User

**File:** `modules/aspects/default.nix` — delete:
- `users.users.daniel` block
- `secretRequests."users/daniel/hashedPassword"` entry

### 1.13 Update Host Entity Data

```nix
den.hosts.x86_64-linux.hvn-hyp1 = {
  system-access-groups = [ "admins" "system-access" ];
  # users implicitly resolved by group-users policy (Phase 5)
};

den.hosts.x86_64-linux.testvm = {
  system-access-groups = [ "admins" "vm-access" "developers" "services" ];
};
```

### 1.14 Phase 1 Verify

```bash
nix flake check
nix eval .#nixosConfigurations.builder.config.users.users.daniel.isNormalUser
```

**Commit:**

```
feat: parametric user model with group registry and ssh-keys battery

Per-user aspect files (daniel, alice) with cross-scope to-hosts policy.
Group entities with access semantics. User registry with identity/sshKeys.
Resolved-user-emitter quirk (sini pattern). Auto-include policy for
den.aspects.<host>.<user> sub-aspects.

Removes hardcoded users.users.daniel from den.default.nixos.
GC now controlled by settings.core.nix.gc.enable (default true).
```

**Deploy:** `deploy .#builder -- --impure` to verify daniel still resolves.

---

## Phase 2: Settings on Aspects

No fork dependencies. Manual settings via schema function pattern.

### 2.1 Declare Settings on Host Schema

**File:** `modules/schema/host.nix` — add settings submodule:

```nix
den.schema.host = { host, lib, ... }: {
  options.zfs = { /* ... existing ... */ };
  options.networking = { /* ... existing ... */ };
  options.system-access-groups = { /* ... Phase 1 ... */ };

  options.settings = lib.mkOption {
    type = lib.types.submodule {
      options = {
        disk.backend = lib.mkOption {
          type = lib.types.enum [ "zfs" "ext4" ];
          default = "zfs";
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

### 2.2 `hasAspect` Replacements

Replace `host.zfs.rootPool != null` checks with `host.hasAspect`:

```nix
# Before (impermanence.nix)
nixos = lib.mkIf (host.zfs.rootPool != null) { ... };

# After
den.aspects.core.impermanence = { host, ... }: {
  nixos = { lib, ... }:
    lib.mkIf (host.hasAspect den.aspects.disk.zfs) {
      # ZFS rollback service
    };
};
```

### 2.3 Phase 2 Verify

```bash
nix flake check
nix eval .#nixosConfigurations.testvm.config.settings
```

**Commit:**

```
feat: add per-host settings with hasAspect replacements

Manual settings on den.schema.host covering disk, networking,
hypervisor, time, impermanence, and remote-unlock options.
Replaces host.zfs.rootPool != null with host.hasAspect checks.
Adopts os class shorthand in ssh-keys and nix aspects.
```

**Deploy:** `deploy .#builder -- --impure` and `deploy .#testvm -- --impure` to verify settings resolve.

---

## Phase 3: Quirks

No fork dependencies. All pipe mechanics are core den (`key-classification.nix:41` — `pipeRegistry = den.quirks or { }`).

### 3.1 Declare Quirk Types

**New file:** `modules/aspects/quirks/persist.nix`

```nix
{ lib, ... }: {
  den.quirks.persist = {
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

  den.quirks.persistHome = {
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

  den.quirks.cache = {
    description = "Cache directories (host-scoped, separate wipe semantics)";
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

  den.quirks.firewall = {
    description = "Firewall rules collected from aspects";
    type = lib.types.listOf lib.types.raw;
    default = [ ];
  };

  den.quirks.resolved-users = {
    description = "Resolved user metadata from user scope";
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

### 3.2 Update Aspects to Emit into Quirks

**File:** `modules/aspects/profiles/hypervisor.nix`

```nix
# Before
persist.directories = [{ directory = "/var/lib/incus"; }];

# After
pipe.persist = [
  { directory = "/var/lib/incus"; user = "incus"; group = "incus"; }
];
```

**File:** `modules/aspects/profiles/time.nix`

```nix
pipe.persist = [
  { directory = config.services.chrony.directory; user = chrony; group = chrony; }
  { directory = logDir; user = chrony; group = chrony; }
];
```

### 3.3 Collector Aspects

**New file:** `modules/aspects/core/persist-collector.nix`

```nix
_: {
  den.aspects.core.persist-collector = {
    nixos = { persist, cache, lib, ... }:
      let
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
    nixos = { firewall, lib, ... }: lib.mkMerge firewall;
  };
}
```

### 3.4 Wire Collectors

**File:** `modules/aspects/default.nix` — add to `den.schema.host.includes`:

```nix
den.schema.host.includes = [
  den.aspects."dlab/profile/time"
  den.aspects."dlab/profile/networking"
  den.aspects.core.persist-collector
  den.aspects.core.firewall-collector
];
```

### 3.5 Remove the NixOS Option

**File:** `modules/aspects/default.nix` — delete `options.persist.directories`.

### 3.6 Phase 3 Verify

```bash
nix flake check
nix eval .#nixosConfigurations.builder.config.environment.persistence."/persist".directories
```

**Commit:**

```
feat: adopt den quirks for persist, firewall, and resolved-users

Replaces the bespoke persist.directories NixOS option with typed
quirks (persist, persistHome, cache, firewall, resolved-users).
Collector aspects (persist-collector, firewall-collector) wired
via den.schema.host.includes. Aspects emit into pipe.* instead of
setting config.persist.directories directly.
```

**Deploy:** `deploy .#builder -- --impure` to verify quirk pipes collect correctly.

---

## Phase 4: Rename & Reorganize

### 4.1 Host Directory Structure

Per-host folders under `modules/den/hosts/<name>/` containing both the entity+aspect file and data files:

```
modules/den/hosts/
  builder/
    default.nix          ← den.hosts.aarch64-linux.builder + den.aspects.builder
    secrets.yaml          ← SOPS encrypted secrets
    facter.json           ← nixos-facter hardware report
    ssh.pub               ← user SSH public key
    known_hosts           ← SSH host keys for deploy-rs
    boot_host_key.pub     ← initrd SSH host key
    runtime_host_key.pub  ← runtime SSH host key
  hvn-hyp1/
    default.nix
    secrets.yaml
    facter.json
    known_hosts
    boot_host_key.pub
    runtime_host_key.pub
    ssh.pub
  testvm/
    default.nix
    secrets.yaml
  daniels-2021-mbp/
    default.nix
```

**Why co-located:** Entity definition, aspect configuration, secrets, and hardware report all live together. The SOPS path in `secrets/sops.nix` uses `../../hosts/<hostName>/secrets.yaml` relative to the sops file, which resolves to the host's data directory regardless of whether the sops file is at the old or new location. Same for facter path.

### 4.2 MergerFS as a Den Aspect

Convert `modules/storage/mergerfs.nix` (228 lines, non-den NixOS module with `options.dlab.storage.mergerfs`) to a den aspect:

**New file:** `modules/den/aspects/services/mergerfs.nix`

```nix
{ lib, pkgs, config, ... }: {
  den.aspects.services.mergerfs.settings = {
    options.pools = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          branches = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Mount paths to merge";
          };
          options = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "allow_other" ];
          };
          depends = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
        };
      });
      default = { };
      description = "MergerFS pool definitions";
    };
  };

  den.aspects.services.mergerfs = {
    nixos = { config, pkgs, lib, ... }: let
      cfg = config.mergerfs;
      escapeSystemdPath = path:
        lib.strings.sanitizeDerivationName (builtins.substring 1 (-1) path);
    in {
      options.mergerfs = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            branches = lib.mkOption { type = lib.types.listOf lib.types.str; };
            options = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "allow_other" ]; };
            depends = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          };
        });
        default = { };
      };

      config = lib.mkIf (cfg != { }) (lib.mkMerge [
        {
          environment.systemPackages = [ pkgs.mergerfs pkgs.attr ];
          boot.supportedFilesystems = [ "fuse" "fuse.mergerfs" ];
        }
        {
          environment.etc = lib.mapAttrs' (path: poolCfg:
            let
              escapedPath = escapeSystemdPath path;
              branchString = lib.concatStringsSep ":" poolCfg.branches;
              optionsString = lib.concatStringsSep "," poolCfg.options;
            in lib.nameValuePair "mergerfs/${escapedPath}.conf" {
              text = ''
                PATH=${path}
                BRANCHES=${branchString}
                OPTIONS=${optionsString}
              '';
            }
          ) cfg;
        }
        # ... (rest of mergerfs systemd service definitions from original module)
      ]);
    };
  };
}
```

Then in `modules/den/hosts/hvn-hyp1/default.nix`:

```nix
den.aspects.hvn-hyp1 = {
  includes = with den.aspects; [
    core.time
    core.facter
    core.impermanence
    hardware.hypervisor
    disk.zfs
    roles.server
    core.remote-unlock
    services.mergerfs    # ← den aspect instead of NixOS import
  ];
  nixos = { config, ... }: {
    mergerfs."/mnt/storage/media" = {
      branches = [ "/mnt/storage-clear/media1" "/mnt/storage-clear/media3" ];
    };
  };
};
```

Note: Converting mergerfs to an aspect introduces a new NixOS option prefix (`options.mergerfs`). The old `dlab.storage.mergerfs` prefix is eliminated. The `dlab` namespace (set via `inputs.den.namespace "dlab" true`) only affects den aspect names, not NixOS option prefixes — these are independent namespaces.

### 4.3 Enable Short Names

**File:** `modules/namespace.nix`:

```nix
{ inputs, ... }:
{
  imports = [ (inputs.den.namespace "dlab" true) ];  # true = flake-exposed, short names
}
```

### 4.4 Target Directory Structure

```
modules/
  den/
    defaults.nix                     ← den.default + schema includes + collectors
    flake-parts.nix                  ← den integration + output bridge
    namespace.nix                    ← namespace declaration
    schema/
      host.nix                       ← zfs, networking, system-access-groups, settings
      user.nix                       ← identity, system, classes
    aspects/
      core/
        time.nix
        nix.nix
        ssh.nix
        sudo.nix
        facter.nix
        impermanence.nix
        remote-unlock.nix
        resolved-user-emitter.nix
        persist-collector.nix
        firewall-collector.nix
      features/
        ssh-keys.nix
      secrets/
        sops.nix
        hardcoded.nix
      services/
        crowdsec.nix
        mergerfs.nix
      disk/
        zfs.nix
        ext4.nix
      hardware/
        hypervisor.nix
      networking/
        default.nix
      roles/
        server.nix
        vm.nix
      users/
        registry.nix
        daniel.nix
        alice.nix
      groups/
        default.nix
      quirks/
        persist.nix
    hosts/
      builder/
        default.nix
        secrets.yaml
        facter.json
        ssh.pub
        known_hosts
        boot_host_key.pub
        runtime_host_key.pub
      hvn-hyp1/
        default.nix
        secrets.yaml
        facter.json
        ssh.pub
        known_hosts
        boot_host_key.pub
        runtime_host_key.pub
      testvm/
        default.nix
        secrets.yaml
      daniels-2021-mbp/
        default.nix
    policies/
      users.nix

  meta/                              ← flake-parts modules (unchanged)
    flake-parts.nix
    inputs.nix
    pkgs.nix
    systems.nix

  flake/
    deploy-rs.nix
    formatter.nix
    sops.nix

  nix/
    den.nix                          ← manual output bridge
    caches.nix
    flakes.nix
    optimise.nix
    sensible.nix
    unfree.nix

  packages/
    initrd.nix
    install-on-envoy.nix

  storage/                           ← EMPTY after mergerfs moved to den aspect
    # (mergerfs.nix moved to modules/den/aspects/services/mergerfs.nix)

  tests/
    default.nix
```

### 4.5 Aspect Name Map

| Current | Target | Category |
|---------|--------|----------|
| `den.aspects."dlab/profile/time"` | `den.aspects.core.time` | core |
| `den.aspects."dlab/profile/networking"` | `den.aspects.networking.default` | networking |
| `den.aspects."dlab/profile/impermanence"` | `den.aspects.core.impermanence` | core |
| `den.aspects."dlab/profile/disks"` | `den.aspects.disk.zfs` (extracted) + `den.aspects.disk.ext4` (new) | disk |
| `den.aspects."dlab/profile/hypervisor"` | `den.aspects.hardware.hypervisor` | hardware |
| `den.aspects."dlab/profile/facter"` | `den.aspects.core.facter` | core |
| `den.aspects."dlab/profile/remote-unlock"` | `den.aspects.core.remote-unlock` | core |
| `den.aspects."dlab/profile/server"` | `den.aspects.roles.server` | roles |
| `den.aspects."dlab/services/crowdsec"` | `den.aspects.services.crowdsec` | services |
| `den.aspects."dlab/secrets/sops"` | `den.aspects.secrets.sops` | secrets |
| `den.aspects."dlab/secrets/hardcoded"` | `den.aspects.secrets.hardcoded` | secrets |
| `modules/aspects/nix/default.nix` | `den.aspects.core.nix` | core |
| `modules/security/sudo.nix` | `den.aspects.core.sudo` | core |
| `modules/storage/mergerfs.nix` | `den.aspects.services.mergerfs` | services |
| Host aspect `den.aspects.builder` | `den.aspects.builder` (same, uses short name) | hosts |

### 4.6 Migration Steps

```bash
# 1. Create new directory tree
mkdir -p modules/den/aspects/{core,features,secrets,services,disk,hardware,networking,roles,users,groups,quirks}
mkdir -p modules/den/{hosts,schema,policies}
mkdir -p modules/den/hosts/{builder,hvn-hyp1,testvm,daniels-2021-mbp}

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
git mv modules/storage/mergerfs.nix                 modules/den/aspects/services/mergerfs.nix

# 6. Move disk (split from profiles/disks.nix)
#    Create disk/zfs.nix and disk/ext4.nix as NEW files with extracted content.
#    After verification, remove the old monolithic file:
git rm modules/aspects/profiles/disks.nix

# 7. Move hardware
git mv modules/aspects/profiles/hypervisor.nix      modules/den/aspects/hardware/hypervisor.nix

# 8. Move networking
git mv modules/aspects/profiles/networking.nix       modules/den/aspects/networking/default.nix

# 9. Move roles
git mv modules/aspects/profiles/server.nix           modules/den/aspects/roles/server.nix

# 10. Move host entity files (to per-host folders)
git mv modules/aspects/hosts/builder/default.nix            modules/den/hosts/builder/default.nix
git mv modules/aspects/hosts/hvn-hyp1/default.nix           modules/den/hosts/hvn-hyp1/default.nix
git mv modules/aspects/hosts/daniels-2021-mbp/default.nix   modules/den/hosts/daniels-2021-mbp/default.nix
git mv modules/aspects/hosts/testvm/default.nix             modules/den/hosts/testvm/default.nix

# 11. Move host data files (secrets, facter, keys) to per-host folders
git mv modules/hosts/builder/secrets.yaml          modules/den/hosts/builder/secrets.yaml
git mv modules/hosts/builder/facter.json           modules/den/hosts/builder/facter.json
git mv modules/hosts/builder/ssh.pub               modules/den/hosts/builder/ssh.pub
git mv modules/hosts/builder/known_hosts           modules/den/hosts/builder/known_hosts
git mv modules/hosts/builder/boot_host_key.pub     modules/den/hosts/builder/boot_host_key.pub
git mv modules/hosts/builder/runtime_host_key.pub  modules/den/hosts/builder/runtime_host_key.pub

git mv modules/hosts/hvn-hyp1/secrets.yaml          modules/den/hosts/hvn-hyp1/secrets.yaml
git mv modules/hosts/hvn-hyp1/facter.json           modules/den/hosts/hvn-hyp1/facter.json
git mv modules/hosts/hvn-hyp1/ssh.pub               modules/den/hosts/hvn-hyp1/ssh.pub
git mv modules/hosts/hvn-hyp1/known_hosts           modules/den/hosts/hvn-hyp1/known_hosts
git mv modules/hosts/hvn-hyp1/boot_host_key.pub     modules/den/hosts/hvn-hyp1/boot_host_key.pub
git mv modules/hosts/hvn-hyp1/runtime_host_key.pub  modules/den/hosts/hvn-hyp1/runtime_host_key.pub

# testvm and daniels-2021-mbp may have secrets.yaml or may not — move what exists

# 12. Move defaults + namespace
git mv modules/aspects/default.nix  modules/den/defaults.nix
git mv modules/namespace.nix        modules/den/namespace.nix

# 13. Create new files (Phase 1-3 artifacts, created in earlier phases)
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

# 14. Clean up empty directories
rmdir modules/aspects/{hosts/builder,hosts/hvn-hyp1,hosts/daniels-2021-mbp,hosts/testvm,hosts}
rmdir modules/aspects/{profiles,secrets,services,nix}
rmdir modules/aspects
rmdir modules/schema
rmdir modules/security
rmdir modules/storage   # mergerfs.nix moved to den aspect
rmdir modules/hosts/{builder,hvn-hyp1,testvm,daniels-2021-mbp}
rmdir modules/hosts

# 15. Remove stale pre-den files
git rm modules/lib/asserts.nix modules/lib/default.nix modules/lib/dlab.nix modules/lib/dsl.nix modules/lib/utilities.nix
git rm modules/hosts/builder/_configuration.nix modules/hosts/hvn-hyp1/_configuration.nix
git rm modules/hosts/daniels-2021-mbp/_configuration.nix modules/hosts/testvm/_default.nix

# 16. Regenerate flake
nix run .#write-flake --impure
```

### 4.7 Relative Paths: No Changes Needed

After the move, both sops.nix and facter.nix use the same relative path pattern (`../../hosts/<name>/...`) from their new locations:

| File | Old location | New location | Relative path | Resolves to |
|------|-------------|-------------|--------------|-------------|
| sops.nix | `modules/aspects/secrets/` | `modules/den/aspects/secrets/` | `../../hosts/<name>/secrets.yaml` | `modules/den/hosts/<name>/secrets.yaml` |
| facter.nix | `modules/aspects/profiles/` | `modules/den/aspects/core/` | `../../hosts/<name>/facter.json` | `modules/den/hosts/<name>/facter.json` |

Both files move from depth 3 under `modules/` to depth 3 under `modules/den/`. The `../../` prefix works identically from both positions, resolving to `modules/hosts/` → `modules/den/hosts/` respectively. **No path string changes needed.**

### 4.8 `shared/secrets.yaml`

The CrowdSec enrollment key lives in `shared/secrets.yaml` at the repo root. This is a SOPS-encrypted file shared across hosts (not per-host). It uses a `sopsFile` override in the secret request:

```nix
# modules/den/aspects/services/crowdsec.nix
secretRequests."crowdsec/enrollmentKey" = {
  sopsFile = ../../../shared/secrets.yaml;
  # ... path stays correct from new location
};
```

This file is out-of-scope for the migration. It stays at the repo root.

### 4.9 Phase 4 Verify

```bash
nix run .#write-flake --impure
nix flake check
nix eval .#nixosConfigurations.builder.config.services.openssh.enable
```

**Commit:**

```
refactor: reorganize modules into den-native structure

File moves: core, disk, hardware, networking, roles, secrets,
services, features, users, groups, quirks categories.
Per-host folders under modules/den/hosts/<name>/ with co-located
entity files and data (secrets.yaml, facter.json, keys).
Mergerfs converted to den.aspects.services.mergerfs.
Namespace changed to "dlab" true for short aspect names.
All "profile" references eliminated.
Legacy pre-den files and empty directories removed.

BREAKING: all den.aspects."dlab/profile/*" renamed to
functional category names (core.*, disk.*, etc.).
```

**Deploy:** `deploy .#builder -- --impure`, then `deploy .#hvn-hyp1 -- --impure`, then remaining hosts.

---

## Phase 5: Policies

No fork dependencies.

### 5.1 Group-Based User Resolution Policy

**New file:** `modules/den/policies/users.nix`

```nix
{ lib, den, config, ... }:
let
  inherit (den.lib.policy) resolve;
  registry = config.den.users.registry or { };

  matchUsers = hostAccessGroups:
    builtins.attrValues (
      lib.filterAttrs (name: user:
        let userGroups = user.groups or [ ];
        in builtins.any (g: lib.elem g hostAccessGroups) userGroups
      ) registry
    );
in {
  den.schema.host.excludes = [ den.policies.host-to-users ];
  den.policies.group-users = { host, ... }:
    let
      accessGroups = host.system-access-groups or [ ];
      matched = matchUsers accessGroups;
    in map (user: resolve.to "user" { inherit user; }) (builtins.attrValues matched);
}
```

### 5.2 Phase 5 Verify

```bash
nix flake check
nix eval .#nixosConfigurations.testvm.config.users.users.alice.isNormalUser
nix eval .#nixosConfigurations.hvn-hyp1.config.users.users.alice
nix eval .#nixosConfigurations.builder.config.users.users.daniel.isNormalUser
```

**Commit:**

```
feat: group-based user resolution policy

Replaces default host-to-users policy with group-users policy.
Users are resolved onto hosts by intersecting user.groups with
host.system-access-groups. Excludes den.policies.host-to-users.

Access rules: daniel (admins) → every host, alice (vm-access) → VMs,
bob (services, vm-access) → service VMs.
```

**Deploy:** `deploy .#testvm -- --impure` and `deploy .#hvn-hyp1 -- --impure`. Alice should have an account on testvm but not hvn-hyp1.

---

## Phase 6: Den-Native Refactors

⚠️ All features gated on `github:sini/den/feat/entity-gen-schema-port` merging into mainline `github:denful/den`.

### 6.1 Dynamic `settingsType` (sini) 🐚 ⚠️

Auto-discovers aspect `.settings` declarations and creates host entity options without manual schema wiring. Replaces the manual `options.settings.*` declared in Phase 2.

### 6.2 Environment Entities (sini) 🐚 ⚠️

```
den.environments.home → cascades defaults to bare-metal hosts
den.environments.vms  → cascades defaults to VMs
```

### 6.3 Settings Cascade (scope-engine) 🐚 ⚠️

`aspect defaults → environment → host → user` precedence chain.

---

## Host Directory Structure

### Decision: Per-Host Folders with Co-Located Data

Each host gets a directory under `modules/den/hosts/<name>/` containing:

| File | Purpose | Source |
|------|---------|--------|
| `default.nix` | `den.hosts.<system>.<name>` entity data + `den.aspects.<name>` aspect definition | Migrated from `modules/aspects/hosts/<name>/default.nix` |
| `secrets.yaml` | SOPS-encrypted secrets (passwords, keys) | Migrated from `modules/hosts/<name>/secrets.yaml` |
| `facter.json` | nixos-facter hardware detection report | Migrated from `modules/hosts/<name>/facter.json` |
| `ssh.pub` | User SSH public key for this host | Migrated from `modules/hosts/<name>/ssh.pub` |
| `known_hosts` | SSH host keys for deploy-rs | Migrated from `modules/hosts/<name>/known_hosts` |
| `boot_host_key.pub` | Initrd SSH host key | Migrated from `modules/hosts/<name>/boot_host_key.pub` |
| `runtime_host_key.pub` | Runtime SSH host key | Migrated from `modules/hosts/<name>/runtime_host_key.pub` |

**Why per-host folders vs. flat files:**

- **Self-contained:** Adding a host means creating one directory with all its files. Removing a host means deleting one directory. No cross-referencing between `modules/aspects/hosts/` (entity) and `modules/hosts/` (data).
- **SOPS path simplification:** The sops.nix relative path `../../hosts/<hostName>/secrets.yaml` works identically from old and new file locations — no path changes needed.
- **Facter path same:** `../../hosts/<hostName>/facter.json` works from both locations.
- **Deploy-rs known_hosts:** `knownHostsPath` in host entity data becomes `./known_hosts` relative to `modules/den/hosts/<name>/default.nix`, or can be computed from `config.networking.hostName`.

**Contrast with sini:** sini uses flat files (`modules/den/hosts/bitstream.nix`, `modules/den/hosts/axon-01.nix`) with secrets stored in `.secrets/hosts/<name>/` at the repo root. sini's approach decouples secrets from entity definitions because secrets are managed by agenix (age-encrypted per-file), not SOPS (yaml per-host). The homelab's SOPS model benefits from co-location.

### Impact on Import-Tree

`modules/den/hosts/<name>/` directories are under `modules/` which is in the import-tree path (`inputs.import-tree [ ./nix ./modules ]` in `modules/meta/flake-parts.nix`). Only `.nix` files are picked up by import-tree. Data files (`secrets.yaml`, `facter.json`, etc.) are NOT `.nix` files, so they're invisible to import-tree — safe to co-locate.

---

## Migration Reference

| Den Path | Purpose | Phase | Fork? | Status |
|----------|---------|-------|-------|--------|
| `den.default.nixos` | Global NixOS defaults | — | ✅ | ✅ stateVersion, SSH, mutableUsers, emergencyAccess |
| `den.default.includes` | Global batteries | 1 | ✅ | ✅ hostname, define-user, ssh-keys battery |
| `den.schema.host` | Host entity metadata | 1,2 | ✅ | 🔜 `system-access-groups`, `settings.*` |
| `den.schema.host.includes` | Auto-applied aspects + collectors | 1,3 | ✅ | 🔜 core.time, networking, persist-collector, firewall-collector |
| `den.schema.host.excludes` | Excluded policies | 5 | ✅ | 🔜 host-to-users |
| `den.schema.user` | User entity metadata | 1 | ✅ | 🔜 `identity`, `system` |
| `den.schema.user.isEntity` | Users as real entities | 1 | ✅ | 🔜 Set via registry |
| `den.schema.user.includes` | Auto-include policies | 1 | ✅ | 🔜 resolved-user-emitter + auto-include |
| `den.aspects.core.*` | Core system aspects | 4 | ✅ | 🔜 11 aspects including collectors |
| `den.aspects.disk.*` | Filesystem aspects | 4 | ✅ | 🔜 zfs + ext4 |
| `den.aspects.hardware.*` | Hardware enablement | 4 | ✅ | 🔜 hypervisor |
| `den.aspects.networking.*` | Networking | 4 | ✅ | 🔜 default |
| `den.aspects.services.*` | Service daemons | 4 | ✅ | ✅ crowdsec + 🔜 mergerfs |
| `den.aspects.secrets.*` | Secret providers | 4 | ✅ | ✅ sops + hardcoded |
| `den.aspects.roles.*` | Composite roles | 4 | ✅ | 🔜 server, vm |
| `den.aspects.features.*` | Cross-cutting features | 1,4 | ✅ | 🔜 ssh-keys |
| `den.aspects.users.*` | Per-user aspects | 1 | ✅ | 🔴 daniel, alice |
| `den.aspects.groups.*` | Group entities | 1 | ✅ | 🔴 default |
| `den.aspects.quirks.*` | Quirk declarations | 3 | ✅ | 🔴 persist |
| `den.users.registry` | User declarations | 1 | ✅ | 🔴 New |
| `den.groups.*` | Group entities | 1 | ✅ | 🔴 New |
| `den.policies.group-users` | Group-based resolution | 5 | ✅ | 🟡 Replace default |
| `den.batteries.define-user` | User account creation | 1 | ✅ | ✅ |
| `den.batteries.hostname` | Hostname from entity | — | ✅ | ✅ |
| `den.batteries.primary-user` | Admin user | 1 | ✅ | 🔜 Per-user includes |
| `den.batteries.user-shell` | Default shell | 1 | ✅ | 🔜 Per-user includes |
| `den.batteries.mutual-provider` | Inert shim | 1 | ✅ | 🟡 Removed |
| `den.quirks.*` | Pipe data | 3 | ✅ | 🔴 persist, persistHome, cache, firewall, resolved-users |
| `host.hasAspect` | Structural detection | 2 | ✅ | 🔴 Replace null checks |
| `host.settings.*` | Per-host configuration | 2 | ✅ | 🔴 Manual schema wiring |
| `os` class | Cross-platform | 2 | ✅ | 🔜 ssh-keys, nix |
| Dynamic `settingsType` | Auto-discovered settings | 6 | ❌ | 🔴 Fork-gated |
| Environment entities | Env defaults/cascade | 6 | ❌ | 🔴 Fork-gated |
| `scope-engine` | Settings cascade | 6 | ❌ | 🔴 Fork-gated |

---

## Den Source & Examples Guide

| Location | What's There |
|----------|--------------|
| `~/src/den/modules/aspects/batteries/*.nix` | Battery implementations |
| `~/src/den/modules/policies/core.nix` | Default host-to-users policy |
| `~/src/den/nix/lib/namespace-types.nix` | Schema submodule type (deferredModule + lazyAttrsOf) |
| `~/src/den/nix/lib/entities/host.nix` | Host entity type definition (imports den.schema.host) |
| `~/src/den/nix/lib/resolve-entity.nix` | Entity resolution (reads schema.includes/excludes) |
| `~/src/den/nix/lib/schema-util.nix` | Schema entity kind detection |
| `~/src/den/nix/lib/aspects/fx/assemble-pipes.nix` | Quirk pipe assembly (804 lines) |
| `~/src/den/nix/lib/aspects/fx/key-classification.nix` | Pipe key classification |
| `~/src/den/templates/example/modules/aspects/alice.nix` | Per-user aspect with cross-scope policy |
| `~/src/den/templates/example/modules/aspects/hasAspect-examples.nix` | hasAspect worked examples (141 lines) |
| `~/src/den/templates/fleet-demo/modules/aspects/users/ssh-keys.nix` | SSH keys battery (23 lines) |
| `~/src/den/templates/fleet-demo/modules/users.nix` | User registry (139 lines) |
| `~/src/den/templates/fleet-demo/modules/policies/fleet.nix` | Policy tree (98 lines) |
| `~/src/den-examples/sini/modules/den/defaults.nix` | Sini defaults patterns |
| `~/src/den-examples/sini/modules/den/aspects/core/resolved-user-emitter.nix` | Resolved-user quirk (14 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/persist-collector.nix` | Persist collector |
| `~/src/den-examples/sini/modules/den/aspects/core/firewall-collector.nix` | Firewall collector (5 lines) |
| `~/src/den-examples/sini/modules/den/hosts/bitstream.nix` | Host entity with settings and includes |

---

## Concept Deep-Dives

### Quirks: The Full Flow

1. **Declaration:** `den.quirks.persist = { type = ...; default = []; }` — registered in `pipeRegistry` (`key-classification.nix:41`)
2. **Emission:** Aspect writes `pipe.persist = [ { directory = ...; } ]` — classified as pipe key
3. **Assembly:** `assemblePipes.nix` collects all `pipe.persist` across aspects per entity scope
4. **Delivery:** Collector receives assembled list via function args: `{ persist, cache, lib, ... }`
5. **Transform:** Collector merges into `environment.persistence`

Collectors must be in `den.schema.host.includes` to fire at every host scope and receive assembled pipe data.

### How Users Reach Hosts

```
1. den.users.registry.daniel = { groups = [ "admins" ]; }
2. den.hosts.x86_64-linux.builder.system-access-groups = [ "admins" ]
3. den.policies.group-users fires: matches users by group intersection
4. resolve.to "user" creates user entity with registry data
5. den.schema.user.includes fires:
   a. resolved-user-emitter emits quirk metadata
   b. auto-include checks den.aspects.builder.daniel
6. den.aspects.daniel.policies.to-hosts fires:
   → den.lib.policy.provide pushes NixOS config
7. define-user battery creates Unix account
8. primary-user battery adds wheel + networkmanager
9. ssh-keys battery populates authorizedKeys
```

### Schema Function + `.includes` Coexistence

See dedicated section at top of document.

---

## Verification Guidelines

### Local Verification + Deploy Prompt Model

Verification follows a two-step pattern:

1. **Local eval** (I handle): `nix flake check`, `nix eval`, `nix run .#write-flake`
2. **Deploy prompt** (you handle): conventional commit, then deploy to verify on actual hardware

### Per-Phase Commit + Deploy Table

| Phase | Commit Scope | Title | Deploy Target |
|-------|-------------|-------|--------------|
| 0.1 | `fix` | convert nix config to den aspect with GC as per-host setting | builder + one other |
| 0.2 | `fix` | restore missing base packages and vim | builder |
| 0.3 | `fix(chrony)` | add user/group ownership to persist directories | builder |
| 0.4 | `fix(remote-unlock)` | restore initrd debugging tools | hvn-hyp1 |
| 0.5 | `fix(hvn-hyp1)` | wire mergerfs storage pool | hvn-hyp1 |
| 1 | `feat` | parametric user model with group registry and ssh-keys battery | builder |
| 2 | `feat` | add per-host settings with hasAspect replacements | builder + testvm |
| 3 | `feat` | adopt den quirks for persist, firewall, and resolved-users | builder |
| 4 | `refactor` | reorganize modules into den-native structure | all hosts, one at a time |
| 5 | `feat` | group-based user resolution policy | testvm + hvn-hyp1 |

### Full System Deploy Order (After Phase 5)

```bash
# 1. Regenerate flake (I handle)
nix run .#write-flake --impure
nix flake check

# 2. Deploy each host (you handle, in this order)
deploy .#builder -- --impure
deploy .#hvn-hyp1 -- --impure
deploy .#testvm -- --impure
deploy .#daniels-2021-mbp -- --impure
```

Verification points after deploy: daniel has an account on all hosts, alice has an account on testvm but not hvn-hyp1, nix GC is active on hvn-hyp1 but inactive on builder, persist directories are owned by correct users.

---

## Quick Start

1. **Phase 0** — fix bugs, deploy immediately
2. **Phase 1** — parametric users, groups, registry, ssh-keys battery
3. **Phase 2** — manual settings, `hasAspect`, `os` shorthand
4. **Phase 3** — quirks, collectors, remove `persist.directories` option
5. **Phase 4** — file moves, per-host folders, mergerfs aspect, short names, `write-flake`
6. **Phase 5** — group-based policy, exclude default host-to-users
7. **Phase 6** — fork-gated
