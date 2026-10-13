## ADDED Requirements

### Requirement: Household media sign-in uses the central identity service

The household media server SHALL accept a central identity account's sign-in only when the account belongs to the household group or the central administrator group. Each sign-in SHALL check that membership again. The media server SHALL refuse any other central identity account and SHALL NOT create a media-server account for it.

#### Scenario: A household member signs in
- **WHEN** a member of the household group signs in to the media server with their central identity credential
- **THEN** the media server accepts the sign-in, and later sign-ins reach the same media-server account

#### Scenario: An identity outside both groups signs in
- **WHEN** a central identity account that belongs to neither group signs in to the media server
- **THEN** the media server refuses it and creates no account for it

#### Scenario: A member leaves the household group
- **WHEN** an operator removes a person from the household group
- **THEN** that person's next sign-in to the media server is refused

### Requirement: Media administration follows the central administrator group

A person who signs in to the media server through the central identity service SHALL hold media-server administration exactly when they belong to the central administrator group at that sign-in.

#### Scenario: An administrator signs in
- **WHEN** a member of the central administrator group signs in to the media server through the central identity service
- **THEN** the media server grants that account administration

#### Scenario: An administrator leaves the administrator group
- **WHEN** a person leaves the central administrator group but remains in the household group
- **THEN** their next media-server sign-in succeeds without administration

### Requirement: Administrator credential strength is declared

The declaration SHALL state the minimum credential strength for the central administrator group, and that minimum SHALL require multi-factor authentication or stronger. It SHALL NOT depend on the identity service's built-in defaults. A directory sign-in by an administrator SHALL NOT accept the credential the administrator uses for web sign-in; it SHALL require a separate directory password that the administrator sets. Setting that password SHALL NOT weaken the administrator's web sign-in.

#### Scenario: An administrator enrolls a password-only credential
- **WHEN** a member of the central administrator group tries to enroll a credential without a second factor
- **THEN** the identity service refuses it

#### Scenario: An administrator uses their web password for the directory
- **WHEN** an administrator presents their web sign-in password to the directory
- **THEN** the directory refuses the sign-in

#### Scenario: An administrator sets a directory password
- **WHEN** an administrator sets a separate directory password
- **THEN** that password signs them in through the directory, it does not sign them in to the identity service's web sign-in, and their multi-factor web sign-in still works

### Requirement: Household members may use one password

A member of the household group who is not an administrator SHALL be able to hold a password-only central identity credential. That one password SHALL sign them in to the identity service and, through the directory, to the media server, unless they set a separate directory password.

#### Scenario: A password-only household member
- **WHEN** a household member with only a password signs in to the identity service and to the media server
- **THEN** both sign-ins accept the same password

#### Scenario: An empty or wrong password
- **WHEN** someone presents an empty or wrong password for a household member
- **THEN** the directory and the media server refuse the sign-in

### Requirement: The directory is read-only and reachable only by declared consumers

The central identity service's directory interface SHALL be read-only and SHALL accept only TLS-protected connections. Network policy SHALL admit only declared directory consumers to it. The media server SHALL verify the directory's server certificate.

#### Scenario: An undeclared workload connects to the directory
- **WHEN** a workload that is not a declared directory consumer opens a connection to the directory port
- **THEN** network policy refuses the connection

#### Scenario: The media server connects to the directory
- **WHEN** the media server checks a sign-in against the directory
- **THEN** it connects over TLS and verifies the server certificate

### Requirement: The request application signs household members in through the media server

The household request application SHALL accept the sign-in of a person the media server accepts through the central identity service, with the same credential, and SHALL refuse a person the media server refuses. It SHALL NOT need a credential of its own for them.

#### Scenario: A household member signs in to the request application
- **WHEN** a household member signs in to the request application with their media-server login
- **THEN** the request application accepts the sign-in

#### Scenario: An outsider signs in to the request application
- **WHEN** a central identity account outside both groups signs in to the request application
- **THEN** the request application refuses it

### Requirement: Household group membership is operator-owned

The declaration SHALL create the household group and its account policy. Provisioning SHALL NOT add or remove the group's members.

#### Scenario: Provisioning runs after an operator adds a member
- **WHEN** an operator adds a person to the household group and provisioning runs again
- **THEN** the person is still a member
