## ADDED Requirements

### Requirement: module registry → aspects

Every `self.modules.nixos.*` entry SHALL convert to a den aspect under the `dlab` namespace. Profiles needing per-host data SHALL use parametric aspects (`{ host, ... }`). Profiles with no per-host data SHALL use static aspects.

#### Scenario: All registry entries converted

- **GIVEN** every `flake.modules.nixos.*` registration in the codebase
- **WHEN** the migration completes
- **THEN** zero `self.modules.nixos.*` references SHALL remain in the evaluation path

### Requirement: den.schema.host for typed host metadata

A `den.schema.host` module SHALL declare typed options for per-host infrastructure metadata that profiles need to read. Hosts SHALL set these values on their `den.hosts.<system>.<name>` declarations. Parametric aspects SHALL read them via `{ host, ... }`.

The schema options SHALL be:

| Option | Type | Read by profiles |
|--------|------|-----------------|
| `zfs.rootPool` | `nullOr { name: str, disk1: str }` | disks, impermanence |
| `zfs.swap.enable` | `bool` | disks |
| `zfs.swap.size` | `str` | disks |
| `networking.interfaces` | `attrsOf { ipv4, gateway, dhcp, initrd }` | networking, remote-unlock |

#### Scenario: Host metadata flows from schema to aspect

- **GIVEN** `den.schema.host` defines `options.zfs.rootPool`
- **GIVEN** `den.hosts.x86_64-linux.hvn-hyp1.zfs.rootPool = { name = "rpool"; disk1 = "/dev/nvme0n1"; }`
- **GIVEN** `den.aspects."dlab/profile/disks" = { host, ... }: { nixos = { ... }: { device = host.zfs.rootPool.disk1; }; }`
- **WHEN** the NixOS configuration is built
- **THEN** `disko.devices.disk.root.device` SHALL be `/dev/nvme0n1`

### Requirement: time profile — static aspect

`den.aspects."dlab/profile/time"` SHALL be a static aspect. No per-host data. Chrony config, timezone default, time sync.

#### Scenario: Time applies

- **GIVEN** a host includes `<dlab/profile/time>`
- **WHEN** the NixOS config is built
- **THEN** `time.timeZone` SHALL default to `"America/Los_Angeles"`, chrony SHALL be enabled

### Requirement: networking profile — parametric aspect for interfaces + static for shared config

`den.aspects."dlab/profile/networking"` SHALL be a parametric aspect reading `host.networking.interfaces` to generate `systemd.network.networks`. Shared config (nftables, resolved, firewall defaults, packages) SHALL be included unconditionally in the same aspect.

#### Scenario: Host has network interfaces defined

- **GIVEN** `den.hosts.x86_64-linux.hvn-hyp1.networking.interfaces.eno1 = { ipv4 = "172.27.50.17/24"; gateway = "172.27.50.1"; initrd.enable = true; }`
- **GIVEN** a host includes `<dlab/profile/networking>`
- **WHEN** the NixOS config is built
- **THEN** `systemd.network.networks."10-eno1"` SHALL be configured with the specified address and gateway

#### Scenario: Host has no interfaces defined

- **GIVEN** `den.hosts.x86_64-linux.testvm.networking.interfaces = { }`
- **GIVEN** a host includes `<dlab/profile/networking>`
- **WHEN** the NixOS config is built
- **THEN** nftables, resolved, and firewall SHALL still be configured (shared config applies)
- **THEN** no `systemd.network` entries SHALL be generated from empty interfaces

### Requirement: facter profile — static aspect

`den.aspects."dlab/profile/facter"` SHALL be a static aspect reading `config.networking.hostName` inside the nixos block. The report path SHALL be `./hosts/${config.networking.hostName}/facter.json`.

#### Scenario: Facter resolves path

- **GIVEN** a host with `config.networking.hostName = "hvn-hyp1"`
- **GIVEN** a host includes `<dlab/profile/facter>`
- **WHEN** the NixOS config is built
- **THEN** `facter.reportPath` SHALL resolve to `modules/hosts/hvn-hyp1/facter.json`

### Requirement: Registry users emitted for resolved hosts

User definitions SHALL live in `den.users.registry.<userName>` entity data rather than a separate host profile. A scope-unique parametric user aspect SHALL emit each resolved user's SSH keys and account metadata into `users.users.<userName>` for the active host.

#### Scenario: Resolved registry user becomes a NixOS account

