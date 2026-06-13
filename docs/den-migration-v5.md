# Den Migration v5: Audit, Roadmap & Concepts

Pre-den baseline: `eea36b4^` (before "Initial den migration")
v4 baseline: `docs/den-migration-v4.md` (superseded)

---

## What Changed from v4

**Quirk declarations corrected.** v4's Phase 3.1 declared quirks with `type`, `default`, and complex submodule structures. Den's `pipeSchemaType` (`options.nix:208-216`) only accepts `{ description = "..."; }`. v5 fixes all quirk declarations to be description-only, matching both the type system and sini's actual usage.

**Nix aspect made parametric for per-host GC.** v4's Phase 0.1 gated GC on `config.settings.core.nix.gc.enable` — but `config` inside a non-parametric class body is NixOS module config, not entity settings. v5 makes the `os` body parametric (`{ host, lib, ... }:`) so it can read `host.settings.core.nix.gc.enable` from the host entity.

**Persist-collector scoped to impermanence hosts.** v4's Phase 3.4 wired `persist-collector` globally via `den.schema.host.includes`, causing it to fire on all hosts including the ext4 `testvm`. This would fail because `environment.persistence` doesn't exist without the impermanence module. v5 follows sini's pattern: `persist-collector` is included by the `disk.impermanence` aspect (via `disk/impermanence.nix:9-11`), not globally. The `firewall-collector` remains global because firewall rules can come from any aspect.

**SOPS path explanation corrected.** v4's Phase 4.7 claimed "no path string changes needed." The relative path string `../../hosts/<name>/secrets.yaml` happens to work from both old and new locations only because both the aspect file and the data directory moved together. v5 explains this correctly.

**MergerFS aspect has single settings surface.** v4's Phase 4.2 declared `settings.options.pools` AND a duplicate `options.mergerfs` NixOS option inside the `nixos` body. v5 consolidates to a single `settings` declaration read from `host.settings`.

**Phase 1 simplified to parametric users from host entity data.** v4's Phase 1 was a full user registry + group entities + auto-include policy + resolved-user-emitter (~200 lines across 8 new files). For the homelab's 3 users across 4 hosts, v5 declares typed `users` options on the host schema and uses a single parametric aspect to create accounts. The full group-based model moves to Phase 5 as optional advanced work.

