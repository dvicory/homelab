## ADDED Requirements

### Requirement: GitOps administration requires central sign-in by the administrator group

Once central sign-in to the GitOps control plane is declared, the control plane SHALL grant administration only to an identity that signs in to it through the central identity service and belongs to the central administrator group. That group's membership SHALL derive from the fleet administrative role. Authentication at an entrance in front of the control plane SHALL NOT by itself grant GitOps administration.

#### Scenario: An administrator signs in

- **WHEN** a member of the central administrator group signs in to the GitOps control plane through the central identity service
- **THEN** the control plane grants that identity full administration

#### Scenario: Only the entrance authenticated the request

- **WHEN** a request passes entrance-level administrator authentication but carries no control-plane sign-in
- **THEN** the control plane grants no administration on the strength of the entrance authentication

### Requirement: Identities outside the administrator group receive no GitOps access

The GitOps control plane SHALL deny every action, including read-only views, to an identity that is not granted access by an explicit declared rule. Central sign-in by an identity outside the administrator group SHALL NOT yield any GitOps access.

#### Scenario: A non-administrator signs in

- **WHEN** an identity known to the central identity service but outside the administrator group attempts to sign in to the GitOps control plane
- **THEN** the identity service refuses the sign-in or the control plane denies every action

#### Scenario: An identity leaves the administrator group

- **WHEN** the fleet administrative role no longer includes a user and provisioning reconciles the central administrator group
- **THEN** a new sign-in by that user yields no GitOps access

### Requirement: The local GitOps administrator is disabled once central sign-in is declared

The GitOps control plane's built-in local administrator SHALL be disabled whenever central sign-in to the control plane is declared, and SHALL NOT serve as a recovery path. Administering the control plane SHALL remain possible through a path that does not depend on the central identity service.

#### Scenario: Central sign-in is not yet declared

- **WHEN** central sign-in to the control plane is not declared
- **THEN** the local administrator may be enabled

#### Scenario: Central sign-in is declared

- **WHEN** central sign-in to the control plane is declared
- **THEN** the control plane rejects local administrator sign-in

#### Scenario: The central identity service fails

- **WHEN** central sign-in to the control plane fails or the central identity service is down
- **THEN** the operator can still administer the control plane through a path that does not depend on the central identity service
