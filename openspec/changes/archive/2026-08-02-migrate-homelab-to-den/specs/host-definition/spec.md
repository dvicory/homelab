## ADDED Requirements

### Requirement: hosts declared via den.hosts

Each host SHALL be declared using the `den.hosts.<system>.<name>` option.
The system SHALL correspond to the host's architecture: `x86_64-linux`, `aarch64-linux`, or `aarch64-darwin`.
Host declarations SHALL include the users that exist on each host.

#### Scenario: Hosts resolve through manual bridge

- **GIVEN** a host declared as `den.hosts.x86_64-linux.hvn-hyp1.users.daniel = {}`
- **WHEN** the manual output bridge evaluates `config.den.hosts`
- **THEN** a `nixosConfigurations.hvn-hyp1` SHALL be generated containing the host's NixOS module

#### Scenario: Cross-platform hosts

- **GIVEN** hosts on `x86_64-linux` (hvn-hyp1, testvm), `aarch64-linux` (builder), and `aarch64-darwin` (daniels-2021-mbp)
- **WHEN** the manual bridge evaluates
- **THEN** `nixosConfigurations` SHALL be generated for Linux hosts and `darwinConfigurations` for Darwin hosts

### Requirement: host aspects with includes

Each host SHALL define a corresponding `den.aspects.<name>` with `includes` referencing applicable aspects.
Host aspects SHOULD use angle-bracket syntax for includes (e.g. `<dlab/profile/base>`, `<dlab/services/crowdsec>`).
Host-specific configuration (`configuration.nix`) SHALL be imported as a NixOS module within the host aspect, not inlined.

#### Scenario: Host aspect selects profiles

- **GIVEN** `den.aspects.hvn-hyp1 = { includes = [ <dlab/profile/base> <dlab/profile/server> ]; nixos = { imports = [ ./configuration.nix ]; }; }`
- **WHEN** the den pipeline resolves the host
- **THEN** the NixOS config SHALL contain the modules from those aspects AND the host-specific configuration.nix

### Requirement: host configuration as separate NixOS module

The host-specific NixOS configuration (SOPS paths, kernel params, filesystems, deployment metadata) SHALL be defined in a separate NixOS module file (`configuration.nix`), not inline in the aspect definition.
This file SHALL remain a pure NixOS module — independent of den's aspect system, usable by any config generation pipeline (den, clan, or manual).

#### Scenario: Configuration module loads correctly

- **GIVEN** `den.aspects.hvn-hyp1.nixos = { imports = [ ./configuration.nix ]; }`
- **WHEN** `nixosConfigurations.hvn-hyp1` is built
- **THEN** the host-specific settings (SOPS, kernel params, filesystems) SHALL be present

#### Mechanism

- Directory: `modules/aspects/hosts/<hostname>/default.nix` — declares both `den.hosts` and `den.aspects.<name>`
- File: `modules/aspects/hosts/<hostname>/configuration.nix` — pure NixOS module imported by the aspect
- Pattern follows zakuciael's `machines/<host>/default.nix` approach
- All `self.modules.nixos.*` references inside `configuration.nix` MUST be rewritten to direct module paths or angle-bracket includes
