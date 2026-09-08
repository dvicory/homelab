## Purpose

Make service, capacity, and recovery failures visible through standard observability tooling without making that tooling a prerequisite for recovery.

## ADDED Requirements

### Requirement: Operational collection is bounded and does not grant application authority

Managed metrics and logs SHALL have explicit resource and retention limits. Collection SHALL NOT require write access to household content or place credentials in labels or rendered configuration artifacts. Failure or exhaustion of observability storage SHALL NOT prevent independent management of the substrate.

#### Scenario: Observability retention is reached
- **WHEN** collected history reaches its declared retention boundary
- **THEN** old history can be retired without deleting application state or blocking substrate recovery

### Requirement: Alerts describe actionable service and recovery failures

The platform SHALL report service unavailability, storage capacity pressure, and failed or stale recovery points through established alert routing software. Recovery reporting SHALL identify the affected application consistency set; success for one set SHALL NOT conceal failure or staleness of another. Alerts SHALL identify the affected service or resource, expose the condition and its resolution, and support grouping and routing to operator-selected destinations without a custom notification broker. Missing collection targets SHALL NOT be interpreted as healthy services.

#### Scenario: An application becomes unavailable and recovers
- **WHEN** the failure persists beyond the configured tolerance and the application subsequently recovers
- **THEN** an operator-visible alert fires and resolves through the configured notification route

#### Scenario: A recovery operation fails
- **WHEN** an export fails or no sufficiently recent complete recovery point exists
- **THEN** the failure or staleness is visible independently of a successful application readiness probe

#### Scenario: One application's capture succeeds while another is stale
- **WHEN** a new complete recovery point is published for only the first application
- **THEN** the second application's stale or failed capture remains visible

### Requirement: Backup evidence distinguishes capture from protection and interruption

Operational evidence SHALL distinguish a complete local capture from successful transfer to an independently protected backup destination. Capture evidence SHALL record any writer interruption and whether affected services resumed. A restore claim SHALL identify the data set and environment actually restored rather than infer recoverability from capture success.

#### Scenario: Capture succeeds but independent transfer fails
- **WHEN** a local recovery point exists but its backup transfer fails
- **THEN** local capture remains identifiable and independent backup success is not reported

#### Scenario: A disposable restore is exercised
- **WHEN** the selected application state is restored and its consistency checked
- **THEN** evidence identifies the restored set and disposable environment without claiming production or host-loss recovery was proven

### Requirement: Dashboards and notification claims have runtime evidence

Operational dashboards SHALL expose current service and storage health using collected data. Local notification verification MAY use a disposable receiver; the handoff SHALL distinguish it from delivery to a real external account.

#### Scenario: External credentials have not been provisioned
- **WHEN** local acceptance exercises a configured disposable notification destination
- **THEN** the observed delivery is recorded as local evidence and external account delivery remains an explicit unverified prerequisite
