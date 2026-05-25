# Den Migration v6: Audit, Roadmap & Concepts

Pre-den baseline: `eea36b4^` (before "Initial den migration")
v5 baseline: `docs/den-migration-v5.md` (superseded)

---

## What Changed from v5

**Phase 1-3 files created at existing paths, Phase 4 moves them.** v5 created Phase 3 quirk/collector files at `modules/den/aspects/...` paths before that directory existed. This violated v2's key insight: "refactor in-place, then move clean files." v6 creates all new Phase 1-3 files under `modules/aspects/`, and Phase 4's migration steps handle the moves.

**Password derivation replaces entity data flag.** v5's Phase 1.4 had `hashedPasswordFile = config.sops.secrets...` in host entity data — but `config` at entity scope is the entity submodule, not NixOS config. v6 removes password from entity data entirely. The parametric aspect's `nixos` body derives the SOPS secret path and declares `secretRequests` for each user. No entity data changes needed beyond the existing `users.<name>.sshKeys`.

**`den.aspects.core.nix` wiring made explicit.** v5 noted "must be wired into `den.schema.host.includes`" as a prose note. v6 shows the exact line to add in `modules/aspects/default.nix`.

**`secretRequests` migrate with the user hardcoding.** v5 deleted the `secretRequests."users/daniel/hashedPassword"` entry from `den.default.nixos` without saying where it moves. v6 moves it into the parametric aspect's `nixos` body (parametric per-user-name, not hardcoded to "daniel").

**`nix/den.nix` moved into `modules/flake/den.nix`, `nix/` directory deleted.** The repo root had two locations importing `den.flakeModule`: `nix/den.nix` (51-line output bridge) and `modules/flake/den.nix` (4-line duplicate). v6 replaces the 4-line stub with the output bridge, deletes `nix/`, and updates import-tree to `[ ./modules ]` only.

**Phase 5 trimmed to reference table.** v5's full 10-subsection implementation (~200 lines of code across 6+ files) is replaced with a sini reference table + 1 key code snippet (the group-based resolution policy). An agent can implement if needed without being tempted to build it during Phases 0-4.

**Phase 0.1 complexity explained.** v5's Phase 0.1 jumped from v3's "uncomment GC" (1 line) to a full 100-line parametric aspect rewrite. v6 explains why: because the nix config lived in `den.default.nixos` (anti-pattern), and converting it to `den.aspects.core.nix` fixes GC being commented out AND moves nix config into the proper den architecture.

---

## Fork Dependency Map