**`den.reservedKeys` not needed for core den.** v4's fork dependency map noted `reservedKeys` as fork-only but didn't explain why it matters. In the fork, `den.reservedKeys = [ "settings" ]` prevents the pipeline from classifying aspect-level `settings` keys as unregistered class keys. In core den, settings are declared via `den.schema.host.options.*` (not as aspect top-level keys), so no reserved key is needed. Phase 6 notes this for future fork migration.

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
| Manual settings via `den.schema.host.options.*` | Core den | Used in Phases 0.1, 2 |
| `den.reservedKeys` | Fork only | Not needed (manual settings don't need it) |
| Dynamic `settingsType` auto-discovery | Fork only | Phase 6 gated |
| `scope-engine` settings cascade | Fork only | Phase 6 gated |
| `gen-schema` methods/refs | Fork only | Blocks environment entities |
| `scope-engine` ACL | Fork only | Not needed |
| `den.lib.policy.instantiate` | Fork only | Homelab uses manual `nix/den.nix` output bridge |

**Bottom line:** Every actionable phase (0-5) uses core den features only. Phase 6 is aspirational and gated on the sini fork. When migrating to the fork, add `den.reservedKeys = [ "settings" ]` (see Phase 6 notes).

---

## How `den.schema.host` Function + `.includes` Coexist

(Unchanged from v4 — this mechanism is verified correct.)

`den.schema` is a `lib.types.submodule` with `freeformType = lib.types.lazyAttrsOf lib.types.deferredModule` (`namespace-types.nix:13`). The function `{ host, lib, ... }: { options = ...; }` is the **deferred module value** for the `host` submodule entry. `.includes` and `.imports` are **data attributes** on the same entry. Because both live under the same lazy submodule key, Nix's module system merges them without conflict.

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

---

## Phase 0: Fix Regressions

Fix and deploy immediately. All use existing file locations (pre-Phase-4 reorg).

### 0.1 Nix Config: Parametric Den Aspect with Per-Host GC

**Current problem:** `modules/aspects/nix/default.nix` writes `den.default.nixos` (120 lines) — the same anti-pattern as the hardcoded user. GC is commented out. The nix config should be a proper den aspect that can read per-host settings.

**Target:** `den.aspects.core.nix` as a parametric aspect with GC controlled by `host.settings.core.nix.gc.enable` (default `true`). Builder disables it.

**File:** `modules/aspects/nix/default.nix` — replace entire file:

```nix
{ lib, config, ... }: {
  den.aspects.core.nix = {
    # Platform-agnostic: both NixOS and Darwin
    # PARAMETRIC so host.settings is accessible
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

**File:** `modules/aspects/hosts/builder/default.nix` — add `settings.core.nix.gc.enable = false` to the entity data:

```nix
den.hosts.aarch64-linux.builder = {
  settings.core.nix.gc.enable = false;
  # ... existing entity data
};
```

**Note:** `den.aspects.core.nix` must be wired into `den.schema.host.includes` (or `den.default.includes`) so the parametric body receives the `host` entity arg. See Phase 4 wiring.

**Commit:**

```
fix: convert nix config to parametric den aspect with per-host GC

Replace den.default.nixos nix config with den.aspects.core.nix.
Uses os/nixos/darwin class bodies (sini pattern). os body is
parametric so it can read host.settings.core.nix.gc.enable.

GC is now a host entity setting (default true). Builder disables
it because its small disk is managed via impermanence rollbacks.

New setting path: host.settings.core.nix.gc.enable
```

**Deploy:** `deploy .#builder -- --impure` then any other host. GC timer should be inactive on builder, active elsewhere.

---

### 0.2 Missing base packages + vim

(Unchanged from v4.)

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

(Unchanged from v4.)

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

(Unchanged from v4.)

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

## Phase 1: Parametric Users from Host Entity Data

No fork dependencies. All core den.

This is a **simplified** model: users are typed entity data on hosts, and a parametric aspect creates Unix accounts. No user registry, no group entities, no user-scope resolution. The full group-based model is deferred to Phase 5.

### 1.1 Declare `users` Option on Host Schema

**File:** `modules/schema/host.nix` — add `users` option:

```nix
den.schema.host = { host, lib, ... }: {
  # ... existing zfs, networking options ...

  options.users = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        sshKeys = lib.mkOption {
          type = lib.types.listOf lib.types.path;
          default = [ ];
          description = "Paths to SSH public key files for this user";
        };
        hashedPasswordFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to the SOPS-decrypted hashed password file";
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
den.schema.host.includes = [
  den.aspects."dlab/profile/time"
  den.aspects."dlab/profile/networking"
  den.aspects.core.nix

  # Parametric: creates Unix accounts from host.users entity data
  ({ host, lib, config, ... }: let
    readKeyFile = path:
      lib.strings.trim (if lib.isPath path then builtins.readFile path else path);
  in {
    nixos = lib.mkIf (host.users != { }) (lib.mkMerge (
      lib.mapAttrsToList (name: userCfg: {
        users.users.${name} = lib.mkMerge [
          {
            isNormalUser = true;
            extraGroups = userCfg.extraGroups;
          }
          (lib.mkIf (userCfg.sshKeys != [ ]) {
            openssh.authorizedKeys.keys =
              lib.filter (k: k != "") (lib.concatMap (path: lib.splitString "\n" (readKeyFile path)) userCfg.sshKeys);
          })
          (lib.mkIf (userCfg.hashedPasswordFile != null) {
            hashedPasswordFile = userCfg.hashedPasswordFile;
          })
        ];
      }) host.users
    ));
  })
];
```

### 1.3 Remove Hardcoded User

**File:** `modules/aspects/default.nix` — remove the hardcoded user block:

Delete all of:
- `users.users.daniel = { ... }` block in `den.default.nixos.config`
- `secretRequests."users/daniel/hashedPassword"` entry
- The inline SSH key battery in `den.default.includes` (replaced by parametric aspect above)

### 1.4 Update Host Entity Data

Builder and hvn-hyp1 already have `users.daniel.sshKeys = [ ... ]` in their entity data. Add `hashedPasswordFile` and `extraGroups`:

```nix
# modules/aspects/hosts/builder/default.nix
den.hosts.aarch64-linux.builder = {
  users.daniel = {
    sshKeys = [ ../../../hosts/builder/ssh.pub ];
    hashedPasswordFile = config.sops.secrets."users/daniel/hashedPassword".path;
    extraGroups = [ "wheel" ];
  };
  # ... rest of entity data ...
};
```

**Commit:**

```
feat: parametric user accounts from typed host entity data

Declares options.users on den.schema.host with typed submodule
(sshKeys, hashedPasswordFile, extraGroups, packages). A parametric
aspect in den.schema.host.includes creates NixOS user accounts.

Removes hardcoded users.users.daniel from den.default.nixos.
```

**Deploy:** `deploy .#builder -- --impure` to verify daniel still resolves.

---

## Phase 2: Settings on Aspects

No fork dependencies. Manual settings via schema function pattern.

### 2.1 Declare Settings on Host Schema

Settings are accumulated across phases. Phase 0.1 added `settings.core.nix.gc.enable`. Phase 2 adds the remaining per-host options:

**File:** `modules/schema/host.nix` — extend the schema function:

```nix
den.schema.host = { host, lib, ... }: {
  # ... existing zfs, networking, users options ...
  # ... Phase 0.1 settings.core.nix.gc.enable already declared ...

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

Note: `settings.core.nix.gc.enable` from Phase 0.1 is declared separately (before the full `settings` submodule was added). Since all `options.settings.*` nodes merge into a single `settings` submodule, this works but must be noted: future cleanup could consolidate into one `options.settings` declaration block.

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
```

**Deploy:** `deploy .#builder -- --impure` and `deploy .#testvm -- --impure` to verify settings resolve.

---

## Phase 3: Quirks

No fork dependencies. All pipe mechanics are core den (`key-classification.nix:41` — `pipeRegistry = den.quirks or { }`).

### 3.1 Declare Quirk Types (DESCRIPTION ONLY)

Den's `pipeSchemaType` only accepts `{ description = "..."; }`. Quirks are **data routes** — the type of data flowing through them is implicit (whatever the emitter returns, collected as `lib.types.raw` lists).

**New file:** `modules/den/aspects/quirks/persist.nix`

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

Aspects emit data by declaring attributes matching the quirk name (NOT `pipe.` — the quirk name itself is the key):

**File:** `modules/den/aspects/hardware/hypervisor.nix`

```nix
# Before (v4 used pipe.persist — wrong)
persist.directories = [{ directory = "/var/lib/incus"; }];

# After (v5 — correct)
persist = [
  { directory = "/var/lib/incus"; user = "incus"; group = "incus"; }
];
```

**File:** `modules/den/aspects/core/time.nix`

```nix
persist = [
  { directory = config.services.chrony.directory; user = chrony; group = chrony; }
  { directory = logDir; user = chrony; group = chrony; }
];
```

Note: the quirk key on the aspect must match the declared quirk name (e.g., `persist` maps to `den.quirks.persist`). These are NOT nested under `pipe.*` — the key classification system (`classifyKeys`) matches aspect keys against `den.quirks` directly.

### 3.3 Collector Aspects

Collectors receive assembled quirk data as function args. Their arg names match quirk names.

**New file:** `modules/den/aspects/core/persist-collector.nix`

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

**New file:** `modules/den/aspects/core/firewall-collector.nix`

```nix
_: {
  den.aspects.core.firewall-collector = {
    nixos = { firewall, lib, ... }: lib.mkMerge firewall;
  };
}
```

### 3.4 Wire Collectors (CORRECTED)

**Critical difference from v4:** `persist-collector` must be included by the impermanence aspect, not globally. Firewall-collector stays global.

**File:** `modules/den/aspects/disk/impermanence.nix` — the impermanence aspect includes its collector:

```nix
den.aspects.disk.impermanence = {
  includes = [
    den.aspects.core.persist-collector
  ];
  # ... rest of aspect ...
};
```

**File:** `modules/den/defaults.nix` (or `modules/aspects/default.nix` pre-reorg) — add to `den.schema.host.includes`:

```nix
den.schema.host.includes = [
  den.aspects.core.time
  den.aspects.networking.default
  den.aspects.core.firewall-collector   # ← global: all hosts
  # persist-collector NOT here — wired via impermanence aspect includes
];
```

Rationale: `environment.persistence` is an option provided by the impermanence module. On hosts without impermanence (like `testvm` with ext4), the collector would fail. Firewall-collector is safe globally because `networking.firewall` exists on all NixOS hosts.

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
Collectors wired correctly: persist-collector via impermanence
aspect includes, firewall-collector globally via host schema includes.
Aspects emit into quirk-named keys directly.
```

**Deploy:** `deploy .#builder -- --impure` to verify quirk pipes collect correctly.

---

## Phase 4: Rename & Reorganize

(Structure largely unchanged from v4, with mergerfs and SOPS path fixes noted below.)

### 4.1 Host Directory Structure

Per-host folders under `modules/den/hosts/<name>/` containing both the entity+aspect file and data files:

```
modules/den/hosts/
  builder/
    default.nix          — den.hosts.aarch64-linux.builder + den.aspects.builder
    secrets.yaml          — SOPS encrypted secrets
    facter.json           — nixos-facter hardware report
    ssh.pub               — user SSH public key
    known_hosts           — SSH host keys for deploy-rs
    boot_host_key.pub     — initrd SSH host key
    runtime_host_key.pub  — runtime SSH host key
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

**Why co-located:** Entity definition, aspect configuration, secrets, and hardware report all live together. One directory per host = one delete/archive operation.

### 4.2 MergerFS as a Den Aspect (FIXED)

v4's target code declared `settings.options.pools` AND a duplicate `options.mergerfs` NixOS option. v5 uses a single settings surface read from `host.settings`:

**New file:** `modules/den/aspects/services/mergerfs.nix`

```nix
{ lib, pkgs, config, ... }: {
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
    nixos = { config, pkgs, lib, ... }: let
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
      # ... (rest of mergerfs systemd service definitions from original module)
    ]);
  };
}
```

Host entity data uses `host.settings.services.mergerfs.pools`:

```nix
den.hosts.x86_64-linux.hvn-hyp1 = {
  settings.services.mergerfs.pools."/mnt/storage/media" = {
    branches = [ "/mnt/storage-clear/media1" "/mnt/storage-clear/media3" ];
  };
};
```

### 4.3 Namespace: Remove, Don't Rename

The current `modules/namespace.nix` declares `inputs.den.namespace "dlab" false`. After the Phase 4 rename, all aspects move from `den.aspects."dlab/profile/..."` to `den.aspects.core.*`, `den.aspects.disk.*`, etc. The namespace prefix `"dlab"` is no longer used. **Remove `modules/namespace.nix` entirely** once all aspect references are migrated.

### 4.4 Target Directory Structure

```
modules/
  den/
    defaults.nix                     — den.default + schema includes + collectors
    flake-parts.nix                  — den integration
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
        impermanence.nix
        remote-unlock.nix
        persist-collector.nix
        firewall-collector.nix
      features/
        ssh-keys.nix                 — optional, for Phase 5 advanced user model
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
      users/                         — for Phase 5 advanced user model
        registry.nix
        daniel.nix
        alice.nix
      groups/                        — for Phase 5 group-based model
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
    policies/                        — for Phase 5 group-based model
      users.nix

  meta/
    flake-parts.nix
    inputs.nix
    pkgs.nix
    systems.nix

  flake/
    deploy-rs.nix
    formatter.nix
    sops.nix
    den.nix                         — den.flakeModule import

  nix/
    den.nix                         — manual output bridge
    caches.nix
    flakes.nix
    optimise.nix
    sensible.nix
    unfree.nix

  packages/
    initrd.nix
    install-on-envoy.nix

  storage/                           — EMPTY after mergerfs moved
    # (mergerfs.nix moved to modules/den/aspects/services/mergerfs.nix)

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
| Host aspect `den.aspects.builder` | `den.aspects.builder` (unchanged) | hosts |

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
git mv modules/aspects/profiles/impermanence.nix     modules/den/aspects/disk/impermanence.nix
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