- **GIVEN** `den.users.registry.daniel.identity.sshKeys` contains an SSH public key
- **GIVEN** the ACL graph resolves `daniel` for host `hvn-hyp1`
- **WHEN** the user enrichment aspect evaluates for that host
- **THEN** `users.users.daniel.openssh.authorizedKeys.keys` SHALL contain that key
- **AND** `users.users.daniel.isNormalUser` SHALL be true
- **AND** no separate static users profile SHALL be required

### Requirement: disks profile — parametric aspect

`den.aspects."dlab/profile/disks"` SHALL be a parametric aspect reading `host.zfs.rootPool` and `host.zfs.swap`. It SHALL generate disko disk layout from these values. If `host.zfs.rootPool` is null, the aspect SHALL be a no-op.

#### Scenario: Disks generates from host data

- **GIVEN** `host.zfs.rootPool = { name = "rpool"; disk1 = "/dev/nvme0n1"; }`
- **WHEN** the disks aspect evaluates
- **THEN** `disko.devices.disk.root.device` SHALL be `/dev/nvme0n1`
- **THEN** `disko.devices.zpool.rpool` SHALL be configured

### Requirement: impermanence profile — parametric aspect

`den.aspects."dlab/profile/impermanence"` SHALL be a parametric aspect reading `host.zfs.rootPool.name`. The initrd ZFS rollback script SHALL be accessed via a flake-native package. Impermanence options (`enable`, `persistPath`, `additionalDirectories`) SHALL be NixOS options declared within the aspect.

#### Scenario: Impermanence reads root pool

- **GIVEN** `host.zfs.rootPool.name = "rpool"`
- **WHEN** the impermanence aspect evaluates
- **THEN** `boot.initrd.systemd.services.initrd-zfs-rollback` SHALL reference pool `rpool`

### Requirement: hypervisor profile — static aspect

`den.aspects."dlab/profile/hypervisor"` SHALL be a static aspect enabling incus on port 8443. No per-host data.

#### Scenario: Hypervisor enables incus

- **GIVEN** a host includes `<dlab/profile/hypervisor>`
- **WHEN** the NixOS config is built
- **THEN** `virtualisation.incus` SHALL be enabled with ui on port 8443

### Requirement: remote-unlock profile — parametric aspect

`den.aspects."dlab/profile/remote-unlock"` SHALL be a parametric aspect reading `host.zfs.rootPool`, `host.networking.interfaces`, and `host.users` (for SSH authorized keys). It SHALL configure hoopsnake initrd unlocking with per-host network and key data.

#### Scenario: Remote unlock reads host data

- **GIVEN** `host.zfs.rootPool.name = "rpool"`
- **GIVEN** `host.networking.interfaces.eno1.initrd.enable = true`
- **WHEN** the aspect evaluates
- **THEN** hoopsnake SHALL be configured with initrd network on eno1 and ZFS pool rpool

### Requirement: crowdsec service — static aspect with secretRequests

`den.aspects."dlab/services/crowdsec"` SHALL be a static aspect using `secretRequests` for SOPS wiring. The `disabledModules` for nixpkgs crowdsec SHALL remain. No per-host data from `host` context.

#### Scenario: CrowdSec declares secret requests

- **GIVEN** a host includes `<dlab/services/crowdsec>`
- **WHEN** the config is built
- **THEN** `secretRequests."crowdsec/bouncer-api-key"` SHALL be populated
- **THEN** `secretRequests."crowdsec/enrollment-key"` SHALL be populated

### Requirement: server profile — static aspect aggregating others

`den.aspects."dlab/profile/server"` SHALL be a static aspect using `includes = [ <dlab/services/crowdsec> <dlab/profile/remote-unlock> ]`. Contract wiring SHALL be replaced with `secretRequests`.

#### Scenario: Server aggregates

- **GIVEN** a host includes `<dlab/profile/server>`
- **WHEN** the config is built
- **THEN** it SHALL be equivalent to including crowdsec + remote-unlock directly

### Requirement: mergerfs kept as NixOS module

mergerfs.nix SHALL remain as a NixOS module importing via `den.default.nixos`. It reads `config.dlab.storage.mergerfs`. No conversion needed.

#### Mechanism

- `modules/schema/host.nix` — `den.schema.host` options for zfs, networking
- `modules/aspects/profiles/<name>.nix` — converted profiles as parametric or static aspects
- Host data set on `den.hosts.<system>.<name>` for per-host values
- Parametric aspects use `{ host, ... }` to read; static aspects use `{ ... }` with `config` in nixos block
