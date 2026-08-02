## Context

The current homelab uses a custom dendritic pattern with three main architectural components that den replaces:

- **Host Inventory DSL** (`modules/flake/hosts.nix`, 433 lines): A custom `config.flake.dlab.hosts` option with typed submodules for systems, tags, networks, users, deploy targets, secrets paths, and remote unlock config.
- **Custom Builders** (`modules/lib/mk-os.nix`, 128 lines): `mkNixos`/`mkDarwin` functions composing modules from `self.modules.nixos.*` registry and injecting `dlab.hostName`/`dlab.hostCfg`.
- **Module Registry** (`self.modules.nixos.*`): Every profile/service/host config registers itself as a named entry. Builders reference these names.

## Goals / Non-Goals

**Goals:**
- Add `github:denful/den` as a flake input, activate flakeModule, build manual output bridge
- Convert `self.modules.nixos.*` registry into den aspects under `dlab` namespace
- Use `den.schema.host` for typed host metadata (replaces DSL's host data)
- Use parametric aspects (`{ host, ... }`) for profiles that need per-host data
- Define `config.deployment` NixOS option for deploy-rs (Codys-Wright pattern)
- Wire SOPS via `secretRequests` NixOS option + SOPS provider aspect
- Remove custom builders, class modules, hosts.nix

**Non-Goals:**
- Restructuring SOPS files, changing deploy-rs workflow, adding hosts/services
- Adding clan or home-manager

## Decisions

### 1. Den input: `github:denful/den` (pinned)

### 2. Namespace: `dlab` (existing stub)

### 3. Output strategy: disable `den/config.nix` + `den/outputs.nix`, manual bridge

### 4. Per-host data via `den.schema.host`, not NixOS options

**Decision:** Host metadata (ZFS pool config, network interfaces, SSH keys) SHALL be declared as typed options on `den.schema.host` and set directly on `den.hosts.<system>.<name>`. No NixOS-level data carrier options. The host entity IS the data carrier.

```nix
# Schema defines typed metadata:
den.schema.host = { host, lib, ... }: {
  options.zfs.rootPool = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule {
      options = {
        name = lib.mkOption { type = lib.types.str; };
        disk1 = lib.mkOption { type = lib.types.str; };
      };
    });
  };
};

# Host declares data:
den.hosts.x86_64-linux.hvn-hyp1 = {
  users.daniel = { };
  zfs.rootPool = { name = "rpool"; disk1 = "/dev/nvme0n1"; };
};

# Parametric aspect reads host data:
den.aspects."dlab/profile/disks" = { host, ... }: {
  nixos = { ... }: {
    device = host.zfs.rootPool.disk1;
  };
};
```

**Rationale:** den's host entity is a freeform attrset. `den.schema.host` types it. Parametric aspects receive `{ host, ... }` with the full metadata. No NixOS option pollution for infrastructure metadata. The `host` object is resolved outside the Nix module system, preventing infinite recursion. This replaces decisions 4 (host config files), 8 (contracts as data carrier), and the "data carrier module" from the previous design.

### 5. Profile conversion: parametric aspects for data-dependent profiles

**Decision:** Profiles that need per-host data become parametric aspects (`{ host, ... }`). Profiles with no per-host data become static aspects (non-parametric). All cross-references use `includes`.

| Profile | Type | Needs from host |
|---------|------|----------------|
| time | static | nothing |
| networking | parametric | `host.networking.interfaces` |
| facter | static | nothing (reads `config.networking.hostName` in nixos block) |
| users | parametric | `host.users` (for SSH keys) |
| disks | parametric | `host.zfs.rootPool`, `host.zfs.swap` |
| impermanence | parametric | `host.zfs.rootPool.name` |
| hypervisor | static | nothing |
| remote-unlock | parametric | `host.zfs.rootPool`, `host.networking.interfaces`, `host.users` |
| crowdsec | static | nothing (uses `config.networking.hostName` + `secretRequests`) |
| server | static | nothing (aggregates crowdsec + remote-unlock) |

### 6. deploy-rs: `config.deployment` NixOS option (Codys-Wright pattern)

### 7. SOPS: `secretRequests` NixOS option, provider aspect

The `secretRequests` option SHALL be a NixOS-level option. The SOPS provider aspect SHALL read `config.secretRequests` and map to `sops.secrets`. The host's default sopsFile SHALL be a NixOS option set by the provider aspect, defaulting from `config.networking.hostName`.

### 8. Cross-cutting Nix config: `den.default.nixos`

## Architecture — Target State

```
den.hosts.<sys>.<name> = {           Metadata
  zfs.rootPool = ...                   typed by den.schema.host
  networking.interfaces = ...
  users.daniel.sshKeys = ...
};

den.aspects."dlab/profile/disks" = { host, ... }: {   ← parametric
  nixos = { ... }: { device = host.zfs.rootPool.disk1; };
};

den.aspects."dlab/profile/time" = {                    ← static
  nixos = { ... }: { time.timeZone = ...; };
};

den.default.nixos = {                                   ← cross-cutting
  nix.settings.experimental-features = [ "flakes" ];
  deployment.enable = true;
};

Module tree:
modules/
├── schema/                        ← den.schema.host definitions
│   └── host.nix
├── aspects/
│   ├── default.nix                ← den.default.includes + den.default.nixos
│   ├── nix/default.nix            ← den.default.nixos (nix config)
│   ├── deployment/default.nix     ← config.deployment option
│   ├── secrets/sops.nix           ← secretRequests option + SOPS provider
│   ├── profiles/                  ← converted profiles
│   │   ├── time.nix               static
│   │   ├── networking.nix         parametric (reads host.networking.interfaces)
│   │   ├── facter.nix             static
│   │   ├── users.nix              parametric (reads host.users)
│   │   ├── disks.nix              parametric (reads host.zfs)
│   │   ├── impermanence.nix       parametric (reads host.zfs)
│   │   ├── hypervisor.nix         static
│   │   ├── remote-unlock.nix      parametric (reads host.zfs, networking, users)
│   │   └── server.nix             static (includes)
│   ├── services/
│   │   └── crowdsec.nix           static (uses secretRequests)
│   └── hosts/
│       ├── hvn-hyp1/default.nix   den.hosts + den.aspects.<name>
│       ├── builder/default.nix
│       ├── testvm/default.nix
│       └── daniels-2021-mbp/default.nix
```

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| `den.schema.host` options can't access NixOS config for defaults | Schema defaults must come from `host.name` or `host.system` only. For things like facter path that depend on `networking.hostName`, use `host.name` instead. |
| Parametric aspects need `host` context not available in some scopes | `den.schema.host.includes` guarantees host context. Static aspects without host data work in any scope. |
| Contracts infrastructure (`config._contracts`) breaks | Replaced by `secretRequests` option directly — simpler, no abstraction layer. |

## Migration Plan

```
Phase 0 — Foundation (done)
Phase 1 — Host definitions (done)

Phase 2 — den.schema.host + data migration
  ├── Create modules/schema/host.nix (zfs, networking, swap options)
  ├── Delete modules/aspects/{host-data*,contracts,secrets/sops.nix} (replaced)
  ├── Move per-host data from den.aspects.<name>.nixos to den.hosts.<name>
  └── Clean up host aspects (remove inlined config that's now on den.hosts)

Phase 3 — Profile conversion (parametric where needed)
  ├── time, hypervisor → static aspects (no per-host data)
  ├── facter → static aspect (uses config.networking.hostName in nixos block)
  ├── networking → parametric aspect (reads host.networking.interfaces)
  ├── users → inlined in den.hosts.<name>.users (no separate profile needed)
  ├── disks, impermanence → parametric aspects (reads host.zfs)
  ├── crowdsec + mergerfs → keep as existing works (via den.default.nixos)
  └── remote-unlock, server → parametric/static aspects

Phase 4 — deploy-rs and SOPS
Phase 5 — Cleanup
```
