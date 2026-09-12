## Purpose

Define client-compatible household access through independently placed public edges without extending public exposure to substrate management.

## ADDED Requirements

### Requirement: Public ingress placement is independent of application compute

Public ingress SHALL support an edge outside the application cluster and a separately reachable home edge, both serving the same declared applications. Remote-to-origin transport SHALL be private and authenticated. Application routing SHALL have one declarative source rather than independently maintained edge route inventories. Failure of the normal public edge SHALL NOT itself prevent the home edge or independent management path from operating.

#### Scenario: The remote edge is unavailable
- **WHEN** an operator uses the configured home backup entrance while the application origin and home connection remain available
- **THEN** declared native-authentication services remain reachable without restoring the remote edge or making the replacement edge a cluster member; fresh centralized-identity sessions require the documented canonical-identity failover when that entrance is affected

### Requirement: Recovery routing preserves explicit application URL constraints

Ingress SHALL support configurable primary and backup service hostnames and application-supported path prefixes. Unsupported prefixes SHALL be rejected rather than emulated through response rewriting. Alternate names SHALL account for application canonical URLs, authentication callbacks, and client configuration. Same-name DNS failover SHALL be an explicit operator action with DNS caching and home-origin exposure documented; public DNS changes SHALL NOT occur as an implicit deployment side effect.

#### Scenario: An application requires a hostname-root URL
- **WHEN** a non-root prefix is configured for that application
- **THEN** configuration validation rejects the unsupported URL before deployment

#### Scenario: An operator selects a backup URL
- **WHEN** the alternate entrance is used
- **THEN** its TLS identity and applicable authentication redirects are valid, and any application/client URL switch or canonical-identity DNS failover required for recovery is explicit rather than implied to be instantaneous

### Requirement: Public authentication is compatible with supported clients

Public household services SHALL enforce application-native authentication, with centralized identity where supported. Ordinary media and photo clients SHALL NOT require a browser-only pre-authentication flow for every API or media request. Browser administration exposed publicly SHALL require strong authentication and administrator authorization, including denial of direct unauthenticated backend access. Forwarded client identity and addressing SHALL be trusted only from declared proxies.

#### Scenario: A household client reaches a public application
- **WHEN** an authorized supported mobile or media client authenticates
- **THEN** it can exercise its permitted API/media operations without an incompatible intermediary login, while an unauthenticated client cannot access private user content

#### Scenario: A non-administrator targets administration or spoofs proxy headers
- **WHEN** the requester lacks administrator authorization or supplies untrusted identity headers
- **THEN** the administrative operation is denied and supplied headers do not establish trust

### Requirement: Administrative browser exposure is separate from API client exposure

Public administrative browser access SHALL NOT implicitly provide a browser-login bypass for non-browser API clients. Native authenticated API access SHALL remain available through the declared private access boundary independently of browser gateway authentication. Any approved public API client path SHALL be implementable without replacing application state or removing native authentication.

#### Scenario: A private automation client uses an administratively exposed application
- **WHEN** it connects through the declared private boundary with valid native API credentials
- **THEN** its supported operations do not require a browser login; invalid credentials are rejected

#### Scenario: A non-browser client targets the public administrative address
- **WHEN** it has no authorized browser session and no separately approved public API access path
- **THEN** it cannot bypass administrator authorization using only the application's API key, while authenticated browser UI requests remain usable

### Requirement: Public application ingress does not expose raw management protocols

SSH, cluster APIs, database protocols, and recovery credentials SHALL remain outside public application ingress. Management access SHALL retain a recovery path independent of cluster, public-edge, and centralized identity availability, consistent with management-boundaries.

#### Scenario: Identity or application compute is unavailable
- **WHEN** an operator needs to repair the failed service
- **THEN** independent private management access remains usable without first restoring that service
