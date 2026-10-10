## ADDED Requirements

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
