# Den Migration: Audit & Roadmap

Pre-den baseline: `eea36b4^` (before "Initial den migration")
Post-den: current HEAD

---

## Contents

- [Phase 0: Fix Regressions](#phase-0-fix-regressions) — bugs, deploy now
- [Phase 1: Rename & Reorganize](#phase-1-rename--reorganize) — file moves, no logic changes
- [Phase 2: Adopt Den Batteries](#phase-2-adopt-den-batteries) — small improvements
- [Phase 3: Structural Gaps](#phase-3-structural-gaps) — major missing patterns
- [Phase 4: Den-Native Refactors](#phase-4-den-native-refactors) — aspirational
- [Migration Reference](#migration-reference)
- [Cross-Example Findings](#cross-example-findings-9-den-users-surveyed)
- [Den Source & Examples Guide](#den-source--examples-guide)

---

## Legend

| Icon | Meaning |
|------|---------|
| 🔴 | Bug / regression (blocking) |
| 🟡 | Working but suboptimal |
| ✅ | Correctly migrated |
| ➕ | New capability post-den |
| 🐚 | Pattern from sini's config |

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

## Phase 2: Adopt Den Batteries

Small, safe improvements that replace hand-written config with den batteries.

### 1.1 Replace hardcoded `extraGroups` with `<den/primary-user>`

**Current** — `modules/aspects/default.nix`:
```nix
users.users.daniel = {
  hashedPasswordFile = ...;
  isNormalUser = true;
  extraGroups = [ "wheel" ];      # hardcoded
};
```

**Target** — Add to `den.default.includes`:
```nix
den.default.includes = [
  den.batteries.hostname
  den.batteries.mutual-provider
  den.batteries.define-user
  den.batteries.primary-user      # ← ADD
  ({ host, user }: { ... })       # SSH keys closure
];
```

`primary-user` adds `wheel` + `networkmanager` on NixOS, `system.primaryUser` on Darwin, `defaultUser` on WSL. See `~/src/den/modules/aspects/batteries/primary-user.nix`.

Then remove `extraGroups = [ "wheel" ]` from `default.nix`.

**Reference:** `~/src/den/templates/example/modules/aspects/alice.nix:36`

---

### 1.2 Consolidate SSH enable

**File:** `modules/aspects/profiles/networking.nix:23`

```nix
services.openssh.enable = lib.mkDefault true;  # ← DELETE
```

This is already set in `modules/aspects/default.nix` alongside the full SSH config.

---

## Phase 3: Structural Gaps

These are the big missing pieces that prevent the config from being "den-native."

### 2.1 🔴 Parametric User Setup

**Current** — User config is hardcoded in `den.default.nixos`:
```nix
# modules/aspects/default.nix
users.users.daniel = {
  hashedPasswordFile = config.sops.secrets."users/daniel/hashedPassword".path;
  isNormalUser = true;
  extraGroups = [ "wheel" ];
};
secretRequests."users/daniel/hashedPassword" = { ... neededForUsers = true; };
```

This is wrong because:
- It only works for one user ("daniel")
- It's not parametric — can't read from host entity data
- Adding another user requires editing this file

**Den target** — Per-user aspect with cross-scope policy (from example template):

**Reference:** `~/src/den/templates/example/modules/aspects/alice.nix`

```nix
# modules/aspects/users/daniel.nix  (new file)
{ den, lib, config, ... }: {
  den.aspects.daniel = {
    includes = [
      <den/primary-user>
      (<den/user-shell> "zsh")
      den.aspects.daniel.policies.to-hosts
    ];

    nixos = { pkgs, ... }: {
      users.users.daniel.packages = [ pkgs.vim ];
    };

    # Cross-scope: push NixOS config to any host daniel is on
    policies.to-hosts =
      { host, user, ... }:
      lib.optional (host ? users.${user.userName}) (
        den.lib.policy.provide {
          class = "nixos";
          module = {
            secretRequests."${user.userName}/hashedPassword" = {
              mode = "0400";
              owner = "root";
              neededForUsers = true;
            };
            users.users.${user.userName}.hashedPasswordFile =
              config.sops.secrets."${user.userName}/hashedPassword".path;
          };
        }
      );
  };
}
```

Then **remove** from `modules/aspects/default.nix`:
- `users.users.daniel` block
- `secretRequests."users/daniel/hashedPassword"` entry
- `extraGroups = [ "wheel" ]`

---

### 2.2 🔴 User Registry Pattern (sini-inspired) 🐚

**Current** — SSH keys are on the host entity via `den.hosts.*.users.daniel.sshKeys`:
```nix
den.hosts.aarch64-linux.builder = {
  users.daniel = {
    sshKeys = [ ../../../hosts/builder/ssh.pub ];
  };
};
```

**Sini pattern** — sini uses a standalone `den.users.registry` with rich user schema:
```nix
den.users.registry.sini = {
  system.uid = 1000;
  groups = [ "admins" "system-access" "libvirtd" "kvm" ];
  identity = {
    displayName = "Jason Bowman";
    email = "jason@json64.dev";
    gpgKey = "0xE822121B6A3D7FC6";
    sshKeys = [
      { tag = "yubikey"; key = "ssh-rsa ..."; }
      { tag = "ipad";    key = "ssh-rsa ..."; }
    ];
  };
};
```

**Reference:** `~/src/den-examples/sini/modules/den/users/sini.nix` + `users.nix` (registry option + ACL resolution)

Short-term: Keep the current host-entity approach. Long-term: adopt a user registry with policy-driven host resolution (see Phase 3).

---

### 2.3 🟡 Quirks for Impermanence (sini-inspired) 🐚

**Current** — Uses a plain NixOS option `config.persist.directories`:
```nix
# modules/aspects/profiles/hypervisor.nix
persist.directories = [ { directory = "/var/lib/incus"; } ];
```

**Sini pattern** — Declares a quirk and aspects emit into it:
```nix
# den.quirks.persist is declared as a collectable pipe
# Aspects emit: { pipe.persist = [ "/var/lib/incus" ]; }
# A collector aspect gathers them all into environment.persistence
```

**Reference:** `~/src/den-examples/sini/modules/den/quirks/impermanence.nix`

This is more den-native than a bespoke NixOS option. Worth adopting if you add more aspects that need persistence.

---

### 2.4 🟡 Inline SSH key closure should be a named aspect

**Current:**
```nix
# Anonymous closure in den.default.includes
({ host, user }: { nixos.users.users.${user.userName} = ... })
```

**Target:** Move to a named aspect:
```nix
# modules/aspects/features/ssh-keys.nix
den.aspects.ssh-keys = { host, user, ... }: { ... };
```

Then `den.default.includes = [ ... den.aspects.ssh-keys ];`

**Why:** Named aspects are testable, can be extended to Darwin, and follow the fleet-demo pattern.

**Reference:** `~/src/den/templates/fleet-demo/modules/aspects/users/ssh-keys.nix`

---

## Phase 4: Den-Native Refactors

Aspirational improvements. Postpone until Phases 0-2 are deployed and stable.

### 3.1 Aspect-based Settings (sini-inspired) 🐚

**Pattern:** Aspects declare `.settings` for their configurable options, and read from `host.settings.<aspect-name>.*`:
```nix
# In the aspect definition:
den.aspects."dlab/services/crowdsec".settings = {
  options.enrollment-key = mkOption { ... };
};

# The aspect reads settings at runtime, not hardcoded config.
```

**Reference:** sini's `modules/den/schema/host.nix:195-218` (dynamic `settingsType`)

### 3.2 Group-based user resolution (sini-inspired) 🐚

**Pattern:** Declare groups as entities, extend user schema with `groups`, and use policy to resolve which users go on which hosts based on group intersection.

**Reference:** `~/src/den-examples/sini/modules/den/groups/` + `modules/den/users.nix`

### 3.3 SecretRequests improvement

**Current:** Hardcoded in `modules/aspects/secrets/sops.nix`:
```nix
key = if req.key != null then req.key else "${config.networking.hostName}/${name}";
```

**Could be a quirk pattern:** Aspects declare their secret needs via `secretRequests`, which is collected by a sops-provider aspect. This is what the homelab already does — the existing `secretRequests` → `sops.secrets` mapping is already "den-native."

**Status:** ✅ Already good.

---

## Migration Reference

| Den Path | Purpose | Current Status |
|----------|---------|---------------|
| `den.default.nixos` | Global NixOS defaults (replaces profiles-base) | ✅ Has SSH, mutableUsers, stateVersion, emergencyAccess |
| `den.default.includes` | Global batteries (hostname, define-user, mutual-provider) | ✅ Has 3 batteries + SSH key closure |
| `den.schema.host` | Host entity metadata (zfs, networking) | ✅ Defined in `modules/schema/host.nix` |
| `den.schema.host.includes` | Auto-applied aspects (time, networking) | ✅ |
| `den.schema.user` | User entity metadata (mainGroup, classes) | ✅ Defined in `modules/schema/user.nix` |
| `den.aspects."dlab/profile/*"` | Profiles as den aspects | ✅ All 7 profiles migrated |
| `den.aspects."dlab/services/crowdsec"` | Crowdsec with `provides.bouncer` | ✅ |
| `den.aspects."dlab/secrets/sops"` | SecretRequests → sops-nix mapper | ✅ |
| `den.batteries.define-user` | User account creation | ✅ In `den.default.includes` |
| `den.batteries.hostname` | Hostname from entity | ✅ In `den.default.includes` |
| `den.batteries.mutual-provider` | Cross-entity data | ✅ In `den.default.includes` |
| `den.batteries.primary-user` | Admin user (wheel+networkmanager) | 🔴 Not adopted |
| `den.batteries.user-shell` | Default shell | 🔴 Not adopted |
| `den.users.registry` | Standalone user declarations | 🔴 Not adopted (sini pattern) |
| `den.quirks.*` | Cross-aspect data collection (pipes) | 🔴 Not adopted (sini pattern) |

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

### What's unique to the homelab (worth questioning)

| Homelab pattern | What everyone else does | Question |
|-----------------|------------------------|----------|
| `secretRequests` abstraction | Set `sops.secrets` directly in parametric aspects | Is the indirection worth it for 3 secrets? Everyone else just uses `sops.secrets."<key>" = {};` directly in aspects. |
| `den.hosts.*.users.*.sshKeys` entity field | Per-user aspect files with SSH keys declared inline | Per-user files (Codys-Wright style) are simpler for 1 user. The entity-field approach is fine but less discoverable. |
| `neededForUsers` on password secrets | Others use `hashedPassword` directly (not `hashedPasswordFile`) | Simpler approach: inline the hash in the aspect rather than via SOPS file. Trade-off: hash in nix store vs hash in encrypted SOPS file. |

### Conflict to resolve: user model

Two different approaches across examples, pick one:

**A) Per-user files (Codys-Wright, zakuciael, hydeik)**
```nix
# users/daniel.nix
den.aspects.daniel = {
  includes = [ <den/primary-user> (<den/user-shell> "zsh") ];
  nixos.users.users.daniel = { ... };
};
# Host assigns user:
den.hosts.aarch64-linux.builder.users.daniel = { };
```
Simple, explicit. Best for 1-5 users.

**B) Central user registry (sini)**
```nix
den.users.registry.daniel = {
  groups = [ "admins" "system-access" ];
  identity = { email = "..."; sshKeys = [ ... ]; };
};
# Policy resolves users onto hosts via group intersection
```
Scalable, policy-driven. Best for 15+ users with SSO. Requires scope-engine or custom policies.

**Recommendation:** A (per-user files) for now. Simple and sufficient.

---

## Den Source & Examples Guide

| Location | What's There |
|----------|--------------|
| `~/src/den/modules/aspects/batteries/*.nix` | Battery implementations |
| `~/src/den/modules/policies/core.nix` | Default entity resolution policies |
| `~/src/den/templates/example/modules/aspects/alice.nix` | Per-user aspect with batteries + cross-scope policy |
| `~/src/den/templates/example/modules/aspects/defaults.nix` | Global defaults with scope guard warnings |
| `~/src/den/templates/fleet-demo/modules/aspects/users/ssh-keys.nix` | SSH keys as a formal aspect |
| `~/src/den/templates/fleet-demo/modules/users.nix` | User registry with group-based resolution |
| `~/src/den/templates/fleet-demo/modules/policies/fleet.nix` | Policy-driven entity topology |
| `~/src/den-examples/sini/modules/den/users/sini.nix` | User registry entry with rich schema |
| `~/src/den-examples/sini/modules/den/users.nix` | Full user registry type + ACL policies |
| `~/src/den-examples/sini/modules/den/quirks/impermanence.nix` | Quirk-based persist directory collection |
| `~/src/den-examples/sini/modules/den/schema/host.nix` | Advanced host schema (channels, interfaces, settings) |
| `~/src/den-examples/sini/modules/den/schema/environment.nix` | Environment entity schema |
| `~/src/den-examples/sini/modules/den/schema/user.nix` | Extended user schema (identity, system, ssh keys) |

---

## Phase 1: Rename & Reorganize

The current file layout was done hastily and mixes concerns. Compare with sini's clean separation (`modules/den/aspects/`, `modules/den/schema/`, `modules/den/hosts/`, `modules/den/users/`, etc.).

### 4.1 Problems with Current Layout

| Issue | Current | Problem |
|-------|---------|---------|
| Everything under `aspects/` | `aspects/default.nix`, `aspects/nix/`, `aspects/profiles/`, `aspects/secrets/`, `aspects/services/`, `aspects/hosts/` | Grab-bag with no structure. Schema is a separate top-level dir |
| `profiles/` naming is legacy | `aspects/profiles/time.nix`, `aspects/profiles/disks.nix` | Term "profile" is from old DSL, not den-native |
| Host entity + aspect mixed | `aspects/hosts/builder/default.nix` has both `den.hosts.*` and `den.aspects.builder` | Should be separate concerns |
| Stale pre-den files | `modules/lib/`, `modules/nix/`, `modules/hosts/_*` | Confusing, should be cleaned up |
| Nix daemon config is buried | `aspects/nix/default.nix` is under `aspects/` but not a den aspect — it uses `den.default.nixos` | Wrong location for what is essentially a core system config |

### 4.2 Target Structure

```
modules/
  den/                              ← ALL den-related config (was modules/aspects/)
    defaults.nix                     ← den.default + den.default.includes + den.default.nixos
    flake-parts.nix                  ← den integration + manual output bridge (was nix/den.nix + ...)
    schema/
      host.nix                       ← den.schema.host (zfs, networking)
      user.nix                       ← den.schema.user (mainGroup, classes)
    aspects/
      core/                          ← System-wide concerns
        time.nix                     ← chrony (was profiles/time.nix)
        nix.nix                      ← Nix daemon config (was aspects/nix/default.nix)
        ssh.nix                      ← services.openssh config (was inline in default.nix)
        sudo.nix                     ← sudo-rs (was modules/security/sudo.nix)
        facter.nix                   ← nixos-facter (was profiles/facter.nix)
        impermanence.nix             ← environment.persistence (was profiles/impermanence.nix)
        remote-unlock.nix            ← Hoopsnake initrd (was profiles/remote-unlock.nix)
        users.nix                    ← define-user + ssh keys + password wiring (now split across multiple files)
      secrets/
        sops.nix                     ← secretRequests → sops-nix (was aspects/secrets/sops.nix)
        hardcoded.nix                ← hardcoded provider (was aspects/secrets/hardcoded.nix)
      services/
        crowdsec.nix                 ← + provides.bouncer (was aspects/services/crowdsec.nix)
      hardware/
        hypervisor.nix               ← Incus (was profiles/hypervisor.nix)
        disks.nix                    ← disko ZFS (was profiles/disks.nix)
      networking/
        default.nix                  ← systemd-networkd, firewall, resolved (was profiles/networking.nix)
    hosts/
      builder.nix                    ← host entity + den.aspects.builder (was hosts/builder/default.nix)
      hvn-hyp1.nix
      daniels-2021-mbp.nix
      testvm.nix
```

### 4.3 Migration Plan

Move files one at a time to avoid breaking git tracking:

```bash
# 1. Create new directories
mkdir -p modules/den/aspects/{core,secrets,services,hardware,networking}
mkdir -p modules/den/hosts
mkdir -p modules/den/schema

# 2. Move schema files
git mv modules/schema/host.nix modules/den/schema/host.nix
git mv modules/schema/user.nix modules/den/schema/user.nix

# 3. Move core aspects
git mv modules/aspects/profiles/time.nix modules/den/aspects/core/time.nix
git mv modules/aspects/profiles/facter.nix modules/den/aspects/core/facter.nix
git mv modules/aspects/profiles/impermanence.nix modules/den/aspects/core/impermanence.nix
git mv modules/aspects/profiles/remote-unlock.nix modules/den/aspects/core/remote-unlock.nix
git mv modules/aspects/nix/default.nix modules/den/aspects/core/nix.nix
git mv modules/security/sudo.nix modules/den/aspects/core/sudo.nix

# 4. Move secrets
git mv modules/aspects/secrets/sops.nix modules/den/aspects/secrets/sops.nix
git mv modules/aspects/secrets/hardcoded.nix modules/den/aspects/secrets/hardcoded.nix

# 5. Move services
git mv modules/aspects/services/crowdsec.nix modules/den/aspects/services/crowdsec.nix

# 6. Move hardware/hypervisor
git mv modules/aspects/profiles/hypervisor.nix modules/den/aspects/hardware/hypervisor.nix
git mv modules/aspects/profiles/disks.nix modules/den/aspects/hardware/disks.nix

# 7. Move networking
git mv modules/aspects/profiles/networking.nix modules/den/aspects/networking/default.nix

# 8. Move hosts
git mv modules/aspects/hosts/builder/default.nix modules/den/hosts/builder.nix
git mv modules/aspects/hosts/hvn-hyp1/default.nix modules/den/hosts/hvn-hyp1.nix
git mv modules/aspects/hosts/daniels-2021-mbp/default.nix modules/den/hosts/daniels-2021-mbp.nix
git mv modules/aspects/hosts/testvm/default.nix modules/den/hosts/testvm.nix

# 9. Move defaults + flake integration
git mv modules/aspects/default.nix modules/den/defaults.nix
git mv modules/namespace.nix modules/den/namespace.nix

# 10. Merge flake integration
# Consolidate nix/den.nix + modules/flake/den.nix into modules/den/flake-parts.nix

# 11. Clean up empty dirs
rmdir modules/aspects/{hosts/builder,hosts/hvn-hyp1,hosts/daniels-2021-mbp,hosts/testvm,hosts}
rmdir modules/aspects/{profiles,secrets,services,nix}
rmdir modules/aspects
rmdir modules/schema
rmdir modules/security  # only had sudo.nix, now moved

# 12. Remove stale pre-den files
git rm modules/lib/asserts.nix modules/lib/default.nix modules/lib/dlab.nix modules/lib/dsl.nix modules/lib/utilities.nix
git rm modules/nix/caches.nix modules/nix/flakes.nix modules/nix/optimise.nix modules/nix/sensible.nix modules/nix/unfree.nix
git rm modules/hosts/builder/_configuration.nix modules/hosts/hvn-hyp1/_configuration.nix
git rm modules/hosts/daniels-2021-mbp/_configuration.nix modules/hosts/testvm/_default.nix
```

### 4.4 Rename the `.provider` namespace

**Current:** `den.aspects."dlab/profile/..."` and `den.aspects."dlab/services/..."`

The `dlab` namespace prefix on aspect names is redundant — the `dlab` keyword is already the namespace (set in `modules/namespace.nix`). The den convention is:

- `den.aspects."dlab/profile/time"` → `dlab.time` (via namespace)
- `den.aspects."dlab/profile/disks"` → `dlab.disks`
- `den.aspects."dlab/services/crowdsec"` → `dlab.crowdsec`
- `den.aspects."dlab/profile/server"` → `dlab.server`

**Reference:** Example template uses `eg.autologin` (via `inputs.den.namespace "eg" true`).

However, this requires the namespace to be flake-exposed (`true` parameter in `inputs.den.namespace`). Currently homelab uses `(inputs.den.namespace "dlab" false)`. Change to `true` if you want short names.

Alternatively, embrace the `dlab/profile/time` naming but remove the `dlab/` prefix redundancy:
- `den.aspects."dlab/profile/time"` → `den.aspects."profile/time"`
- Or keep as-is if you want clarity — this is cosmetic.

### 4.5 Aspect naming convention

| Current | Target | Why |
|---------|--------|-----|
| `den.aspects."dlab/profile/time"` | `core.time` (via namespace) or `den.aspects.core.time` | "Time" is a core system concern, not a "profile" |
| `den.aspects."dlab/profile/networking"` | `networking` (or `den.aspects.networking`) | Direct name, no "profile" prefix |
| `den.aspects."dlab/profile/disks"` | `hardware.disks` (or `den.aspects.hardware.disks`) | Disk config is hardware |
| `den.aspects."dlab/profile/impermanence"` | `core.impermanence` | It's a core system property |
| `den.aspects."dlab/services/crowdsec"` | `services.crowdsec` | Makes sense, keep |
| `den.aspects."dlab/profile/server"` | `roles.server` | "Server" is a role, not a profile |
| `den.aspects."dlab/profile/hypervisor"` | `hardware.hypervisor` | Incus is hardware virtualization |
| `den.aspects."dlab/profile/facter"` | `core.facter` | Hardware detection, core |
| `den.aspects."dlab/profile/remote-unlock"` | `core.remote-unlock` | initrd feature, core |

Sini groups by purpose:
- `core/` — essential system config (time, nix, ssh, sudo, boot, users)
- `hardware/` — hardware-specific (disks, GPU, CPU, audio, bluetooth)
- `network/` — networking (networking, wireless, DNS)
- `desktop/` — GUI/windowing (DE, display manager, xdg)
- `services/` — daemons/services (crowdsec, nginx, postgres)
- `roles/` — high-level composite roles (server, workstation, laptop, gaming)
- `apps/` — user-facing applications (browsers, dev tools, media)

The homelab should adopt: `core`, `hardware`, `networking`, `services`, `roles`.

---

## Quick Start

1. **Phase 0** — fix bugs, deploy immediately
2. **Phase 1** — file moves, `nix run .#write-flake --impure`, verify builds
3. **Phase 2** — adopt batteries, minor
4. **Phase 3** — structural refactors
5. **Phase 4** — aspirational
