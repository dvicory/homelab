## ADDED Requirements

### Requirement: Strict typed capability decoding

The broker MUST decode runtime capabilities with a closed, versioned schema before approval or activation. Unknown kinds, fields, enum values, wildcard hosts, invalid ports, userinfo, URL paths or queries, unsupported protocols, and non-canonical values MUST fail closed.

The first supported runtime capability SHALL be an exact `network-origin` containing scheme, normalized hostname or IP literal, explicit ports, and address mode.

#### Scenario: Unknown approved capability
- **GIVEN** a request containing a capability kind the broker does not implement
- **WHEN** a user attempts to approve it
- **THEN** preparation MUST fail before showing an approval prompt
- **AND** no grant or remembered rule may be stored

#### Scenario: Canonical exact origin
- **GIVEN** a valid HTTPS hostname request with omitted default port
- **WHEN** the broker prepares the request
- **THEN** it SHALL normalize the hostname and represent the destination as exact port 443
- **AND** the canonical representation SHALL be the data used for fingerprinting, display, persistence, and enforcement

### Requirement: Live grant evaluation

Gondolin DNS and HTTP enforcement hooks MUST evaluate each new request against an atomic broker-owned snapshot of active grants. Activation, revocation, expiry, and once-use consumption MUST affect subsequent matching requests without recreating the VM.

#### Scenario: Discover, approve, and retry
- **GIVEN** an active VM whose default policy denies an exact HTTP(S) origin
- **WHEN** a matching grant is approved and activated
- **THEN** the same VM generation SHALL be able to retry the request successfully

#### Scenario: Live revocation
- **GIVEN** an active VM using a task-scoped origin grant
- **WHEN** the grant is revoked
- **THEN** the next matching request MUST be denied without waiting for VM recreation or broker restart

#### Scenario: Atomic batch activation
- **GIVEN** a batch of multiple approved capabilities
- **WHEN** the broker commits activation
- **THEN** concurrent request evaluators MUST observe either none or all of the activated batch
- **AND** MUST NOT observe a partially activated batch

### Requirement: Public and private origin enforcement

Public origin grants MUST continue to reject loopback, private, link-local, metadata, multicast, and otherwise blocked resolved addresses. Private origin grants MUST require explicit approval, exact scheme/host/port, and broker-resolved pinned addresses. Synthetic DNS and every redirect MUST remain constrained by the effective grant.

#### Scenario: Public DNS rebinding
- **GIVEN** an active public-only origin grant
- **WHEN** the hostname resolves or redirects to an internal address
- **THEN** the broker MUST deny the request with a stable address-policy reason

#### Scenario: Approved private hostname
- **GIVEN** a prepared private-origin capability whose canonical preview contains pinned addresses
- **WHEN** the user approves and the guest resolves that hostname
- **THEN** synthetic DNS SHALL return only the approved pins
- **AND** HTTP requests to a different address, origin, or port MUST be denied

#### Scenario: Private pin changes
- **GIVEN** a remembered private-origin rule
- **WHEN** resolution no longer matches its approved pins
- **THEN** the broker MUST require re-preparation and approval rather than silently following the changed address

### Requirement: Scoped and persistent grants

The broker MUST support once, task, conversation, timed, profile, and executor grant scopes. Every grant MUST record its binding or remembered-rule scope, policy generation, normalized capabilities, approval principal, creation time, expiry where applicable, usage state, and revocation state.

#### Scenario: Once grant consumption
- **GIVEN** a once-scoped grant with one remaining use
- **WHEN** two matching requests race
- **THEN** at most one request SHALL consume and use the grant
- **AND** the other MUST evaluate against the post-consumption policy

#### Scenario: Expired timed grant
- **GIVEN** a timed grant whose expiry has passed
- **WHEN** a matching request is evaluated
- **THEN** the broker MUST treat the grant as inactive
- **AND** SHALL persist or audit the expiry transition without exposing request content

#### Scenario: Remembered profile rule
- **GIVEN** an approved profile-scoped exact origin rule
- **WHEN** a new environment for that profile is bound under the same policy generation
- **THEN** the broker MAY activate the matching authority without prompting
- **AND** the rule MUST remain listable and revocable

### Requirement: Policy-generation and restart safety

Runtime grants and remembered rules MUST remain subordinate to the current immutable policy generation and installed capability mechanisms. Broker restart MUST restore only valid, non-expired state before accepting mediated requests.

#### Scenario: Policy generation changes
- **GIVEN** grants created under an older policy generation
- **WHEN** the broker starts with a new policy generation
- **THEN** those grants MUST be inactive until explicitly migrated or re-approved

#### Scenario: Broker restart
- **GIVEN** a valid task grant and an expired grant in persistent storage
- **WHEN** the broker restarts
- **THEN** it SHALL rebuild one atomic snapshot containing only the valid grant
- **AND** MUST NOT briefly authorize the expired grant during startup

### Requirement: Requestable structured denials

A denied mediated request SHOULD include a bounded `suggestedCapability` only when the broker implements a capability that could authorize it. The denial MUST identify a stable reason and MUST NOT itself trigger user approval.

#### Scenario: Requestable origin denial
- **WHEN** an HTTPS request targets a syntactically valid but inactive exact origin
- **THEN** the denial SHALL identify `network.capability_inactive`
- **AND** MAY include a canonical network-origin suggestion without URL path, query, headers, or body

#### Scenario: Unsupported protocol denial
- **WHEN** the guest attempts an unsupported raw protocol
- **THEN** the denial MUST identify it as unsupported or hard-denied
- **AND** MUST NOT claim that approval can make it available

## Mechanism

- `pkgs/by-name/gondolin-broker-effect/src/domain.ts` defines versioned capability, request, grant, scope, and canonical-origin schemas.
- A grant service backed by strict SQLite tables performs transactional preparation, activation, consumption, expiry, revocation, and snapshot rebuild.
- `src/network.ts` composes immutable Nix default policy with the live grant snapshot and pins explicitly approved private resolutions.
- `src/environments.ts` supplies the bound authority context to Gondolin hook construction without embedding mutable policy in the guest.
- `_policy.nix` declares installed capability mechanisms and safe defaults; it does not enumerate every dynamically approvable hostname.
