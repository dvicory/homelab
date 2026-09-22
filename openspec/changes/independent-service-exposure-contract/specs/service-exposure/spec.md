## Purpose

Define the durable routing, trust, lifecycle, ownership, and evidence boundaries for exposing independently managed household services.

## ADDED Requirements

### Requirement: Declared service route inventory

The system SHALL derive every managed service entrance from one declarative route inventory. Each declared route SHALL contain one or more non-empty hostnames, a backend service, an authentication mode, an exposure class, a backend protocol/TLS declaration, and a request-timeout policy. A TLS declaration SHALL name the backend certificate hostname and select the platform-declared system trust source unless a future contract adds another supported source. Route presence is the declaration; this contract SHALL NOT require a separate boolean presence flag or impose a universal hostname count, order, or domain-family rule. Each consuming edge SHALL validate any additional hostname shape or cardinality it requires before emitting an entrance.

#### Scenario: A declared route is rendered for an internal entrance

- **WHEN** a route is present in the declarative inventory
- **THEN** the internal entrance uses that route's declared hostnames, backend service, authentication, exposure, trust, and timeout policy

### Requirement: Independent public entrances

The system SHALL publish only routes explicitly classified as public through an independent public entrance. A route classified as private SHALL remain available through the internal entrance without being published by that public entrance. A public-edge consumer SHALL omit a route or fail closed if its own hostname cardinality or domain-family policy rejects the declaration.

#### Scenario: A private route shares the internal gateway

- **WHEN** a private and a public route use the same internal gateway
- **THEN** the public entrance forwards the public route and omits the private route

#### Scenario: A public edge rejects route hostname shape

- **WHEN** a public route does not satisfy the cardinality or domain-family policy declared by a consuming edge
- **THEN** that edge emits no entrance for the route or fails closed rather than guessing a hostname

#### Scenario: An unrelated application workload is unavailable

- **WHEN** one routed application workload other than shared ingress or identity is stopped or unhealthy
- **THEN** shared ingress, identity, and independently routed healthy workloads remain operable without depending on the failed workload

### Requirement: Public administrator exposure follows identity phase

An administrator-authenticated route classified as public SHALL NOT be published or accepted while identity is in its initial or provisioning phase. Normal phase SHALL declare the route and its corresponding SecurityPolicy in one Argo Application, order the policy before the route, and SHALL NOT expose an unauthenticated fallback.

#### Scenario: Identity is not normal

- **WHEN** an administrator-authenticated route is public while identity remains initial or provisioning
- **THEN** every entrance omits or denies the route and no public request reaches the backend

#### Scenario: Normal identity phase supplies the administrator policy

- **WHEN** identity reaches normal and the policy and route reconcile
- **THEN** the policy is applied before the route and the route is never owned or published without it

### Requirement: Explicit origin and backend trust

The system SHALL distinguish direct internal ingress from ingress through configured trusted public edges. In trusted-edge mode, only configured peers may supply forwarded client-address metadata. Client-supplied end-user identity and request identifiers SHALL be discarded at the first trusted proxy. For a TLS backend, the gateway SHALL verify the declared backend certificate hostname and certificate chain against platform system roots; verification SHALL NOT be disabled.

#### Scenario: A trusted-edge entrance is declared

- **WHEN** an independent public entrance forwards a request to the internal gateway
- **THEN** the gateway accepts forwarded client-address metadata only from configured trusted edge peers

#### Scenario: Direct ingress is declared

- **WHEN** a request reaches the internal gateway without a declared trusted public edge
- **THEN** the gateway derives the client address directly from its downstream peer connection

#### Scenario: A TLS backend route is declared

- **WHEN** a route uses TLS to its backend
- **THEN** the gateway verifies the declared backend hostname and certificate chain using the platform-declared system trust source

### Requirement: Kanidm canonical identity uses public PKI

The first identity-route hostname SHALL be Kanidm's canonical issuer, SNI, and certificate identity. Direct and secondary-edge access SHALL preserve that canonical identity; failover MAY change DNS routing but SHALL NOT introduce another issuer or certificate name. Gateway and provisioning clients SHALL use strict hostname verification through public system roots and SHALL NOT receive a private-CA runtime trust input.

#### Scenario: Identity traffic uses either entrance

- **WHEN** a gateway or provisioning client reaches Kanidm directly or after DNS failover
- **THEN** it verifies the same canonical hostname through system roots without a custom CA file, trust mount, or verification bypass

### Requirement: Trusted client address and request-ID reconstruction

The first trusted public proxy SHALL discard client-supplied forwarding, end-user identity, and request-ID metadata, reconstruct trusted client-address metadata from its peer connection, and generate a fresh request identifier. The internal gateway SHALL accept forwarded client-address metadata only from configured edge peers and SHALL preserve the edge-generated request identifier unchanged; direct mode SHALL derive the client address from the gateway's peer connection. Access logs SHALL omit URL query strings.

#### Scenario: A client spoofs forwarding or request-ID headers

- **WHEN** a request supplies forwarding, end-user identity, or request-ID headers
- **THEN** the first trusted proxy discards the supplied values and creates trusted client-address metadata plus a fresh request identifier

#### Scenario: A trusted request identifier traverses both proxies

- **WHEN** one request enters through an independent public edge and reaches the internal gateway
- **THEN** the gateway forwards the same non-empty edge-generated request identifier without replacing it

#### Scenario: A request contains credentials in its query

- **WHEN** a routed request contains a query string
- **THEN** proxy access logs record the path without the query string

### Requirement: Canonical identity lifecycle