# 12. Move defaults
git mv modules/aspects/default.nix  modules/den/defaults.nix

# 13. Remove namespace (no longer needed after "dlab" prefix eliminated)
git rm modules/namespace.nix

# 14. Create new files (Phase 1-3 artifacts, created in earlier phases)
# modules/den/aspects/quirks/persist.nix
# modules/den/aspects/core/persist-collector.nix
# modules/den/aspects/core/firewall-collector.nix
# modules/den/aspects/disk/zfs.nix
# modules/den/aspects/disk/ext4.nix
# modules/den/aspects/roles/vm.nix

# 15. Clean up empty directories
rmdir modules/aspects/{hosts/builder,hosts/hvn-hyp1,hosts/daniels-2021-mbp,hosts/testvm,hosts}
rmdir modules/aspects/{profiles,secrets,services,nix}
rmdir modules/aspects
rmdir modules/schema
rmdir modules/security
rmdir modules/storage
rmdir modules/hosts/{builder,hvn-hyp1,testvm,daniels-2021-mbp}
rmdir modules/hosts

# 16. Remove stale pre-den files
git rm modules/lib/asserts.nix modules/lib/default.nix modules/lib/dlab.nix modules/lib/dsl.nix modules/lib/utilities.nix
git rm modules/hosts/builder/_configuration.nix modules/hosts/hvn-hyp1/_configuration.nix
git rm modules/hosts/daniels-2021-mbp/_configuration.nix modules/hosts/testvm/_default.nix

