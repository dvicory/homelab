## Purpose

Define the durable routing, trust, lifecycle, ownership, and evidence boundaries for exposing independently managed household services.

## ADDED Requirements

### Requirement: Declared service route inventory

The system SHALL derive every managed service entrance from one declarative route inventory. Each declared route SHALL contain one or more non-empty hostnames, a backend service, an authentication mode, an exposure class, a backend protocol/TLS declaration, and a request-timeout policy. A TLS declaration SHALL name the backend certificate hostname and select the platform-declared system trust source unless a future contract adds another supported source. Route presence is the declaration; service selection or default metadata alone SHALL NOT publish a route. Exposure SHALL express intended public access independently of bootstrap readiness. The contract SHALL NOT impose a universal hostname count, order, or domain-family rule.

#### Scenario: A declared route is rendered for an internal entrance

- **WHEN** a route is present in the declarative inventory
- **THEN** the internal entrance uses that route's declared hostnames, backend service, authentication, exposure, trust, and timeout policy

#### Scenario: Public permission precedes bootstrap completion

- **WHEN** a declared public route has unmet bootstrap requirements
- **THEN** public permission remains declared while the required safety gate withholds access

### Requirement: Independent public entrances

The gateway SHALL provide separate public and private application entries and own TLS termination, HTTP routing, and authentication policy. The public entry SHALL serve only routes explicitly classified as public and permitted by their bootstrap gates. A private route whose bootstrap requirements are met SHALL remain available through its authorized private entry without becoming reachable through public entry. A public transport relay SHALL carry encrypted application connections without terminating their TLS or owning their HTTP policy.

#### Scenario: Public entry receives a private hostname

- **WHEN** a public connection names a private route through SNI, HTTP authority, or forwarding headers
- **THEN** the request cannot reach that route's backend

#### Scenario: A public hostname is undeclared

- **WHEN** a public connection names a hostname absent from the permitted public route inventory
- **THEN** public entry rejects the connection or request without selecting a fallback application

#### Scenario: An unrelated application workload is unavailable

- **WHEN** one routed application workload other than shared ingress or identity is stopped or unhealthy
- **THEN** shared ingress, identity, and independently routed healthy workloads remain operable without depending on the failed workload

### Requirement: A transport peer cannot reach private services

The system SHALL limit each public transport peer to its declared public application receiver over an authenticated private link. That peer SHALL NOT gain network access to private application entry, application backends, the cluster API, or host and guest management services. A reported client address SHALL NOT grant application or administrator authority.

#### Scenario: A transport peer attempts a bypass

- **WHEN** the peer attempts a connection outside its declared public application receiver
- **THEN** the network boundary denies the connection even if the peer controls its own transport metadata

#### Scenario: The firewall rule manager stops

- **WHEN** the firewall rule manager stops while public transport remains available
- **THEN** the approved public-peer restrictions remain enforced rather than exposing management or private services

#### Scenario: A replacement firewall policy cannot load

- **WHEN** a replacement firewall policy is invalid or cannot be applied
- **THEN** the previously approved restrictions remain enforced and the failed update does not create an unfiltered public path

#### Scenario: A peer reports an administrator's network address

- **WHEN** the peer reports a client address associated with an administrator
- **THEN** the application still requires its declared authentication and authorization

### Requirement: Private access is independent of public transport

The private application entry SHALL retain its authorized direct access when the public relay or its private link is unavailable. Private classification SHALL NOT require a particular VPN product. A direct entry SHALL NOT require or trust relay-supplied client-address metadata.

#### Scenario: Public transport is unavailable

- **WHEN** the public relay or its link stops
- **THEN** authorized private clients can still use the private entry and its normal sign-in

#### Scenario: A direct client sends transport metadata

- **WHEN** an ordinary direct client sends a relay metadata preamble instead of its normal TLS connection
- **THEN** the private entry does not accept the claimed client identity

### Requirement: Public administrator exposure follows identity phase

An administrator-authenticated route classified as public SHALL NOT be published or accepted while identity is in its initial or provisioning phase. Normal phase SHALL declare the route and its corresponding SecurityPolicy in one Argo Application, order the policy before the route, and SHALL NOT expose an unauthenticated fallback.

#### Scenario: Identity is not normal

- **WHEN** an administrator-authenticated route is public while identity remains initial or provisioning
- **THEN** every entrance omits or denies the route and no public request reaches the backend

