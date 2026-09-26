## Purpose

Define media-acquisition and request-service ownership, access, persistence and integration guarantees on the existing Kubernetes platform without duplicating the platform or Jellyfin contracts.

## ADDED Requirements

### Requirement: Media applications retain independent state and explicit connections

Radarr, Sonarr, Prowlarr, SABnzbd and Seerr SHALL each have declared durable private state and required credentials. Multiple instances of a given Arr application SHALL retain distinct state, credentials, roots, download categories and selected policy. Reconciliation of one instance SHALL NOT reset another instance's state, accounts or content. Missing required state or credentials SHALL fail closed rather than causing substitute empty state or uncredentialed access.

#### Scenario: A second Arr instance is declared
- **WHEN** a second Radarr or Sonarr instance is delivered with its own declarations
- **THEN** it uses its own retained state and policy without replacing the first instance's state or configuration

#### Scenario: Required state is absent
- **WHEN** a declared retained configuration path or credential is unavailable
- **THEN** the dependent service cannot silently initialize replacement state or proceed without its required credential

### Requirement: Shared media access is represented honestly

The shared media writer group provides coarse filesystem write capability over accessible shared media paths; logical root/category assignments SHALL reject conflicts unless sharing is explicitly declared, but SHALL NOT be represented as per-application filesystem isolation. Jellyfin's read-only media access remains owned by its own contract.

#### Scenario: Two instances claim conflicting logical paths
- **WHEN** their declared roots/categories conflict without explicit sharing
- **THEN** configuration rejects the conflict, while no claim is made that the shared writer group enforces OS-level denial outside an instance's logical root

### Requirement: Managed policy is reconstructible and bounded

The selected configuration tool and external policy inputs SHALL identify their pinned versions and provenance. Rebuilding managed configuration SHALL NOT silently follow newer upstream policy or require live upstream policy content. Managed fields MAY be repaired on reconciliation, but unrelated application records, accounts, media and UI-owned fields SHALL survive; policy reconciliation alone SHALL NOT initiate media search, upgrades or deletion. Each managed field SHALL have one reconciliation owner.

#### Scenario: Upstream policy changes
- **WHEN** media policy is rebuilt after the upstream guide changes
- **THEN** the selected release and inputs produce the declared configuration without adopting the newer guide

#### Scenario: Reconciliation follows a user edit
- **WHEN** a managed field and an unrelated record have changed
- **THEN** the managed field returns to its declared value while the unrelated record remains intact and no media action is started solely by policy reconciliation

### Requirement: Cross-application configuration waits for its prerequisites

Initial media reconciliation SHALL wait for the required workload Applications and the Jellyfin-owned integration readiness boundary before using their APIs. Supported-API checks SHALL tolerate bounded startup variance. Reconciliation SHALL be repeatable after an ordinary Git revision or re-sync without manual first-cluster intervention and SHALL NOT run destructive first-start setup on every workload restart.

#### Scenario: All services arrive from one fresh-cluster revision
- **WHEN** media workloads and Jellyfin integration become ready after the configuration declaration
- **THEN** media configuration eventually completes without an operator manually re-syncing Argo

### Requirement: Seerr integration roles and account ownership are explicit

Exactly one Radarr and one Sonarr instance SHALL be selected as Seerr's default backends. Adding or renaming another instance SHALL NOT implicitly change either selection; missing or duplicate selections SHALL be rejected. Seerr SHALL consume the already configured Jellyfin endpoint, libraries and integration credential from their owner, not create or reset Jellyfin accounts or libraries. Seerr SHALL recognize availability from those libraries and integrate its selected Arr backends.

#### Scenario: A secondary Arr instance is introduced
- **WHEN** another instance is declared without the Seerr default role
- **THEN** Seerr continues using the explicitly selected backend; zero or multiple defaults of either kind fail configuration

#### Scenario: Jellyfin libraries are already configured
- **WHEN** Seerr reconciliation runs after the Jellyfin-owned configuration is ready
- **THEN** Seerr uses the intended libraries and recognizes their content without creating duplicate Jellyfin libraries or credentials

### Requirement: Media exposure preserves native user authentication

Seerr's household-facing request route SHALL admit users to Seerr's native Jellyfin/local sign-in while Seerr governs application roles. Radarr, Sonarr, Prowlarr and SABnzbd browser administration SHALL remain administrator-only at the edge; internal automation SHALL use their native authenticated APIs. Runtime credentials SHALL NOT appear in rendered manifests or policy assets.

#### Scenario: A non-administrator opens the request UI
- **WHEN** a household user accesses Seerr but lacks the edge administrator role
- **THEN** the user can reach Seerr's native sign-in without gaining Arr or downloader administration

### Requirement: Runtime acceptance covers actual pinned application behavior

A completed integration claim SHALL be supported by a bounded disposable run against the pinned Radarr, Sonarr, Prowlarr, SABnzbd, Seerr, Configarr and Jellyfin integration releases. It SHALL exercise credential acceptance, root/profile/download-client configuration, Prowlarr registration, SAB configuration, Seerr's Jellyfin and Arr onboarding, idempotent repetition and preservation of undeclared records. External indexer/provider availability and production credentials are not prerequisites for that local evidence.

#### Scenario: Configuration is rerun against real services
- **WHEN** the same selected policy is applied twice to the pinned running applications after an unmanaged record is created
- **THEN** the supported APIs accept the declared settings, the rerun is idempotent and the unmanaged record survives
