## Purpose

Define how Jellyfin initializes retained state before its stock runtime starts,
then reconciles supported settings through its API. Generic isolation and
compute replacement remain governed by `reproducible-application-compute`.

## ADDED Requirements

### Requirement: Jellyfin has one coupled release identity

The Jellyfin provisioner and long-lived runtime SHALL consume one Nix-owned
release declaration. The declaration SHALL expose package `passthru.release`
fields `version`, `sourceRev`, `runtimeImage`, `runtimeDigest`, and
`provisionPatchRev`, and SHALL identify Jellyfin v12.1 source commit
`ee91c75e777da41a9c4f4855e70adc604fbf2ef8` with exact PR #17902 commit
`8b0a2c269d5a3d9d7084b5295fd818a8a67af6f2`. The runtime image SHALL be the
stock official `docker.io/jellyfin/jellyfin:12.1` image pinned by the declared
architecture-specific digest. Provisioner and runtime version identity SHALL
not be independently overridden.

#### Scenario: Release identity is consumed by both sides
- **WHEN** manifests and the `pkgs.jellyfin-provisioner-image` package are
  evaluated
- **THEN** the initContainer and long-lived container derive their Jellyfin
  release from the same declaration, and no second version or digest is
  silently introduced

#### Scenario: Provisioner and runtime releases drift
- **WHEN** a change selects a provisioner source release or runtime image whose
  upstream Jellyfin version differs from the other side
- **THEN** evaluation or build fails before a workload can be deployed

#### Scenario: Jellyfin is upgraded
- **WHEN** an operator upgrades Jellyfin
- **THEN** the provisioner source, official runtime image/digest, patch
  compatibility, and focused acceptance evidence are reviewed and moved
  together

### Requirement: First-start provisioning is bounded before normal HTTP

The provisioner SHALL be a Nix-built `pkgs.jellyfin-provisioner-image` used only
as a Kubernetes initContainer. It SHALL mount retained `/config`, use the
exact pinned v12.1 source plus PR #17902 patch, and complete before the stock
runtime can become ready. In Provision mode it SHALL run only its internal
`SetupServer`. The official runtime SHALL be completely stock and SHALL remain
the only long-lived Jellyfin process.

#### Scenario: Fresh retained state is provisioned
- **WHEN** a Pod starts with an empty retained `/config`
- **THEN** the provisioner completes first-start initialization, exits
  successfully, and only then can the stock official runtime start and pass
  readiness

#### Scenario: Provision mode runs
- **WHEN** the provisioner executes its patched Provision mode
- **THEN** it runs only its internal `SetupServer`, and no externally routable
  stock-runtime backend exists until provisioning completes

#### Scenario: The stock runtime is inspected
- **WHEN** the long-lived Jellyfin process is identified after init completion
- **THEN** it comes from the pinned official runtime image, not from the
  patched provisioner image or a Nix-rebuilt multimedia image

### Requirement: Provisioning credentials are assembled only at runtime

Credential-bearing provision input SHALL be assembled at runtime from
Nix-rendered non-secret values and an agenix-managed Kubernetes Secret or
mounted secret file. The final file SHALL live only in a restrictive
memory-backed volume during provisioning and SHALL be removed afterward. It
SHALL NOT enter Git, generated manifests, the Nix store, logs, command-line
arguments, or retained `/config`.

#### Scenario: A provisioner artifact is built without secret access
- **WHEN** an authorized maintainer evaluates or builds the provisioner image
  without administrator secret keys
- **THEN** the image and generated non-secret resources contain no private
  administrator credential

#### Scenario: Runtime-only provision input is used
- **WHEN** a Pod runs the provisioner
- **THEN** the credential-bearing input is assembled in memory with restrictive
  ownership, is not printed or passed as an argument, and is removed after
  provisioning

### Requirement: Repeated Provision mode is a safe no-op

Provisioning an already initialized Jellyfin `/config` SHALL succeed as a
no-op. A repeated initContainer run SHALL NOT reset the administrator
password, recreate users or libraries, reset retained state, overwrite
Jellarr-managed settings, or fail merely because setup was completed. If the
upstream patch lacks this behavior, the implementation SHALL carry only the
smallest Provision-mode compatibility adjustment and SHALL NOT parse or rewrite
Jellyfin's internal database to manufacture idempotence.

#### Scenario: An initialized Pod is recreated
- **WHEN** the initContainer runs against an already initialized `/config`
- **THEN** it exits successfully, preserves credentials and application state,
  and the stock runtime starts normally

#### Scenario: A repeated run meets Jellarr-owned state
- **WHEN** Provision mode is rerun after Jellarr has reconciled a selected
  setting
- **THEN** the provisioner leaves that setting unchanged