# 17. Regenerate flake
nix run .#write-flake --impure
```

### 4.7 SOPS Relative Paths: Verified Correct

The sops.nix file currently at `modules/aspects/secrets/sops.nix` uses:

```nix
sops.defaultSopsFile = ./. + "/../../hosts/${config.networking.hostName}/secrets.yaml";
```

After moving to `modules/den/aspects/secrets/sops.nix`, the same relative path string `../../hosts/<name>/secrets.yaml` resolves from depth 3 to depth 3, now landing at `modules/den/hosts/<name>/secrets.yaml`. This is correct because:

| File | Old location | New location | `../../hosts/` resolves to | Target |
|---|---|---|---|---|
| sops.nix | `modules/aspects/secrets/` | `modules/den/aspects/secrets/` | `modules/hosts/` | `modules/den/hosts/<name>/secrets.yaml` |
| facter.nix | `modules/aspects/profiles/` | `modules/den/aspects/core/` | `modules/hosts/` | `modules/den/hosts/<name>/facter.json` |

The `../../` prefix walks from the aspect file up to `modules/den/`, then into `hosts/`. The same literal path string works from both old and new locations because both the source file and the target directory moved deeper by the same amount. **No path string changes needed.**

### 4.8 `shared/secrets.yaml`

(Unchanged from v4.) CrowdSec enrollment key at `shared/secrets.yaml` at the repo root. After crowdsec moves to `modules/den/aspects/services/crowdsec.nix`, the reference `../../../shared/secrets.yaml` still resolves correctly.

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
Mergerfs converted to den.aspects.services.mergerfs with single
settings surface. Namespace module removed — "dlab" prefix eliminated.
All legacy pre-den files and empty directories removed.

BREAKING: all den.aspects."dlab/profile/*" renamed to
functional category names (core.*, disk.*, etc.).
```

