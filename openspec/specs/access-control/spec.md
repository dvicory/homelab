# access-control Specification

## Purpose
Define how fleet identities gain machine access and system privileges while keeping login eligibility, transitive group membership, and administrative authority coherent and separate.

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
