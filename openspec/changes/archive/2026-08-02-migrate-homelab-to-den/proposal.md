## Why

The current homelab configuration uses a custom dendritic pattern — a 433-line Host Inventory DSL (`modules/flake/hosts.nix`), custom `mkNixos`/`mkDarwin` builders (`modules/lib/mk-os.nix`), and manual module resolution via a `self.modules.nixos.*` registry. The `den` framework provides a native type system for hosts, users, and homes; aspect-oriented composition; and a resolution pipeline that eliminates boilerplate and the custom DSL entirely. Broken stubs already exist in `modules/flake/den.nix` and `modules/namespace.nix` — this migration completes that work.

## What Changes

- Add `den` as a flake input (`github:denful/den`) and activate `inputs.den.flakeModule`
- Hydrate `modules/flake/den.nix` and `modules/namespace.nix` so den's pipeline activates
- Follow the zakuciael pattern: disable `den/modules/config.nix` and build a manual output bridge from `den.hosts` → `nixosConfigurations`/`darwinConfigurations`
- Declare hosts via `den.hosts` (replacing the custom Host Inventory DSL)
- Define aspects for configuration concerns (replacing the `self.modules.nixos.*` registry)
- Convert every `self.modules.nixos.profiles-*`, `self.modules.nixos.services-*`, and `self.modules.nixos.hosts-*` to den aspects
- Keep host-specific configs (`configuration.nix`) as separate NixOS module files, imported from their host's aspect
- Define a `config.deployment` NixOS option set for deploy-rs metadata (Codys-Wright pattern), independent of den
- Wire SOPS via standard `sops-nix` NixOS modules within aspects
- Remove custom `mkNixos`/`mkDarwin` builders (`modules/lib/mk-os.nix`)
- Remove the `self.modules.nixos.*` class system (`nixos-class.nix`, `darwin-class.nix`)
- Remove `modules/flake/hosts.nix` (the 433-line DSL)

## Capabilities

### New Capabilities

- `den-integration`: Wire `github:denful/den` as a flake input, activate flakeModule and namespace, disable auto-output generation
- `output-bridge`: Manually bridge `den.hosts` → `nixosConfigurations`/`darwinConfigurations` (zakuciael pattern, enables future clan migration)
- `host-definition`: Declare hosts and users via `den.hosts` with system type and aspect selection
- `module-registry-migration`: Convert every `self.modules.nixos.*` registry entry to a den aspect (profiles, services, contracts, Nix config)
- `secret-management`: Wire SOPS secrets into den's aspect pipeline
- `deploy-rs-integration`: Adapt deploy-rs to read `config.deployment` from den-generated configs

### Modified Capabilities

*(No existing specs are being modified — this is a new migration.)*

## Impact

**Affected hosts:** builder (aarch64-linux), hvn-hyp1 (x86_64-linux), daniels-2021-mbp (aarch64-darwin), testvm (x86_64-linux)

**Module registry entries to convert (every `self.modules.nixos.*` reference):**
- `profiles-base`, `profiles-time`, `profiles-networking`, `profiles-users`, `profiles-disks`, `profiles-facter`
- `profiles-server`, `profiles-impermanence`, `profiles-hypervisor`, `profiles-remote-unlock-tailscale`
- `services-crowdsec`
- `hosts-<name>` (4 host configs)
- `nix` class entries: `nixos`, `aarch64-linux`, `x86_64-linux` (class modules)
- `contracts-provider`, `secret-sops-provider` (contracts infrastructure)
- `self.modules.generic.nix-common` (5 Nix config files merged into one — becomes `den.default.nixos`)

**Affected modules to create:**
- `nix/den.nix` — flakeModule import + disabledModules + manual output bridge (zakuciael pattern)
- `modules/aspects/` — aspect definitions
- `modules/aspects/hosts/<name>/default.nix` — host declarations + aspect selection
- `modules/aspects/profiles/<name>.nix` — profile aspects
- `modules/aspects/services/<name>.nix` — service aspects
- `modules/aspects/deployment/default.nix` — `config.deployment` NixOS option
- `modules/aspects/nix/default.nix` — cross-cutting Nix config (`den.default.nixos`)

**Affected modules to remove:**
- `modules/flake/hosts.nix` — replaced by `den.hosts`
- `modules/lib/mk-os.nix` — replaced by manual output bridge
- `modules/flake/nixos-class.nix` — replaced by den's class system
- `modules/flake/darwin-class.nix` — replaced by den's class system

**Affected modules to adapt:**
- `modules/flake/deploy-rs.nix` — read from `config.deployment` instead of `config.flake.dlab.hosts`
- `modules/flake/den.nix` — hydration (currently broken)
- `modules/namespace.nix` — hydration (currently broken)
- `modules/flake/sops.nix` — may need simplification

**Dependencies:** `den` (`github:denful/den`, pinned rev), `flake-file` (no change), `import-tree` (no change), `sops-nix` (no change)

**Non-goals:**
- Refactoring secrets storage or SOPS rules (secrets stay in their current files)
- Changing the deployment workflow (deploy-rs continues as-is, adapted to read `config.deployment`)
- Adding new hosts or services (pure migration of existing config)
- Changing the module auto-import behavior (import-tree continues)
- Upgrading nixpkgs or other dependency versions
- Adding clan or home-manager support

**Technical Assumptions:**
- The manual output bridge in `nix/den.nix` follows zakuciael's pattern: disable `den/modules/config.nix`, build `nixosConfigurations` from resolved `den.hosts` via `host.mainModule`
- Host-specific configs are imported as separate NixOS module files from within `den.aspects.<name>.nixos = { imports = [ ./configuration.nix ]; }`
- deploy-rs reads `nixosConfigurations.<name>.config.deployment` — works identically whether den or a future tool generates the configs
- The `self.modules.nixos.*` registry references inside host configs are rewritten to direct file imports or aspect includes
- The local `den/` directory is implementation reference only (not a flake input)

**Rollback Plan:** Each task is independently revertible. The den input and broken stubs already exist — activation is the only real risk. If den evaluation fails, revert the flake input change and the two hydrated stubs. The old code paths (`hosts.nix`, `mk-os.nix`, class modules) remain intact until explicitly removed.