**Deploy:** `deploy .#builder -- --impure`, then `deploy .#hvn-hyp1 -- --impure`, then remaining hosts.

---

## Phase 5: Group-Based User Model (Advanced, Optional)

No fork dependencies. Builds on Phase 1's parametric users by adding user entities, groups, and resolution policy. Deployable independently — Phase 1 users continue working alongside this.

### 5.1 When to Implement

The homelab has 3 users (daniel, alice, bob) across 4 hosts. If all users go on all hosts, Phase 1's per-host data model is simpler and sufficient. Implement Phase 5 when:
- Users have different access levels per host (e.g., alice gets account on testvm but not hvn-hyp1)
- You want to define users once and let policy resolve them onto hosts
- You add more users and per-host duplication becomes unwieldy

### 5.2 Group Entities

**New file:** `modules/den/aspects/groups/default.nix`

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

### 5.3 Extend Host Schema

**File:** `modules/den/schema/host.nix` — add:

```nix
options.system-access-groups = lib.mkOption {
  type = lib.types.listOf lib.types.str;
  default = [ "system-access" ];
  description = "Groups granted Unix account access on this host";
};
```

### 5.4 Extend User Schema

**File:** `modules/den/schema/user.nix` — replace:

```nix
{ lib, ... }: {
  den.schema.user = { lib, ... }: {
    config.classes = lib.mkDefault [ "homeManager" ];

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
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      primaryUser = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
  };
}
```

