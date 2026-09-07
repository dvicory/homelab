## Purpose

Make service, capacity, and recovery failures visible through standard observability tooling without making that tooling a prerequisite for recovery.

## ADDED Requirements

### Requirement: Operational collection is bounded and does not grant application authority

Managed metrics and logs SHALL have explicit resource and retention limits. Collection SHALL NOT require write access to household content or place credentials in labels or rendered configuration artifacts. Failure or exhaustion of observability storage SHALL NOT prevent independent management of the substrate.

#### Scenario: Observability retention is reached
- **WHEN** collected history reaches its declared retention boundary
- **THEN** old history can be retired without deleting application state or blocking substrate recovery

### Requirement: Alerts describe actionable service and recovery failures

The platform SHALL report service unavailability, storage capacity pressure, and failed or stale recovery points through established alert routing software. Alerts SHALL identify the affected service or resource, expose the condition and its resolution, and support grouping and routing to operator-selected destinations without a custom notification broker. Missing collection targets SHALL NOT be interpreted as healthy services.

#### Scenario: An application becomes unavailable and recovers
- **WHEN** the failure persists beyond the configured tolerance and the application subsequently recovers
- **THEN** an operator-visible alert fires and resolves through the configured notification route

#### Scenario: A recovery operation fails
- **WHEN** an export fails or no sufficiently recent complete recovery point exists
- **THEN** the failure or staleness is visible independently of a successful application readiness probe

### Requirement: Dashboards and notification claims have runtime evidence

Operational dashboards SHALL expose current service and storage health using collected data. Local notification verification MAY use a disposable receiver; the handoff SHALL distinguish it from delivery to a real external account.

#### Scenario: External credentials have not been provisioned
- **WHEN** local acceptance exercises a configured disposable notification destination
- **THEN** the observed delivery is recorded as local evidence and external account delivery remains an explicit unverified prerequisite
