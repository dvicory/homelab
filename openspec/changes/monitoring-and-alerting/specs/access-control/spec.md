## ADDED Requirements

### Requirement: Monitoring dashboards require central administrator sign-in

Monitoring dashboards SHALL grant access only to an identity that signs in to them through the central identity service and belongs to the central administrator group. Dashboards SHALL NOT grant access to anonymous requests, to local password sign-in, or to an identity outside the administrator group, even one the central identity service knows. Authentication at an entrance in front of the dashboards SHALL NOT by itself grant dashboard access.

#### Scenario: An administrator opens the dashboards
- **WHEN** a member of the central administrator group signs in to the dashboards through the central identity service
- **THEN** the dashboards grant that identity access

#### Scenario: A non-administrator signs in
- **WHEN** an identity known to the central identity service but outside the administrator group attempts to sign in to the dashboards
- **THEN** the identity service refuses the sign-in or the dashboards grant no access

#### Scenario: An anonymous or local sign-in is attempted
- **WHEN** a request reaches the dashboards without central sign-in, or attempts local password sign-in
- **THEN** the dashboards grant no access

#### Scenario: Only the entrance authenticated the request
- **WHEN** a request passes entrance-level administrator sign-in but carries no dashboard sign-in
- **THEN** the dashboards grant no access on the strength of the entrance sign-in

### Requirement: Every entrance to the monitoring dashboards requires administrator sign-in first

Every entrance that serves the monitoring dashboards, including an entrance reachable from the internet, SHALL require central sign-in by a member of the central administrator group before it forwards any request to the dashboards. Requests that lack that sign-in SHALL NOT reach the dashboards. Serving the dashboards from the internet SHALL NOT relax any requirement on the dashboards' own sign-in, and SHALL NOT make any other monitoring endpoint reachable.

#### Scenario: An internet client without sign-in requests the dashboards
- **WHEN** a client on the internet requests the dashboards' hostname without central sign-in
- **THEN** the entrance redirects the client to central sign-in, and no part of the request reaches the dashboards

#### Scenario: A non-administrator signs in at the entrance
- **WHEN** an identity outside the central administrator group attempts entrance sign-in for the dashboards
- **THEN** the identity service or the entrance refuses it, and no request from that identity reaches the dashboards

#### Scenario: An administrator reaches the dashboards from anywhere
- **WHEN** a member of the central administrator group, outside the household network, completes entrance sign-in and then dashboard sign-in
- **THEN** the dashboards grant that identity access, and the identity service offers the dashboards once

### Requirement: Monitoring endpoints other than dashboards are not exposed

Metrics storage, metrics query, alert evaluation, alert routing and telemetry exporter endpoints SHALL NOT be published through any entrance, whether it serves the household network, the tailnet or the internet. Only the dashboards' administrator route MAY expose monitoring data outside the cluster, and that route SHALL forward only to the dashboards. Within the cluster, the endpoints of components deployed for monitoring SHALL accept connections only from other monitoring components, plus, for the dashboards, the entrance that serves their administrator route. This requirement does not change how existing applications restrict their own metrics endpoints.

#### Scenario: A client requests a raw monitoring endpoint through an entrance
- **WHEN** a client asks any entrance, including one reachable from the internet, for the metrics query, alert-routing or exporter endpoint
- **THEN** no route serves the request

#### Scenario: An unrelated workload connects to the metrics store
- **WHEN** a workload that is not part of monitoring connects to a monitoring endpoint inside the cluster
- **THEN** the connection is refused or dropped