### 5.5 User Registry + Per-User Aspects

**New file:** `modules/den/aspects/users/daniel.nix`

```nix
{ den, lib, config, ... }: let
  readAsStr = v: lib.strings.trim (if lib.isPath v then builtins.readFile v else v);
in {
  den.users.registry.daniel = {
    groups = [ "admins" ];
    primaryUser = true;
    identity = {
      displayName = "Daniel Vicory";
      email = "daniel@vicory.com";
      sshKeys = [
        { tag = "laptop"; key = readAsStr ./../../../hosts/builder/ssh.pub; }
      ];
    };
  };

  den.aspects.daniel = {
    includes = [
      den.batteries.primary-user
      (den.batteries.user-shell "zsh")
    ];
    nixos = { pkgs, ... }: {
      users.users.daniel.packages = with pkgs; [ git bottom lnav vim ];
    };
    policies.to-hosts = { host, user, ... }:
      lib.optional (host ? users.${user.name}) (
        den.lib.policy.provide {
          class = "nixos";
          module = {
            users.users.${user.name} = {
              hashedPasswordFile = config.sops.secrets."${user.name}/hashedPassword".path;
              isNormalUser = true;
            };
          };
        }
      );
  };
}
```

### 5.6 Resolved-User Emitter Quirk

**New file:** `modules/den/aspects/core/resolved-user-emitter.nix`

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

### 5.7 Auto-Include Policy

**File:** `modules/den/defaults.nix` — add to `den.schema.user.includes`:

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

### 5.8 Group-Based Resolution Policy

**New file:** `modules/den/policies/users.nix`

```nix
{ lib, den, config, ... }:
let
  inherit (den.lib.policy) resolve;
  registry = config.den.users.registry or { };

  matchUsers = hostAccessGroups:
    builtins.attrValues (
      lib.filterAttrs (_: user:
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
    in map (u: resolve.to "user" { user = u; }) matched;
}
```

### 5.9 Update Runtime Wiring

**File:** `modules/den/defaults.nix` — ensure :

```nix
den.default.includes = [
  den.batteries.hostname
  den.batteries.define-user
  den.batteries.primary-user
];
```

### 5.10 Phase 5 Verify

```bash
nix flake check
nix eval .#nixosConfigurations.testvm.config.users.users.alice.isNormalUser
nix eval .#nixosConfigurations.hvn-hyp1.config.users.users.alice
nix eval .#nixosConfigurations.builder.config.users.users.daniel.isNormalUser
```

---

## Phase 6: Den-Native Refactors (Fork-Gated)

All features gated on `github:sini/den/feat/entity-gen-schema-port` merging into mainline `github:denful/den`.

### 6.1 Dynamic `settingsType` (sini pattern)

Auto-discovers aspect `.settings` declarations and creates host entity options without manual schema wiring. Replaces the manual `options.settings.*` declared in Phase 2.

**Migration note:** When adopting the fork, add `den.reservedKeys = [ "settings" ]` to prevent the pipeline from classifying aspect-level `settings` keys as unregistered class keys. Remove the manual `options.settings` block from `den.schema.host`.

### 6.2 Environment Entities (sini pattern)

```
den.environments.home — cascades defaults to bare-metal hosts
den.environments.vms  — cascades defaults to VMs
```

### 6.3 Settings Cascade (scope-engine)

`aspect defaults → environment → host → user` precedence chain.

---

## Verification Guidelines

### Per-Phase Commit + Deploy Table

| Phase | Commit | Title | Deploy Target |
|-------|--------|-------|--------------|
| 0.1 | `fix` | convert nix config to parametric den aspect with per-host GC | builder + one other |
| 0.2 | `fix` | restore missing base packages and vim | builder |
| 0.3 | `fix(chrony)` | add user/group ownership to persist directories | builder |
| 0.4 | `fix(remote-unlock)` | restore initrd debugging tools | hvn-hyp1 |
| 0.5 | `fix(hvn-hyp1)` | wire mergerfs storage pool | hvn-hyp1 |
| 1 | `feat` | parametric user accounts from typed host entity data | builder |
| 2 | `feat` | add per-host settings with hasAspect replacements | builder + testvm |
| 3 | `feat` | adopt den quirks for persist, firewall, and resolved-users | builder |
| 4 | `refactor` | reorganize modules into den-native structure | all hosts, one at a time |
| 5 | `feat` (optional) | group-based user resolution policy | testvm + hvn-hyp1 |

