## Purpose

Define the durable routing, trust, lifecycle, and evidence boundaries for exposing independently managed household services.

## ADDED Requirements

### Requirement: Declared service route inventory

The system SHALL derive every managed service entrance from one declarative route inventory. Each route SHALL identify its declared hostnames, backend service, authentication mode, exposure class, backend trust mode, and request timeout policy.

#### Scenario: Route is rendered for an internal entrance
- **WHEN** a service route is enabled
- **THEN** the internal entrance uses that route's declared hostnames, backend, authentication, trust, and timeout policy

### Requirement: Independent public entrances

The system SHALL publish only routes explicitly classified as public through an independent public entrance. A service classified as private SHALL remain available through the internal entrance without being published by that public entrance.

#### Scenario: Private route shares the internal gateway
- **WHEN** a private and a public route use the same internal gateway
- **THEN** the public entrance forwards the public route and omits the private route

#### Scenario: Unrelated application workload is unavailable
- **WHEN** one routed application workload other than shared ingress or identity is stopped or unhealthy
- **THEN** shared ingress and identity services remain independently operable

### Requirement: Explicit origin and backend trust

The system SHALL distinguish direct internal ingress from ingress through configured trusted public edges. Backend TLS verification SHALL use the backend's declared identity and trust source; verification SHALL NOT be disabled.

#### Scenario: Trusted-edge ingress is enabled
- **WHEN** an independent public entrance forwards a request to the internal gateway
- **THEN** the gateway accepts forwarded client identity only from the configured trusted edge peers

#### Scenario: Direct ingress is enabled
- **WHEN** a request reaches the internal gateway without a configured trusted public edge
- **THEN** the gateway derives client identity directly from its downstream peer connection

#### Scenario: TLS backend is routed
- **WHEN** a route uses TLS to its backend
- **THEN** the gateway verifies the certificate chain and the route's declared backend hostname

### Requirement: Canonical identity backend uses public PKI

The canonical identity backend SHALL present a certificate for its canonical identity hostname that verifies through publicly trusted system roots. Gateway and provisioning clients SHALL perform strict hostname verification and SHALL NOT receive a private-CA runtime trust input for that backend.

#### Scenario: Identity backend TLS is configured
- **WHEN** the gateway or a provisioning client connects to the canonical identity backend
- **THEN** it verifies the canonical identity hostname through system roots without a custom CA file, trust mount, or verification bypass

### Requirement: Trusted client identity reconstruction

The public edge SHALL discard client-supplied forwarding and identity metadata and create sanitized values from its peer connection. The internal gateway SHALL accept that forwarded client identity only from explicitly trusted edge peers; direct mode SHALL derive client identity from the gateway's peer connection. The first trusted proxy SHALL generate or normalize the trusted request identifier, and downstream trusted proxies SHALL propagate it. Access logs SHALL omit URL query strings.

#### Scenario: Client spoofs forwarding headers
- **WHEN** a request supplies forwarding or client-identity headers
- **THEN** the first trusted proxy discards them and creates sanitized values rather than forwarding the supplied values

#### Scenario: Trusted request identifier traverses both proxies
- **WHEN** a request enters through an independent public edge
- **THEN** the edge generates or normalizes one trusted request identifier and the internal gateway propagates it

#### Scenario: Request contains credentials in its query
- **WHEN** a routed request contains a query string
- **THEN** proxy access logs record the path without the query string

### Requirement: Canonical identity lifecycle

The identity service SHALL have explicit initial and normal operating phases. The initial phase SHALL expose the minimum retained service needed for operator bootstrap and SHALL omit dependent provisioning credentials, jobs, integrations, and cross-namespace publication rights. The normal phase MAY enable those dependents only after the operator has completed and recorded the bootstrap transition.

#### Scenario: Fresh identity deployment
- **WHEN** the identity service is in its initial phase
- **THEN** bootstrap-dependent credentials, provisioning, OIDC publication, and cross-namespace publication rights are absent

#### Scenario: Bootstrap transition completes
- **WHEN** the operator has escrowed recovery credentials, enrolled durable human authentication, encrypted the required provisioning credential, and selects normal phase
- **THEN** declarative provisioning and application integration may reconcile

### Requirement: Kanidm state exposes a Preserve-facing integration seam

The identity service SHALL expose stable facts describing the durable Kanidm state boundary, its stable identity and location, its authoritative live capability boundary and runtime access projections, and the consistency, fidelity, quiescence, version, and application-native payload constraints intrinsic to Kanidm. Those facts SHALL be sufficient for the Preserve workstream to define the corresponding StateSlot, State, Realization, and future application-native Integration without rediscovering the application contract.

The service SHALL record Kanidm's native online-backup/export capability as future Preserve integration input. Until Preserve selects and implements compatible State, ProtectionPolicy, Route, Target, and lifecycle-owner wiring, the discovery SHALL remain non-operational and SHALL NOT create an identity-owned adapter, schedule, retention policy, off-host route, verification policy, restore workflow, or second protection subsystem.

#### Scenario: Preserve has not integrated Kanidm
- **WHEN** Kanidm durable-state and native-export facts are recorded but Preserve has not selected and implemented the corresponding state-protection declarations and lifecycle owner
- **THEN** the facts remain future integration input without claiming protection or scheduling a backup

### Requirement: Structural and live acceptance evidence

Static evaluation SHALL prove route inventory, exposure filtering, trust policy, lifecycle gating, and non-overlapping declared and generated desired-state ownership. The system SHALL NOT treat those structural checks as evidence of live cluster ownership, DNS, certificate, proxy, authentication, logging, or failure-isolation behavior.

#### Scenario: Configuration checks pass before deployment
- **WHEN** structural checks pass without exercising the deployed request path
- **THEN** live end-to-end acceptance remains open and is reported separately