#### Scenario: Normal identity phase supplies the administrator policy

- **WHEN** identity reaches normal and the policy and route reconcile
- **THEN** the policy is applied before the route and the route is never owned or published without it

### Requirement: Explicit origin and backend trust

The system SHALL separate ordinary direct connections from connections carrying trusted transport metadata. Only an authenticated declared relay peer on its restricted receiver SHALL supply a reported client address. The gateway SHALL reject missing or malformed metadata on that receiver and SHALL NOT use HTTP forwarding headers as evidence of the original client address. For a TLS backend, the gateway SHALL verify the declared backend certificate hostname and certificate chain against platform system roots; verification SHALL NOT be disabled.

#### Scenario: A relay reports a client address

- **WHEN** an authenticated declared peer supplies valid transport metadata on its receiver
- **THEN** the gateway records that reported client address without treating it as application authorization

#### Scenario: Relay metadata is missing or malformed

- **WHEN** a connection to the relay receiver lacks valid transport metadata
- **THEN** the connection is rejected without falling back to a direct-client mode

#### Scenario: Direct ingress is used

- **WHEN** an authorized client reaches the private entry directly
- **THEN** the gateway derives the client address from its downstream connection, not client-supplied headers

#### Scenario: A TLS backend route is declared

- **WHEN** a route uses TLS to its backend
- **THEN** the gateway verifies the declared backend hostname and certificate chain using the platform-declared system trust source

### Requirement: Kanidm canonical identity uses public PKI

The first identity-route hostname SHALL be Kanidm's canonical issuer, SNI, and certificate identity. Direct and secondary-edge access SHALL preserve that canonical identity; failover MAY change DNS routing but SHALL NOT introduce another issuer or certificate name. Gateway and provisioning clients SHALL use strict hostname verification through public system roots and SHALL NOT receive a private-CA runtime trust input.

#### Scenario: Identity traffic uses either entrance

- **WHEN** a gateway or provisioning client reaches Kanidm directly or after DNS failover
- **THEN** it verifies the same canonical hostname through system roots without a custom CA file, trust mount, or verification bypass

### Requirement: Trusted client address and request-ID reconstruction

The gateway, as the first HTTP policy owner, SHALL discard client-supplied forwarding, end-user identity, and request-ID metadata and generate a fresh request identifier. It SHALL derive client-address metadata from the direct connection or the declared trusted transport source. Backend requests and gateway access records SHALL use the same generated identifier. Access logs SHALL omit URL query strings. The encrypted TCP relay SHALL NOT be required to inspect HTTP or generate an HTTP request identifier.

#### Scenario: A client spoofs forwarding or request-ID headers

- **WHEN** a direct or relayed request supplies forwarding, end-user identity, or request-ID headers
- **THEN** the gateway discards those values, uses the declared client-address source, and generates a fresh request identifier

#### Scenario: A request is traced through the gateway

- **WHEN** a relayed request reaches an application backend
- **THEN** the backend and gateway access record contain the same non-empty identifier generated by the gateway, not the value supplied by the client

#### Scenario: A request contains credentials in its query

- **WHEN** a routed request contains a query string
- **THEN** gateway access logs record the path without the query string

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

Disposable runtime acceptance SHALL exercise the rendered gateway, real TCP transport, and enforced network boundaries without requiring a production edge, provider account, or production credentials. It SHALL verify public/private isolation, transport-peer containment, metadata handling, TLS, administrator and application authentication, and continued direct private access. Deployment acceptance SHALL separately verify the real link, DNS, certificates, client behavior, long requests, logging, and failure isolation before public activation.

#### Scenario: Configuration checks pass before deployment

- **WHEN** structural checks pass without exercising the deployed request path
- **THEN** live end-to-end acceptance remains open and is reported separately

#### Scenario: A disposable transport proof runs

- **WHEN** the relay and gateway run in owned test networks with fixture credentials
- **THEN** acceptance exercises the actual TLS and request path, rejects private-route and management bypasses, verifies trusted client-address handling and gateway-generated request identifiers, and checks authentication without claiming production acceptance

#### Scenario: The deployed path is accepted

- **WHEN** public activation is proposed
- **THEN** the real endpoint, link, DNS, certificates, authorized and denied sign-ins, long requests, and independent private access are verified separately from disposable results