### Full System Deploy Order (After Phase 5)

```bash
nix run .#write-flake --impure
nix flake check
deploy .#builder -- --impure
deploy .#hvn-hyp1 -- --impure
deploy .#testvm -- --impure
deploy .#daniels-2021-mbp -- --impure
```

---

## Migration Reference

| Den Path | Purpose | Phase | Fork? | Status |
|----------|---------|-------|-------|--------|
| `den.default.nixos` | Global NixOS defaults | — | Core | stateVersion, SSH, mutableUsers, emergencyAccess |
| `den.default.includes` | Global batteries | 1 | Core | hostname, define-user |
| `den.schema.host` | Host entity metadata | 0.1, 1, 2, 5 | Core | zfs, networking, users, settings |
| `den.schema.host.includes` | Auto-applied aspects | 0.1, 1, 3 | Core | core.nix, users parametric, firewall-collector |
| `den.schema.host.excludes` | Excluded policies | 5 | Core | host-to-users |
| `den.schema.user` | User entity metadata | 5 | Core | identity, system |
| `den.schema.user.includes` | Auto-include policies | 5 | Core | resolved-user-emitter + auto-include |
| `den.aspects.core.*` | Core system aspects | 4 | Core | 10+ aspects including collectors |
| `den.aspects.disk.*` | Filesystem aspects | 4 | Core | zfs, ext4, impermanence |
| `den.aspects.hardware.*` | Hardware enablement | 4 | Core | hypervisor |
| `den.aspects.networking.*` | Networking | 4 | Core | default |
| `den.aspects.services.*` | Service daemons | 4 | Core | crowdsec, mergerfs |
| `den.aspects.secrets.*` | Secret providers | 4 | Core | sops, hardcoded |
| `den.aspects.roles.*` | Composite roles | 4 | Core | server, vm |
| `den.aspects.quirks.*` | Quirk declarations | 3 | Core | persist, persistHome, cache, firewall, resolved-users |
| `den.users.registry` | User declarations | 5 | Core | daniel, alice |
| `den.groups.*` | Group entities | 5 | Core | admins, system-access, vm-access, etc. |
| `den.policies.group-users` | Group-based resolution | 5 | Core | Replace default host-to-users |
| `den.batteries.define-user` | User account creation | 1, 5 | Core | ✅ |
| `den.batteries.hostname` | Hostname from entity | — | Core | ✅ |
| `den.batteries.primary-user` | Admin user | 5 | Core | Per-user includes |
| `den.batteries.user-shell` | Default shell | 5 | Core | Per-user includes |
| `den.quirks.*` | Pipe data | 3 | Core | description-only declarations |
| `host.hasAspect` | Structural detection | 2 | Core | Replace null checks |
| `host.settings.*` | Per-host configuration | 0.1, 2 | Core | Manual schema wiring |
| `os` class | Cross-platform | 0.1 | Core | nix, ssh-keys aspects |
| Dynamic `settingsType` | Auto-discovered settings | 6 | Fork | Fork-gated |
| Environment entities | Env defaults/cascade | 6 | Fork | Fork-gated |
| `scope-engine` | Settings cascade | 6 | Fork | Fork-gated |

---

## Den Source & Examples Guide

