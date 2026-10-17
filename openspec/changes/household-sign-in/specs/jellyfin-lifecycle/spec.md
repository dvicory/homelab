## ADDED Requirements

### Requirement: Jellyfin plugins are pinned and installed before the runtime

Every Jellyfin plugin SHALL come from a Nix-pinned release whose target ABI matches the declared Jellyfin major release; evaluation SHALL fail otherwise. An init container SHALL install the pinned plugin builds into retained `/config` after first-start provisioning and before the stock runtime starts, and SHALL remove other versions of a declared plugin. Jellyfin's automatic plugin updates SHALL NOT replace a pinned build. Jellarr SHALL configure only installed plugins and SHALL NOT install a plugin from a repository.

#### Scenario: The Pod starts
- **WHEN** a Jellyfin Pod starts against initialized or freshly provisioned `/config`
- **THEN** the pinned plugin builds are installed before the stock runtime starts, and the runtime loads them

#### Scenario: Another version of a declared plugin is present
- **WHEN** `/config` holds a different version of a declared plugin, such as one installed from a repository
- **THEN** the next Pod start removes it and installs the pinned build

#### Scenario: Jellyfin is upgraded to another major release
- **WHEN** the declared Jellyfin release moves to a major version that a pinned plugin does not target
- **THEN** evaluation fails until the plugin pin is reviewed and moved

### Requirement: The declared administrator stays a local account

The declared normal administrator SHALL keep Jellyfin's local password authentication when directory sign-in is enabled. Directory sign-in SHALL NOT convert, link, or replace an existing local Jellyfin account. The declared administrator SHALL be able to sign in while the central identity service is unavailable.

#### Scenario: A directory account has the administrator's name
- **WHEN** the central identity service holds an account with the same name as the declared local administrator
- **THEN** Jellyfin keeps authenticating that name with the local password, and the directory credential does not sign in to it

#### Scenario: The central identity service is down
- **WHEN** the central identity service cannot answer directory requests
- **THEN** the declared administrator still signs in with its local password, and directory sign-ins are refused

## MODIFIED Requirements

### Requirement: Application startup ownership is explicit

Nix/Den and Kubernetes/Argo SHALL own workload declarations, retained storage
and media mounts, resource/security policy, Service/Gateway objects, release
pins, pinned plugin builds, and declarative Jellarr configuration. The patched
provisioner SHALL own fresh-state SetupServer initialization and initial
administrator creation. The plugin init container SHALL own the declared
plugins' files under `/config/plugins`. The stock official runtime SHALL own
normal serving, database/state internals, media processing, and unspecified
settings. Jellarr SHALL own only selected supported API fields, including
selected plugin settings. A plugin SHALL own the state it keeps in its own
settings, such as links between directory and Jellyfin accounts. Preserve
SHALL own backup/recovery policy and retained-state protection. No owner SHALL
silently write another owner's boundary.

#### Scenario: A new configuration writer is proposed
- **WHEN** a change introduces a Jellyfin XML/SQLite writer or a second
  startup/reconciliation controller
- **THEN** it is rejected unless it removes the competing owner and uses the
  owner boundary above

#### Scenario: Retained state is recovered
- **WHEN** Preserve or compute replacement restores retained Jellyfin state
- **THEN** it restores the declared inputs without taking ownership of
  first-start provisioning, stock runtime behavior, or Jellarr's selected API
  fields

#### Scenario: Jellarr reconciles a plugin's settings
- **WHEN** Jellarr reconciles a plugin whose settings also hold plugin-owned
  state
- **THEN** it changes only its declared keys and leaves the plugin-owned state
  in place
