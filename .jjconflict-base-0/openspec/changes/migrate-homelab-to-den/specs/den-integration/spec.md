## ADDED Requirements

### Requirement: den flake input

The system SHALL declare `den` as a flake input using `url = "github:denful/den"` with a pinned revision.
The `den` input MUST be registered in the `flake-file` input system (via `modules/meta/inputs.nix`).
The `flake.nix` SHALL be regenerated after adding the input.

#### Scenario: Input resolves

- **GIVEN** the flake has `github:denful/den` declared as an input with pinned rev
- **WHEN** `nix flake show` is evaluated
- **THEN** the `den` input SHALL appear in the output with the pinned revision

### Requirement: den flakeModule activation with disabled auto-output

The `inputs.den.flakeModule` SHALL be imported in a module that participates in `import-tree` (e.g. `modules/flake/den.nix`).
The `den/modules/config.nix` SHALL be explicitly disabled to prevent den from auto-generating `nixosConfigurations`.
Output generation SHALL use a manual bridge function that builds configurations from resolved `den.hosts`.

#### Scenario: flakeModule imports without auto-output

- **GIVEN** `den/modules/config.nix` is listed in `disabledModules`
- **WHEN** `inputs.den.flakeModule` is imported
- **THEN** the `den` option namespace (e.g. `den.hosts`, `den.aspects`) SHALL be available without error
- **THEN** den SHALL NOT auto-generate `nixosConfigurations` (manual bridge controls output)

#### Scenario: Manual output bridge produces configs

- **GIVEN** a manual bridge function processes `config.den.hosts`
- **WHEN** the flake evaluates
- **THEN** `nixosConfigurations` and `darwinConfigurations` SHALL be produced for each declared host

### Requirement: namespace creation with angle brackets

A `den.namespace` SHALL be created using `inputs.den.namespace "dlab" true` in `modules/namespace.nix`.
The `_module.args.__findFile` SHALL be set to `den.lib.__findFile` to enable angle-bracket syntax.
Aspects under this namespace SHALL be resolvable via `<dlab/category/name>` syntax.

#### Scenario: namespace registered

- **GIVEN** the namespace module at `modules/namespace.nix`
- **WHEN** the flake evaluates
- **THEN** aspects under the `dlab` namespace SHALL be resolvable via angle brackets (e.g. `<dlab/profile/base>`)

#### Mechanism

- File: `nix/den.nix` — imports `inputs.den.flakeModule`, disables `den/modules/config.nix`, sets `__findFile`, builds manual output bridge
- File: `modules/namespace.nix` — imports `inputs.den.namespace "dlab" true`
- Input: `den` — `github:denful/den` (pinned rev) in `modules/meta/inputs.nix`
- Bridge pattern follows zakuciael's approach: `host.mainModule` + `nixpkgs.hostPlatform`
