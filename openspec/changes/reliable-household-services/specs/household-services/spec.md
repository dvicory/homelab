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

The selected configuration tool and external policy inputs SHALL identify their pinned versions and content provenance. Rebuilding managed configuration SHALL NOT silently follow newer upstream policy or require live upstream policy content. Declared Arr root records, profiles, scored formats and download clients SHALL have one native configuration owner; managed Prowlarr registrations SHALL NOT erase UI-owned applications. Reconciliation MAY remove undeclared Arr root records, but SHALL NOT remove media files or unrelated application accounts and records. Malformed policy or a rejected API write SHALL fail visibly rather than report successful repair. Policy reconciliation alone SHALL NOT initiate media search, upgrades or deletion.

#### Scenario: Upstream policy changes
- **WHEN** media policy is rebuilt after the upstream guide changes
- **THEN** the selected release and inputs produce the declared configuration without adopting the newer guide

#### Scenario: Reconciliation follows a user edit
- **WHEN** a declared Arr root record changes while an unrelated Prowlarr application and media files exist
- **THEN** the root record returns to its declared value, the unrelated application and files survive, and no media action starts solely from policy reconciliation

### Requirement: Cross-application configuration waits for its prerequisites

Initial media reconciliation SHALL wait for healthy workload Applications and the Jellyfin-owned integration readiness boundary before using their APIs. Supported-API checks SHALL tolerate bounded startup variance. Git revisions SHALL rerun ordered PostSync Jobs without manual first-cluster intervention. After successful initial convergence, unsuspended Configarr and Seerr Jobs SHALL repair drift on staggered roughly six-hour schedules without overlapping runs or unbounded retries; failed repair SHALL remain visible and SHALL NOT mark a rejected API write successful.

#### Scenario: All services arrive from one fresh-cluster revision
- **WHEN** media workloads and Jellyfin integration become ready after the configuration declaration
- **THEN** media configuration eventually completes without an operator manually re-syncing Argo

### Requirement: Seerr integration roles and account ownership are explicit

Exactly one Radarr and one Sonarr instance SHALL be selected by semantic role as Seerr's standard default backends. Optional 4K instances SHALL remain independent, and adding or renaming another instance SHALL NOT implicitly change either default; missing or duplicate defaults SHALL be rejected. Seerr SHALL consume the configured Jellyfin endpoint, libraries and owner credential without creating or resetting Jellyfin accounts or libraries. Its first-owner claim SHALL run privately using that credential, and later reconciliation SHALL use a stable operator-owned Seerr API key. Seerr SHALL recognize availability from the Jellyfin libraries and integrate the selected Arr backends.

#### Scenario: A secondary Arr instance is introduced
- **WHEN** another instance is declared without the Seerr default role
- **THEN** Seerr continues using the explicitly selected backend; zero or multiple defaults of either kind fail configuration

#### Scenario: Jellyfin libraries are already configured
- **WHEN** Seerr reconciliation runs after the Jellyfin-owned configuration is ready
- **THEN** Seerr uses the intended libraries and recognizes their content without creating duplicate Jellyfin libraries or credentials

### Requirement: Media exposure preserves native user authentication

The household-facing Seerr request route SHALL be absent while first-owner setup is claimable. It MAY be published only after Seerr reports initialized, its intended Jellyfin library has synchronized, and selected Arr defaults are verified. Once published, the route SHALL admit users to Seerr's native Jellyfin/local sign-in while Seerr governs application roles. Radarr, Sonarr, Prowlarr and SABnzbd browser administration SHALL remain administrator-only at the edge; internal automation SHALL use authenticated native APIs. Runtime credentials SHALL NOT appear in rendered manifests or policy assets.

#### Scenario: A non-administrator opens the request UI
- **WHEN** a household user accesses Seerr but lacks the edge administrator role
- **THEN** the user can reach Seerr's native sign-in without gaining Arr or downloader administration

#### Scenario: Fresh Seerr cannot yet authenticate a household user
- **WHEN** a retained Seerr instance has no owner or its Jellyfin library integration is incomplete
- **THEN** no public requests route exists, and an API key alone cannot bypass first-owner authentication

### Requirement: Runtime acceptance covers actual pinned application behavior

A completed integration claim SHALL be supported by a bounded disposable run against the pinned Radarr, Sonarr, Prowlarr, SABnzbd, Seerr, Configarr and Jellyfin releases. It SHALL exercise credential acceptance and rotation, root/profile/download-client configuration, Prowlarr registration, SAB configuration, private Seerr first-owner and selected Jellyfin/Arr integration, idempotent repetition, malformed policy and rejected API writes, and preservation of UI-owned records and filesystem media when an Arr root record is removed. It SHALL confirm no search or upgrade command is started solely by reconciliation. External indexer/provider availability and production credentials are not prerequisites for that local evidence; whole-cluster Argo convergence remains a separate hosted acceptance gate.

#### Scenario: Configuration is rerun against real services
- **WHEN** the same selected policy is applied twice to the pinned running applications after an unmanaged record is created
- **THEN** the supported APIs accept the declared settings, the rerun is idempotent and the unmanaged record survives