### Requirement: Provisioning failures after preflight remain visible

Provisioning SHALL validate required inputs before mutation where possible, but
it SHALL be treated as non-transactional after preflight. A failure after
preflight SHALL fail the initContainer, SHALL prevent stock-runtime readiness,
and SHALL expose an actionable failure outcome without claiming automatic
rollback or silently retrying into an unknown retained state.

#### Scenario: A post-preflight operation fails
- **WHEN** a focused test injects a failure after Provision mode has passed
  preflight
- **THEN** the initContainer reports failure, the stock runtime does not become
  ready, and the test records the resulting retained-state condition

### Requirement: Steady-state configuration uses supported APIs only

The provisioner SHALL own fresh-state initialization only. Routine steady-state
configuration SHALL NOT copy or overwrite Jellyfin internal XML and SHALL NOT
write Jellyfin SQLite directly. Jellarr SHALL be the selected ongoing owner
only for API-exposed fields explicitly present in its declarative
configuration, and unspecified fields SHALL remain application-owned.

#### Scenario: A selected setting drifts
- **WHEN** an API-exposed Jellarr-owned setting is changed away from its
  declared value and the one-shot reconciliation runs
- **THEN** Jellarr restores the value through an authenticated supported
  Jellyfin API without direct XML or SQLite manipulation

#### Scenario: An unspecified setting changes
- **WHEN** a setting is not present in Jellarr's declarative configuration
- **THEN** reconciliation leaves it application-owned rather than resetting it

#### Scenario: Startup wizard ownership is checked
- **WHEN** Jellarr's configuration is evaluated
- **THEN** it does not configure `startup.completeStartupWizard`, because that
  field belongs to the first-start provisioner

### Requirement: Jellarr runs once after healthy stock runtime

Jellarr v0.1.0 SHALL run as one pinned declarative one-shot Job after the stock
Jellyfin Service is healthy. Its Job/initContainer SHALL use supported
Jellyfin authentication and API-key endpoints: authenticate with the normal
administrator credential, find a named Jellarr key, create it only when
missing, re-read it, and pass the token through an ephemeral memory-backed
shared volume to the Jellarr process. The generated key SHALL NOT be published
as a durable Kubernetes Secret or copied into agenix. Job failure SHALL be
visible, and a desired configuration change SHALL cause another one-shot run.

#### Scenario: Jellarr has no existing API key
- **WHEN** the healthy stock runtime has no API key named for Jellarr
- **THEN** the Job authenticates through supported APIs, creates exactly one
  key, re-reads it, and Jellarr reconciles using a token held only in shared
  ephemeral memory

#### Scenario: Jellarr runs again
- **WHEN** the one-shot reconciliation runs a second time with the existing
  named key
- **THEN** it reuses that key, creates no duplicate, and leaves the resulting
  desired configuration unchanged

#### Scenario: Jellarr starts before Jellyfin is healthy
- **WHEN** the stock Service is not healthy
- **THEN** the Jellarr Job waits or fails visibly and does not attempt a hidden
  direct database bootstrap

### Requirement: Jellyfin has one normal declarative administrator

The first-start provisioner SHALL create one normal administrator whose
credential source and desired policy are explicit. The password SHALL remain
agenix-owned at rest. Jellarr MAY reconcile supported administrator policy or
password fields only when declared, but the workload SHALL NOT rely on a
second undocumented bootstrap or automation administrator.

#### Scenario: Fresh state creates the administrator
- **WHEN** the provisioner initializes an empty `/config`
- **THEN** the declared normal administrator is created and can authenticate to
  the stock runtime after readiness

#### Scenario: Administrator ownership is reviewed
- **WHEN** a proposed design adds another administrator for automation
- **THEN** the change identifies its lifecycle and retention explicitly or is
  rejected in favor of the one normal declarative administrator

### Requirement: Application startup ownership is explicit

Nix/Den and Kubernetes/Argo SHALL own workload declarations, retained storage
and media mounts, resource/security policy, Service/Gateway objects, release
pins, and declarative Jellarr configuration. The patched provisioner SHALL own
fresh-state SetupServer initialization and initial administrator creation. The
stock official runtime SHALL own normal serving, database/state internals,
media processing, and unspecified settings. Jellarr SHALL own only selected
supported API fields. Preserve SHALL own backup/recovery policy and
retained-state protection. No owner SHALL silently write another owner's
boundary.

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

### Requirement: Jellyfin has read-only access to shared media

Jellyfin SHALL read its declared library without write authority, even when
other workloads have write access to the shared media source.

#### Scenario: Jellyfin shares a media source with writers
- **WHEN** Jellyfin reads a library that acquisition workloads can modify
- **THEN** Jellyfin can consume the library but cannot change its contents