The identity service SHALL have explicit initial, provisioning, and normal phases. Initial SHALL expose only the retained service needed for private operator bootstrap. Provisioning SHALL add the encrypted credential, cross-namespace publication RBAC in the identity Application, and an idempotent PostSync provisioning Job while administrator routes and policies remain absent. The Job SHALL create named administrators without granting administrator-group membership in provisioning. Normal MAY grant that membership and publish administrator access only after provisioning succeeds, durable human authentication is enrolled, and private native login is verified.

#### Scenario: A fresh identity deployment is initial

- **WHEN** the identity service is initial
- **THEN** bootstrap-dependent credentials, provisioning, OIDC publication, administrator SecurityPolicies, routes, and cross-namespace publication rights are absent

#### Scenario: Provisioning runs

- **WHEN** the operator has escrowed recovery credentials, encrypted the required provisioning credential, and selects provisioning
- **THEN** publication RBAC reconciles in the identity Application before its PostSync provisioning Job creates the named accounts without granting administrator-group membership; administrator routes remain absent

#### Scenario: Normal exposure is selected

- **WHEN** provisioning succeeds, durable human authentication is enrolled, private native login is verified, and the operator selects normal
- **THEN** the provisioning Job may grant administrator-group membership and the administrator policy and routes may reconcile atomically

### Requirement: Private bootstrap handling is documented

Operator guidance SHALL direct Kanidm `recover-account` through a private interactive Kubernetes session. It SHALL require immediate escrow or encryption, forbid persistence in Git, generated documentation, CI or service logs, durable agent transcripts, or ordinary workspace files, and require durable human authentication enrollment. It SHALL document separate initial-to-provisioning and provisioning-to-normal transitions.

#### Scenario: Bootstrap guidance is generated

- **WHEN** operations guidance is generated for a fresh identity deployment
- **THEN** it contains the private-session, immediate-escrow/encryption, non-persistence, enrollment, provisioning, verification, and normal-exposure instructions

### Requirement: Kanidm state exposes a Preserve-facing integration seam

The identity service SHALL record the durable `identity-kanidm` boundary, its stable identity and location, and Kanidm's native export capability as non-operational facts for Preserve. It SHALL NOT define an export path, cadence, retention, capture route, target, adapter, verification policy, recovery point, or restore workflow unless Preserve delegates that ownership through its lifecycle-owner Integration contract.

#### Scenario: Preserve has not integrated Kanidm

- **WHEN** Kanidm durable-state and native-export facts are recorded but Preserve has not selected and implemented the corresponding protection declarations and lifecycle owner
- **THEN** the facts remain future integration input without scheduling capture or claiming protection

### Requirement: Gateway images have exact immutable identity

The Gateway controller and data-plane SHALL each use one exact immutable multi-architecture image identity. Each identity SHALL include its repository, release tag, and digest; tag-only or mutable image references SHALL NOT satisfy this requirement.

#### Scenario: Gateway resources are rendered

- **WHEN** Gateway controller and data-plane resources are evaluated or generated
- **THEN** both resources use their declared exact immutable image identities and no mutable substitute

### Requirement: Argo convergence follows real dependencies and child health

Declared Argo Applications SHALL order retained state before workloads, Gateway CRDs before the controller, the controller before Gateway resources, cross-namespace RBAC before identity provisioning, and administrator policy before route publication. A parent Application SHALL report readiness only after each child Application reports its actual healthy status; a sync-wave annotation alone SHALL NOT be treated as child readiness.

#### Scenario: A prerequisite Application is unhealthy

- **WHEN** a prerequisite child Application is missing, degraded, or not yet healthy
- **THEN** the dependent Application remains unapplied or not ready

#### Scenario: Ordered children become healthy

- **WHEN** each prerequisite child reports healthy status in dependency order
- **THEN** reconciliation may advance to the dependent Application

### Requirement: Desired-state ownership is uniquely declared

For every generated desired-state object identity `(apiGroup, kind, namespace, name)` and every generated source directory, exactly one declared Argo Application SHALL be the owner. The desired-state declaration SHALL reject duplicate Application/object/source claims. Live cluster owner references, labels, or field managers SHALL NOT substitute for the declared ownership map.

#### Scenario: Two declared Applications claim one object

- **WHEN** two Applications or source directories declare the same generated object identity
- **THEN** evaluation fails with the conflicting identity and no ambiguous desired state is emitted

#### Scenario: Live ownership differs from declared ownership

- **WHEN** a live cluster owner reference or field manager differs from the declared owner
- **THEN** the declaration remains the source of truth and the mismatch is reported as deployment evidence rather than silently changing ownership

### Requirement: Structural and live acceptance evidence are separate

Static evaluation SHALL prove route inventory and exposure filtering, trust policy, lifecycle and administrator-route gating, exact image identity, Argo wave and child-health declarations, bootstrap guidance, and unique declared desired-state ownership. The system SHALL NOT treat those structural checks as evidence of live cluster ownership, DNS, certificate, proxy, authentication, logging, request-ID propagation, or failure-isolation behavior.

Deployment acceptance SHALL exercise both layers of the public path. For one request carrying a spoofed request identifier, live evidence SHALL capture a non-empty trusted identifier generated at the public edge, the same identifier at the internal gateway, queryless logs at both layers, and the expected authenticated response; DNS, certificates, long requests, and unrelated-application failure isolation SHALL be recorded separately.

#### Scenario: Configuration checks pass before deployment

- **WHEN** structural checks pass without exercising the deployed request path
- **THEN** live end-to-end acceptance remains open and is reported separately

#### Scenario: The deployed two-layer request proof runs

- **WHEN** a request traverses the public edge and internal gateway with a client-supplied request-ID value
- **THEN** evidence shows that the client value was discarded, one fresh identifier appears unchanged in both layers' logs, queries are absent, and the authenticated response succeeds
