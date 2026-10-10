# access-control Specification

## Purpose
Define how fleet identities gain machine access, system privileges, and access to administrator applications while keeping login eligibility, transitive group membership, and administrative authority coherent and separate.

## Requirements

### Requirement: One resolved group graph determines account presence and groups

A user's effective group membership SHALL be derived from the transitive closure of the user's declared groups over the fleet group graph.

The same resolved access result SHALL determine both whether that user is present on a managed machine and which applicable system groups the account receives. A second direct-membership-only or otherwise competing account-eligibility path SHALL NOT independently decide account presence.

#### Scenario: Access is inherited transitively
- **WHEN** a user's declared group transitively implies a machine-access group accepted by a host
- **THEN** the user is eligible for an account on that host and the inherited group is present in the same resolved result

#### Scenario: No accepted access capability is resolved
- **WHEN** none of a user's effective groups match the machine's effective access gates
- **THEN** that user is not materialized as an account on the machine

### Requirement: Machine access and administrative privilege are independent

Machine-access capabilities SHALL control where an identity may log in; they SHALL NOT by themselves grant administrative privilege.

`system-access` SHALL represent broad machine access and may satisfy both `server-access` and `workstation-access`. `server-access` and `workstation-access` SHALL remain narrower alternatives and SHALL NOT imply one another. Administrative roles such as `admins` MAY confer `wheel`, but administrative role membership alone SHALL NOT confer machine login eligibility.

#### Scenario: Broad access without administration
- **WHEN** a user has `system-access` but no administrative role
- **THEN** the user may satisfy server and workstation access gates without receiving `wheel`

#### Scenario: Administration without machine access
- **WHEN** a user has an administrative role but no machine-access capability accepted by a host
- **THEN** the administrative role may imply privileged groups but the user is not granted an account on that host

#### Scenario: Narrow access remains narrow
- **WHEN** a user has only `server-access`
- **THEN** the user can satisfy a server access gate but does not thereby satisfy a workstation access gate or gain `wheel`

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

### Requirement: The identity service offers each administrator application once

The central identity service's application list SHALL offer each administrator application exactly once, under the application's declared name, and each entry SHALL lead to that application. The list SHALL NOT offer an entry that leads to no application of its own. The identity service SHALL offer administrator applications only to members of the central administrator group.

#### Scenario: An administrator views the application list
- **WHEN** a member of the central administrator group views the applications the identity service offers
- **THEN** each administrator application appears once under its declared name, and opening it leads to that application

#### Scenario: An application signs users in behind an authenticated entrance
- **WHEN** an administrator application has its own central sign-in and also sits behind an entrance that requires central sign-in
- **THEN** the identity service still offers that application once

#### Scenario: A non-administrator views the application list
- **WHEN** an identity outside the central administrator group views the applications the identity service offers
- **THEN** no administrator application is offered

### Requirement: Sign-in to one administrator application does not grant another

A sign-in issued for one administrator application SHALL NOT authenticate a request to a different administrator application.

#### Scenario: A sign-in for one application reaches another
- **WHEN** a request to one administrator application presents a sign-in issued for a different administrator application
- **THEN** the request is not authenticated

### Requirement: The declaration owns every application registration in the identity service

Every application registration in the central identity service SHALL come from the declaration. Provisioning SHALL remove each registration the declaration does not contain before it grants administrator-group membership. Removing a registration SHALL NOT remove people, their credentials, or group membership other than grants on that registration.

#### Scenario: An application registration is no longer declared
- **WHEN** provisioning runs and the identity service holds an application registration that the declaration does not contain
- **THEN** provisioning removes that registration before it grants administrator-group membership

#### Scenario: Removal fails
- **WHEN** provisioning cannot remove an undeclared registration
- **THEN** provisioning fails and grants no administrator-group membership