| Feature | Dependency | Status in homelab |
|---|---|---|
| Quirks (`pipe.*`, `den.quirks.*`, collectors) | Core den | Used in Phase 3 |
| `den.schema.*.includes` / `excludes` | Core den | Used in Phases 1, 3, 5 |
| `den.lib.policy.mkPolicy`, `.include`, `.provide`, `.resolve.to` | Core den | Used in Phase 5 |
| `host.hasAspect` | Core den | Used in Phase 2 |
| `os` class shorthand (via `os-to-host` policy) | Core den | Used in Phase 0.1 |
| Parametric aspects with entity args (`{ host, ... }:`) | Core den | Used in Phases 0.1, 1, 3 |
| Bare functions in `includes` lists | Core den | Used in Phase 1 (verified: `wrapBareFn` in `normalize.nix:62-72`) |
| Manual settings via `den.schema.host.options.*` | Core den | Used in Phases 0.1, 2 |
| `den.reservedKeys` | Fork only | Not needed (manual settings on schema don't need it) |
| Dynamic `settingsType` auto-discovery | Fork only | Phase 6 gated |
| `scope-engine` settings cascade | Fork only | Phase 6 gated |
| `gen-schema` methods/refs | Fork only | Blocks environment entities |
| `den.lib.policy.instantiate` | Fork only | Homelab uses manual `nix/den.nix` output bridge |

**Bottom line:** Every actionable phase (0-5) uses core den features only. Phase 6 is gated on the fork merging into mainline.

---

## How `den.schema.host` Function + `.includes` Coexist

`den.schema` is a `lib.types.submodule` with `freeformType = lib.types.lazyAttrsOf lib.types.deferredModule`. The function `{ host, lib, ... }: { options = ...; }` is the **deferred module value** for the `host` submodule entry. `.includes` and `.imports` are **data attributes** on the same entry. Because both live under the same lazy submodule key, Nix's module system merges them without conflict.

---

## Phase 0: Fix Regressions

Fix and deploy immediately. All changes are to files at their current paths (pre-Phase-4 reorg).

### 0.1 Nix Config: Parametric Den Aspect with Per-Host GC

**Why this is complex:** v3's Phase 0.1 was "uncomment GC" (1 line). The nix daemon config lived in `den.default.nixos` — the same anti-pattern as the hardcoded `users.users.daniel`. Converting it to `den.aspects.core.nix` kills two birds: fixes GC being commented out, AND moves nix config from a `den.default.nixos` blob into a proper parametric den aspect with `os`/`nixos`/`darwin` class bodies (sini pattern). The daemon scheduling and OOM prevention patterns are adopted from sini's `aspects/core/nix.nix`.

**Target:** `den.aspects.core.nix` — parametric so `host.settings` is accessible for per-host GC control.

**File:** `modules/aspects/nix/default.nix` — replace entire file:

```nix
{ lib, config, ... }: {
  den.aspects.core.nix = {
    # os = fires on BOTH NixOS and Darwin (via os-to-host policy)
    # Parametric: { host, lib, ... } so host.settings is readable
    os = { host, lib, ... }: {
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

      nix.gc = lib.mkIf (host.settings.core.nix.gc.enable or true) {
        automatic = true;
        options = "--delete-older-than 14d";
      };
    };

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
        services.nix-gc.serviceConfig = {
          CPUSchedulingPolicy = "batch";
          IOSchedulingClass = "idle";
          IOSchedulingPriority = 7;
        };
      };
    };

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

  # Unfree package allowlist (migrated from old location in nix/default.nix)
  den.schema.host.options.nix.allowedUnfree = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
  };
}
```

**Wiring** — open `modules/aspects/default.nix` and add `den.aspects.core.nix` to `den.schema.host.includes`:

```nix
den.schema.host.includes = [
  den.aspects."dlab/profile/time"
  den.aspects."dlab/profile/networking"
  den.aspects.core.nix       # ← ADD THIS LINE
];
```

**File:** `modules/aspects/hosts/builder/default.nix` — add `settings.core.nix.gc.enable = false`:

```nix
den.hosts.aarch64-linux.builder = {
  settings.core.nix.gc.enable = false;
  # ... existing entity data
};
```

**Commit:**

```
fix: convert nix config to parametric den aspect with per-host GC

Replace den.default.nixos nix config with den.aspects.core.nix.
Uses os/nixos/darwin class bodies. os body is parametric so it
can read host.settings.core.nix.gc.enable.

GC is a host entity setting (default true). Builder disables it
because its small disk is managed via impermanence rollbacks.
Also adopts sini's daemon scheduling and OOM prevention patterns.
```

**Deploy:** `deploy .#builder -- --impure`. GC timer inactive on builder, active elsewhere.

---

### 0.2 Missing base packages + vim

**File:** `modules/aspects/default.nix` — add to `den.default.nixos.config`:

```nix
environment.systemPackages = with pkgs; [ bottom lnav git ];
programs.vim.enable = lib.mkDefault true;
```

**Commit:**

```
fix: restore missing base packages and vim from pre-den config
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
```

**Deploy:** `deploy .#builder -- --impure` and verify chrony directory ownership.

---

### 0.4 Initrd `extraBin` missing for remote unlock

**File:** `modules/aspects/profiles/remote-unlock.nix` — add to the `config = lib.mkIf (poolName != null) { ... }` block:

```nix
boot.initrd.systemd.extraBin = {
  ping = "${pkgs.iputils}/bin/ping";
  trip  = "${pkgs.trippy}/bin/trip";
  ip    = "${pkgs.iproute2}/bin/ip";
  vi    = "${pkgs.vim}/bin/vi";
};
```

These debugging tools were in the pre-migration initrd config but never migrated.

**Commit:**

```
fix(remote-unlock): restore initrd debugging tools
```

**Deploy:** `deploy .#hvn-hyp1 -- --impure`. Verify tools present in initrd after reboot.

---

### 0.5 MergerFS not wired for hvn-hyp1

**File:** `modules/aspects/hosts/hvn-hyp1/default.nix` — add to `den.aspects.hvn-hyp1.nixos`:

```nix
imports = [ ../../../storage/mergerfs.nix ];
dlab.storage.mergerfs."/mnt/storage/media" = {
  branches = [
    "/mnt/storage-clear/media1"
    "/mnt/storage-clear/media3"
  ];
};
```

**Commit:**

```
fix(hvn-hyp1): wire mergerfs storage pool
```

**Deploy:** `deploy .#hvn-hyp1 -- --impure` and verify mergerfs pool mounts.

---

## Phase 1: Parametric Users from Host Entity Data

No fork dependencies. All core den.

**Design:** Users are typed entity data on hosts. A parametric aspect in `den.schema.host.includes` reads `host.users` and creates NixOS accounts. Passwords are derived from SOPS (not stored in entity data). No user registry, no group entities, no user-scope resolution. The full group-based model is deferred to Phase 5.

### 1.1 Declare `users` Option on Host Schema

**File:** `modules/schema/host.nix` — add `options.users`:

```nix
den.schema.host = { host, lib, ... }: {
  # ... existing zfs, networking options ...

  options.users = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        sshKeys = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          default = [ ];
          description = "Paths to SSH public key files";
        };
        extraGroups = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra groups for the user";
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "User-specific packages";
        };
      };
    });
    default = { };
    description = "User accounts on this host";
  };
};
```

### 1.2 Parametric User Account Aspect

**File:** `modules/aspects/default.nix` — add to `den.schema.host.includes`:

```nix
({ host, lib, config, ... }: let
  readKeyFile = path:
    lib.strings.trim (if lib.isPath path then builtins.readFile path else path);
  readAllKeys = keys:
    lib.filter (k: k != "") (lib.concatMap (path: lib.splitString "\n" (readKeyFile path)) keys);
in {
  nixos = lib.mkMerge (lib.mapAttrsToList (name: userCfg: {
    secretRequests."users/${name}/hashedPassword" = {
      mode = "0400";
      owner = "root";
      neededForUsers = true;
    };
    users.users.${name} = lib.mkMerge [
      {
        isNormalUser = true;
        extraGroups = userCfg.extraGroups or [ ];
        hashedPasswordFile = config.sops.secrets."users/${name}/hashedPassword".path;
      }
      (lib.mkIf (userCfg.sshKeys or [ ] != [ ]) {
        openssh.authorizedKeys.keys = readAllKeys userCfg.sshKeys;
      })
    ];
  }) host.users);
})
```

Design notes:
- `hashedPasswordFile` is derived from `config.sops.secrets` (NixOS module config, available in `nixos` body). Not stored in entity data.
- `secretRequests` is declared here (parametric per-user-name) so SOPS picks it up. The original hardcoded `secretRequests."users/daniel/hashedPassword"` in `den.default.nixos` is removed below.
- `config.sops.secrets."users/${name}/hashedPassword".path` resolves because `secretRequests` → `sops.secrets` mapping is handled by `sops.nix`.
- Every user declared on a host must have a corresponding SOPS entry at `users/<name>/hashedPassword` in the host's `secrets.yaml`. Build fails if missing. For the current 3-user setup, all users have passwords.

### 1.3 Remove Hardcoded User

**File:** `modules/aspects/default.nix` — delete these entries from `den.default.nixos.config`:

```nix
# DELETE: secretRequests."users/daniel/hashedPassword" = { ... };
# DELETE: users.users.daniel = { ... };
```

Also remove the inline SSH key lambda from `den.default.includes` (the `({ host, user }: { nixos.users.users.${user.userName}... })` block) — replaced by the parametric aspect above.

### 1.4 Update Host Entity Data

Builder and hvn-hyp1 already have `users.daniel.sshKeys = [ ... ]`. Add `extraGroups`:

```nix
# modules/aspects/hosts/builder/default.nix
den.hosts.aarch64-linux.builder = {
  users.daniel = {
    sshKeys = [ ../../../hosts/builder/ssh.pub ];
    extraGroups = [ "wheel" ];
  };
  # ... rest
};
```

Do the same for `hvn-hyp1` and any other host with users.

**Commit:**

```
feat: parametric user accounts from typed host entity data

Declares options.users on den.schema.host. A parametric aspect
in den.schema.host.includes creates NixOS accounts, derives
hashedPasswordFile from SOPS, and emits per-user secretRequests.

Removes hardcoded users.users.daniel from den.default.nixos.
```

**Deploy:** `deploy .#builder -- --impure` to verify daniel still resolves.

---

## Phase 2: Settings on Aspects

No fork dependencies. Manual settings via schema function pattern.

### 2.1 Declare Per-Host Settings

Settings are accumulated across phases. Phase 0.1 added `settings.core.nix.gc.enable`. Phase 2 adds the rest. Both live under `options.settings.*` on the schema function.

**File:** `modules/schema/host.nix` — extend the schema function:

```nix
den.schema.host = { host, lib, ... }: {
  # ... existing zfs, networking, users options ...

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

Note: Phase 0.1's `settings.core.nix.gc.enable` was declared separately before the full `settings` submodule was added. When both `options.settings.core.nix.gc.enable` (Phase 0.1) and `options.settings = lib.mkOption { ... }` (Phase 2) merge, the individual option merges into the submodule's freeform space. This works in Nix's module merge.

### 2.2 `hasAspect` Replacements

Replace `host.zfs.rootPool != null` checks with `host.hasAspect`:

```nix
# Before (impermanence.nix)
nixos = lib.mkIf (host.zfs.rootPool != null) { ... };

# After
nixos = lib.mkIf (host.hasAspect den.aspects.disk.zfs) { ... };
```

**Commit:**

```
feat: add per-host settings with hasAspect replacements

Manual settings on den.schema.host for disk, networking, hypervisor,
time, impermanence, and remote-unlock. Replaces host.zfs.rootPool
null checks with host.hasAspect.
```

**Deploy:** `deploy .#builder -- --impure` and `deploy .#testvm -- --impure`.

---

## Phase 3: Quirks

> **Note:** See [Phase 3 Addendum](./den-migration-v6-phase3-addendum.md) for implementation findings. Quirk pipes and `den.batteries.forward` custom class registration require the den fork (`sini/den/feat/entity-gen-schema-port`). On `denful/den` main, the working approach is the existing `persist.directories` NixOS option.

No fork dependencies. All files created at current paths (under `modules/aspects/`) — Phase 4 moves them.

### 3.1 Declare Quirk Descriptions (Description Only)

Den's `pipeSchemaType` accepts only `{ description = "..."; }`. Quirks are data routes — the type of data flowing through them is implicit.

**New file:** `modules/aspects/quirks/persist.nix`

```nix
_: {
  den.quirks.persist.description =
    "Persistent directories/files from aspects (host-scoped)";
  den.quirks.persistHome.description =
    "Persistent directories/files from aspects (user-scoped)";
  den.quirks.cache.description =
    "Cache directories (host-scoped, separate wipe semantics)";
  den.quirks.firewall.description =
    "Firewall rules collected from aspects";
  den.quirks.resolved-users.description =
    "Resolved user metadata from user scope";
}
```

### 3.2 Update Aspects to Emit into Quirks

Aspects emit by declaring quirk-named keys. The key classification system matches these against `den.quirks`.

**File:** `modules/aspects/profiles/hypervisor.nix` — replace the `persist.directories` line:

```nix
# Before
persist.directories = [{ directory = "/var/lib/incus"; }];

# After
persist = [
  { directory = "/var/lib/incus"; user = "incus"; group = "incus"; }
];
```

**File:** `modules/aspects/profiles/time.nix` — same pattern:

```nix
persist = [
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

**persist-collector** is scoped to hosts with impermanence (sini pattern: `disk/impermanence.nix:9-11`). It must NOT be global — `environment.persistence` doesn't exist on non-impermanence hosts.

**File:** `modules/aspects/profiles/impermanence.nix` — add includes:

```nix
den.aspects."dlab/profile/impermanence" = { host, ... }: {
  includes = [
    den.aspects.core.persist-collector
  ];
  # ... rest of aspect ...
};
```

**File:** `modules/aspects/default.nix` — add firewall-collector to `den.schema.host.includes`:

```nix
den.schema.host.includes = [
  den.aspects."dlab/profile/time"
  den.aspects."dlab/profile/networking"
  den.aspects.core.nix
  den.aspects.core.firewall-collector   # ← ADD: global (safe on all hosts)
  # persist-collector NOT here — wired via impermanence aspect
];
```

Rationale: firewall-collector is safe globally because `networking.firewall` exists on all NixOS hosts.

### 3.5 Remove the NixOS Option

**File:** `modules/aspects/default.nix` — delete `options.persist.directories`.

**Commit:**

```
feat: adopt den quirks for persist, firewall, and resolved-users

Replaces the bespoke persist.directories NixOS option with quirk-
based data pipes. persist-collector wired via impermanence aspect
includes (scoped). firewall-collector global via host schema includes.
Quirk declarations are description-only (matching den's pipeSchemaType).
Aspects emit into quirk-named keys directly.
```

**Deploy:** `deploy .#builder -- --impure` to verify.

---

## Phase 4: Rename & Reorganize

> **Note:** See [Phase 4 Addendum](./den-migration-v6-phase4-addendum.md) for dot vs slash notation findings. Multi-word dot-notation names (`den.aspects.disk.zfs`) cause `hasAspect` failures on `denful/den` main. Slash notation (`den.aspects."disk/zfs"`) is used throughout.

### 4.1 Host Directory Structure

Per-host folders under `modules/den/hosts/<name>/` containing both the entity+aspect file and data files:

```
modules/den/hosts/
  builder/default.nix, secrets.yaml, facter.json, ssh.pub, known_hosts, boot_host_key.pub, runtime_host_key.pub
  hvn-hyp1/default.nix, secrets.yaml, facter.json, ssh.pub, known_hosts, boot_host_key.pub, runtime_host_key.pub
  testvm/default.nix, secrets.yaml
  daniels-2021-mbp/default.nix
```

### 4.2 MergerFS as a Den Aspect

The old `modules/storage/mergerfs.nix` will be `git mv`'d to its new location, then its contents replaced.

**File:** `modules/den/aspects/services/mergerfs.nix` (replaces moved file)

```nix
{ lib, pkgs, ... }: {
  den.aspects.services.mergerfs.settings.options.pools = lib.mkOption {
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

  den.aspects.services.mergerfs = { host, ... }: {
    nixos = { pkgs, lib, ... }: let
      cfg = host.settings.services.mergerfs.pools or { };
      escapeSystemdPath = path:
        lib.strings.sanitizeDerivationName (builtins.substring 1 (-1) path);
    in lib.mkIf (cfg != { }) (lib.mkMerge [
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
      # ... mergerfs systemd service definitions (extracted from the old module)
    ]);
  };
};
```

Host entity data uses `settings.services.mergerfs.pools`:

```nix
den.hosts.x86_64-linux.hvn-hyp1 = {
  settings.services.mergerfs.pools."/mnt/storage/media" = {
    branches = [ "/mnt/storage-clear/media1" "/mnt/storage-clear/media3" ];
  };
};
```

### 4.3 Namespace: Remove Entirely

The `"dlab"` prefix is eliminated by the rename — all aspects become bare functional names (`core.time`, `disk.zfs`, etc.). `modules/namespace.nix` is deleted in the migration steps.

### 4.4 Target Directory Structure

```
modules/
  den/
    defaults.nix                     — den.default + schema includes + collectors
    flake-parts.nix                  — den.flakeModule import (was: modules/flake/den.nix)
    schema/
      host.nix                       — zfs, networking, users, settings
      user.nix                       — identity, system, classes
    aspects/
      core/
        time.nix
        nix.nix
        ssh.nix
        sudo.nix
        facter.nix
        remote-unlock.nix
        persist-collector.nix
        firewall-collector.nix
      secrets/
        sops.nix
        hardcoded.nix
      services/
        crowdsec.nix
        mergerfs.nix
      disk/
        zfs.nix
        ext4.nix
        impermanence.nix
      hardware/
        hypervisor.nix
      networking/
        default.nix
      roles/
        server.nix
        vm.nix
      quirks/
        persist.nix
    hosts/
      builder/default.nix, secrets.yaml, facter.json, ssh.pub, known_hosts, ...
      hvn-hyp1/default.nix, ...
      testvm/default.nix, ...
      daniels-2021-mbp/default.nix, ...

  meta/
    flake-parts.nix                  — import-tree updated to [ ./modules ] only
    inputs.nix
    pkgs.nix
    systems.nix

  flake/
    den.nix                          — the output bridge (moved from nix/den.nix)
    deploy-rs.nix
    formatter.nix
    sops.nix

  nix/                               — flake-parts modules (unchanged)
    caches.nix, flakes.nix, optimise.nix, sensible.nix, unfree.nix

  packages/
    initrd.nix, install-on-envoy.nix

  storage/                           — EMPTY (mergerfs.nix moved)

  tests/
    default.nix
```

### 4.5 Aspect Name Map

| Current | Target | Category |
|---------|--------|----------|
| `den.aspects."dlab/profile/time"` | `den.aspects.core.time` | core |
| `den.aspects."dlab/profile/networking"` | `den.aspects.networking.default` | networking |
| `den.aspects."dlab/profile/impermanence"` | `den.aspects.disk.impermanence` | disk |
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
| `modules/aspects/quirks/persist.nix` (Phase 3) | `modules/den/aspects/quirks/persist.nix` | quirks |
| `modules/aspects/core/persist-collector.nix` (Phase 3) | `modules/den/aspects/core/persist-collector.nix` | core |
| `modules/aspects/core/firewall-collector.nix` (Phase 3) | `modules/den/aspects/core/firewall-collector.nix` | core |

### 4.6 Migration Steps

```bash
# 1. Create new directory tree
mkdir -p modules/den/aspects/{core,secrets,services,disk,hardware,networking,roles,quirks}
mkdir -p modules/den/{hosts,schema,policies}
mkdir -p modules/den/hosts/{builder,hvn-hyp1,testvm,daniels-2021-mbp}

# 2. Move schema files
git mv modules/schema/host.nix modules/den/schema/host.nix
git mv modules/schema/user.nix modules/den/schema/user.nix

# 3. Move core aspects
git mv modules/aspects/profiles/time.nix             modules/den/aspects/core/time.nix
git mv modules/aspects/profiles/facter.nix            modules/den/aspects/core/facter.nix
git mv modules/aspects/profiles/impermanence.nix     modules/den/aspects/disk/impermanence.nix
git mv modules/aspects/profiles/remote-unlock.nix    modules/den/aspects/core/remote-unlock.nix
git mv modules/aspects/nix/default.nix               modules/den/aspects/core/nix.nix
git mv modules/security/sudo.nix                     modules/den/aspects/core/sudo.nix

# 4. Move secrets
git mv modules/aspects/secrets/sops.nix             modules/den/aspects/secrets/sops.nix
git mv modules/aspects/secrets/hardcoded.nix        modules/den/aspects/secrets/hardcoded.nix

# 5. Move services (mergerfs: mv then edit contents per Phase 4.2)
git mv modules/aspects/services/crowdsec.nix        modules/den/aspects/services/crowdsec.nix
git mv modules/storage/mergerfs.nix                 modules/den/aspects/services/mergerfs.nix

# 6. Move disk (split from profiles/disks.nix)
#    Create disk/zfs.nix and disk/ext4.nix as new files with extracted content.
#    After verification, remove the old monolithic file:
git rm modules/aspects/profiles/disks.nix

# 7. Move hardware
git mv modules/aspects/profiles/hypervisor.nix      modules/den/aspects/hardware/hypervisor.nix

# 8. Move networking
git mv modules/aspects/profiles/networking.nix       modules/den/aspects/networking/default.nix

# 9. Move roles
git mv modules/aspects/profiles/server.nix           modules/den/aspects/roles/server.nix

# 10. Move Phase 3 files (created at old paths)
git mv modules/aspects/quirks/persist.nix            modules/den/aspects/quirks/persist.nix
git mv modules/aspects/core/persist-collector.nix    modules/den/aspects/core/persist-collector.nix
git mv modules/aspects/core/firewall-collector.nix   modules/den/aspects/core/firewall-collector.nix
rmdir modules/aspects/quirks

# 11. Move host entity files (to per-host folders)
git mv modules/aspects/hosts/builder/default.nix            modules/den/hosts/builder/default.nix
git mv modules/aspects/hosts/hvn-hyp1/default.nix           modules/den/hosts/hvn-hyp1/default.nix
git mv modules/aspects/hosts/daniels-2021-mbp/default.nix   modules/den/hosts/daniels-2021-mbp/default.nix
git mv modules/aspects/hosts/testvm/default.nix             modules/den/hosts/testvm/default.nix

# 12. Move host data files (secrets, facter, keys) to per-host folders
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

# testvm and daniels-2021-mbp: move what exists (secrets.yaml if present, etc.)

# 13. Move defaults
git mv modules/aspects/default.nix  modules/den/defaults.nix

# 14. Consolidate den.flakeModule imports: move the output bridge over the stub
git rm modules/flake/den.nix
git mv nix/den.nix modules/flake/den.nix
rmdir nix
# Update import-tree in modules/meta/flake-parts.nix: [ ./nix ./modules ] → [ ./modules ]

# 15. Remove namespace (no longer needed after "dlab" prefix eliminated)
git rm modules/namespace.nix

# 16. Clean up empty directories
rmdir modules/aspects/{hosts/builder,hosts/hvn-hyp1,hosts/daniels-2021-mbp,hosts/testvm,hosts}
rmdir modules/aspects/{profiles,secrets,services,nix,core}
rmdir modules/aspects
rmdir modules/schema
rmdir modules/security
rmdir modules/storage
rmdir modules/hosts/{builder,hvn-hyp1,testvm,daniels-2021-mbp}
rmdir modules/hosts

# 17. Remove stale pre-den files
git rm modules/lib/*.nix
git rm modules/hosts/builder/_configuration.nix modules/hosts/hvn-hyp1/_configuration.nix
git rm modules/hosts/daniels-2021-mbp/_configuration.nix modules/hosts/testvm/_default.nix

# 18. Regenerate flake
nix run .#write-flake --impure
nix flake check
```

### 4.7 SOPS Relative Paths: Verified Correct

The `sops.nix` currently at `modules/aspects/secrets/sops.nix` uses:

```nix
sops.defaultSopsFile = ./. + "/../../hosts/${config.networking.hostName}/secrets.yaml";
```

After moving to `modules/den/aspects/secrets/sops.nix`, the same literal path string `../../hosts/<name>/secrets.yaml` resolves from `modules/aspects/secrets/` depth 3 to `modules/den/aspects/secrets/` depth 3. The `../../` prefix walks up to `modules/den/`, then into `hosts/`. Both source file and target directory moved deeper by the same amount — the path string works unchanged. Same for facter.nix.

### 4.8 `shared/secrets.yaml`

CrowdSec enrollment key at repo root. After crowdsec moves to `modules/den/aspects/services/crowdsec.nix`, the reference `../../../shared/secrets.yaml` still resolves correctly.

**Commit:**

```
refactor: reorganize modules into den-native structure

File moves: core, disk, hardware, networking, roles, secrets,
services, quirks categories. Per-host folders co-locate entity
files and data. Mergerfs converted to den aspect with single
settings surface. Namespace module removed. nix/den.nix output
bridge consolidated into modules/flake/den.nix. Legacy files removed.

BREAKING: all den.aspects."dlab/profile/*" renamed to functional
category names.
```

**Deploy:** all hosts, one at a time.

---

## Phase 5: Group-Based User Model (Optional)

No fork dependencies. Builds on Phase 1. When Phase 1's per-host user duplication becomes unwieldy, Phase 5 adds user entities, group-based resolution, and per-user aspect files.

### When to Implement

The homelab has 3 users across 4 hosts. Phase 1's per-host data model is sufficient for most scenarios. Implement Phase 5 when:
- Users have different access levels per host (e.g., alice only on VMs)
- You want to define each user once and let policy resolve host membership
- You add users and per-host duplication becomes unwieldy

### Architecture

```
den.users.registry.<name> → groups → den.schema.host.system-access-groups
                                        ↓
                              den.policies.group-users matches by intersection
                                        ↓
                              resolve.to "user" creates user entities
                                        ↓
                              den.schema.user.includes fires:
                                - resolved-user-emitter (quirk)
                                - auto-include policy (den.aspects.<host>.<user>)
                                        ↓
                              den.batteries.define-user → Unix account
                              den.batteries.primary-user → wheel + networkmanager
```

### Reference Files

Each concept maps to a working implementation in sini's config:

| Concept | Sini reference |
|---------|---------------|
| Group entity declarations | `sini/modules/den/groups/default.nix` |
| User schema (identity, system) | `sini/modules/den/schema/user.nix` |
| User registry entries | `sini/modules/den/users/sini.nix` |
| Resolved-user-emitter quirk | `sini/modules/den/aspects/core/resolved-user-emitter.nix` (14 lines) |
| Auto-include policy | `sini/modules/den/defaults.nix:17-23` |
| Group-based resolution policy | `sini/modules/den/policies/users.nix` |
| Per-user aspect pattern | `sini/modules/den/users/sini.nix` |
| Schema wiring (includes/excludes) | `sini/modules/den/defaults.nix` |

### Key Snippet: Group-Based Resolution

The core logic — matching registry users to hosts by group intersection:

```nix
{ lib, den, config, ... }:
let
  inherit (den.lib.policy) resolve;
  registry = config.den.users.registry or { };

  matchUsers = hostAccessGroups:
    lib.filterAttrs (_: user:
      let userGroups = user.groups or [ ];
      in builtins.any (g: lib.elem g hostAccessGroups) userGroups
    ) registry;
in {
  den.schema.host.excludes = [ den.policies.host-to-users ];
  den.policies.group-users = { host, ... }:
    let accessGroups = host.system-access-groups or [ ];
    in map (u: resolve.to "user" { user = u; }) (builtins.attrValues (matchUsers accessGroups));
}
```

---

## Phase 6: Den-Native Refactors (Fork-Gated)

All features gated on `github:sini/den/feat/entity-gen-schema-port` merging into mainline.

### 6.1 Dynamic `settingsType` (sini pattern)

Auto-discovers aspect `.settings` declarations. Replaces Phase 2's manual `options.settings.*`. **Migration note:** add `den.reservedKeys = [ "settings" ]` to prevent pipeline dispatch; remove manual `options.settings` block from `den.schema.host`.

### 6.2 Environment Entities

`den.environments.home` / `den.environments.vms` with cascading defaults.

### 6.3 Settings Cascade (scope-engine)

`aspect defaults → environment → host → user` precedence chain.

---

## Verification Guidelines

### Per-Phase Deploy Table

| Phase | Target Hosts | Key Verification |
|-------|-------------|-----------------|
| 0.1 | builder + one other | GC timer inactive on builder, active elsewhere |
| 0.2 | builder | `which git bottom lnav` |
| 0.3 | builder | chrony log/drift file ownership |
| 0.4 | hvn-hyp1 | initrd extraBin tools present after reboot |
| 0.5 | hvn-hyp1 | mergerfs `/mnt/storage/media` mounts |
| 1 | builder | `id daniel` — user exists, SSH key present |
| 2 | builder + testvm | `nix eval ...config.settings` |
| 3 | builder | `nix eval ...config.environment.persistence."/persist".directories` |
| 4 | all hosts, one at a time | `nix run .#write-flake --impure && nix flake check` |
| 5 | testvm + hvn-hyp1 | alice on testvm but not hvn-hyp1 |

### Full Deploy Order (after Phase 5)

```bash
nix run .#write-flake --impure && nix flake check
deploy .#builder -- --impure
deploy .#hvn-hyp1 -- --impure
deploy .#testvm -- --impure
deploy .#daniels-2021-mbp -- --impure
```

---

## Den Source & Examples Guide

| Location | Content |
|----------|---------|
| `~/src/den/modules/aspects/batteries/*.nix` | Battery implementations |
| `~/src/den/modules/policies/core.nix` | Default host-to-users policy |
| `~/src/den/nix/lib/namespace-types.nix` | Schema submodule type |
| `~/src/den/nix/lib/entities/host.nix` | Host entity type |
| `~/src/den/nix/lib/resolve-entity.nix` | Entity resolution |
| `~/src/den/nix/lib/aspects/fx/assemble-pipes.nix` | Quirk pipe assembly |
| `~/src/den/nix/lib/aspects/fx/key-classification.nix` | Pipe key classification |
| `~/src/den/nix/lib/aspects/fx/aspect/normalize.nix:62-86` | `wrapBareFn` — bare functions in includes |
| `~/src/den/modules/options.nix:208-216` | `pipeSchemaType` (description-only) |
| `~/src/den-examples/sini/modules/den/aspects/core/nix.nix` | Nix aspect with os/nixos/darwin (111 lines) |
| `~/src/den-examples/sini/modules/den/defaults.nix` | Schema includes + auto-include policy (35 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/resolved-user-emitter.nix` | Resolved-user quirk (14 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/persist-collector.nix` | Persist collector (22 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/firewall-collector.nix` | Firewall collector (5 lines) |
| `~/src/den-examples/sini/modules/den/aspects/disk/impermanence.nix` | Impermanence + persist-collector include |
| `~/src/den-examples/sini/modules/den/quirks/impermanence.nix` | Description-only quirk declarations (6 lines) |
| `~/src/den-examples/sini/modules/den/hosts/bitstream.nix` | Host entity with settings and includes |

---

## v5 → v6 Changelog

| Issue | v5 | v6 |
|-------|----|----|
| Phase 1-3 file paths | Created at `modules/den/aspects/...` (directory doesn't exist yet) | Created at `modules/aspects/...`, Phase 4 moves them |
| Password in entity data | `hashedPasswordFile = config.sops...` (won't resolve) | Removed from entity data; derived in parametric nixos body |
| Anonymous fn in includes | Kept (correct) | Kept (verified against `wrapBareFn` source + sini usage) |
| MergerFS migration | "New file" + git mv conflict | git mv then edit (one file, no conflict) |
| `core.nix` wiring | Prose note only | Explicit `den.schema.host.includes` line in Phase 0.1 |
| `secretRequests` migration | Deleted without replacement path | Moved into parametric aspect's nixos body |
| `nix/den.nix` + `modules/flake/den.nix` | Duplicate imports | Consolidated into `modules/flake/den.nix`, `nix/` deleted, import-tree updated |
| Phase 5 | Full 10-subsection implementation | Reference table + 1 key snippet |
| Phase 0.1 explanation | None | Why it's complex (anti-pattern fix + GC fix) |