| Location | What's There |
|----------|--------------|
| `~/src/den/modules/aspects/batteries/*.nix` | Battery implementations |
| `~/src/den/modules/policies/core.nix` | Default host-to-users policy |
| `~/src/den/nix/lib/namespace-types.nix` | Schema submodule type (deferredModule + lazyAttrsOf) |
| `~/src/den/nix/lib/entities/host.nix` | Host entity type definition |
| `~/src/den/nix/lib/resolve-entity.nix` | Entity resolution (reads schema.includes/excludes) |
| `~/src/den/nix/lib/aspects/fx/assemble-pipes.nix` | Quirk pipe assembly |
| `~/src/den/nix/lib/aspects/fx/key-classification.nix` | Pipe key classification |
| `~/src/den/modules/options.nix:208-216` | `pipeSchemaType` definition (description-only) |
| `~/src/den/templates/example/modules/aspects/alice.nix` | Per-user aspect with cross-scope policy |
| `~/src/den/templates/example/modules/aspects/hasAspect-examples.nix` | hasAspect worked examples |
| `~/src/den-examples/sini/modules/den/defaults.nix` | Sini defaults patterns (35 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/nix.nix` | Nix aspect with os/nixos/darwin (111 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/resolved-user-emitter.nix` | Resolved-user quirk (14 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/persist-collector.nix` | Persist collector (22 lines) |
| `~/src/den-examples/sini/modules/den/aspects/core/firewall-collector.nix` | Firewall collector (5 lines) |
| `~/src/den-examples/sini/modules/den/aspects/disk/impermanence.nix` | Impermanence aspect with persist-collector include |
| `~/src/den-examples/sini/modules/den/quirks/impermanence.nix` | Quirk declarations (description-only, 6 lines) |
| `~/src/den-examples/sini/modules/den/hosts/bitstream.nix` | Host entity with settings and includes |

---

## Concept Deep-Dives

### Quirks: The Corrected Flow

1. **Declaration:** `den.quirks.persist.description = "..."` — registered in `pipeRegistry` (`key-classification.nix:41`)
2. **Emission:** Aspect declares `persist = [ ... ]` (NOT `pipe.persist` — the quirk name matches directly)
3. **Assembly:** `assemblePipes.nix` collects all `persist` values across aspects per entity scope
4. **Delivery:** Collector receives assembled list via function args: `{ persist, cache, lib, ... }`
5. **Transform:** Collector merges into `environment.persistence`

Collectors must be wired either globally via `den.schema.host.includes` (for collectors that don't depend on optional modules) or via the aspect that provides the underlying module (for collectors that do, e.g., persist-collector via impermanence).

### Parametric Aspects and `host.settings`

Aspects receive entity args (`host`, `user`) when fired in entity scope. The `os` class shorthand requires the `os-to-host` policy (built into core den) which routes `os` class content into the host's actual class (`nixos` or `darwin`). When the `os` body is a function `{ host, lib, ... }:`, `host` is resolved from the entity context and the remaining args come from the module system.

### How Users Reach Hosts (Phase 5 Advanced Model)

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
```

### Schema Function + `.includes` Coexistence

See dedicated section at top of document.

---

## Quick Start

1. **Phase 0** — fix bugs, deploy immediately
2. **Phase 1** — parametric users from typed host entity data
3. **Phase 2** — manual settings, `hasAspect`, `os` shorthand
4. **Phase 3** — quirks, collectors, remove `persist.directories` option
5. **Phase 4** — file moves, per-host folders, mergerfs aspect, remove namespace, `write-flake`
6. **Phase 5** — group-based user model (optional, deferred)
7. **Phase 6** — fork-gated

---

## v4 → v5 Changelog

| Issue | v4 | v5 |
|-------|----|----|
| Quirk declarations | `type` + `default` + submodule (invalid) | `description` only (matches `pipeSchemaType`) |
| Nix aspect GC access | `config.settings.core.nix.gc.enable` (NixOS config, not entity) | `host.settings.core.nix.gc.enable` (parametric `os` body) |
| Persist-collector wiring | `den.schema.host.includes` (global, breaks testvm) | `disk.impermanence.includes` (scoped, sini pattern) |
| Firewall-collector wiring | `den.schema.host.includes` (global) | same (correctly global) |
| SOPS path explanation | "no path string changes" (misleading) | explained: same literal path works because both moved |
| MergerFS option surface | `settings.options.pools` + duplicate `options.mergerfs` | Single `settings.options.pools` read from `host.settings` |
| Phase 1 user model | Full group registry + entities (~200 lines, 8 files) | Simple parametric users (~30 lines, 2 modifications) |
| Phase 5 | Group-based policies (mandatory) | Advanced optional model (deferred) |
| Namespace | Change `false` to `true` | Remove entirely (prefix eliminated by rename) |
| `reservedKeys` | "skip" without explanation | Correctly noted as fork-only, not needed for manual settings |
