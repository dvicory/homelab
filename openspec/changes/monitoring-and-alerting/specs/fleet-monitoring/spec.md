## Purpose

Define which fleet failures must be detected and how quickly, how alerts reach the fleet owner, how the loss of monitoring itself is detected from outside the fleet, and the access, secret, failure-domain and lifecycle boundaries monitoring must respect.

## ADDED Requirements

### Requirement: Workload failures produce alerts

The fleet SHALL alert when a cluster workload container is killed for exceeding its memory limit, or restarts for any other reason, within 5 minutes of the event. It SHALL alert when a workload pod stays not ready, or keeps restarting in a crash loop, for 15 minutes, and SHALL do so within 20 minutes of onset. It SHALL alert within 15 minutes after a Job fails. An application's reported GitOps health SHALL NOT suppress these alerts.

#### Scenario: A container is killed at its memory limit
- **WHEN** a workload container is terminated because it exceeded its memory limit and Kubernetes restarts it
- **THEN** an alert naming the workload, its namespace and the out-of-memory reason is delivered within 5 minutes, even if the GitOps control plane reports the application as Healthy

#### Scenario: A pod crash-loops
- **WHEN** a workload pod keeps restarting and never becomes ready for 15 minutes
- **THEN** an alert naming the pod is delivered within 20 minutes of the first failure

#### Scenario: A Job fails
- **WHEN** a Job reaches a failed state
- **THEN** an alert naming the Job is delivered within 15 minutes

### Requirement: GitOps deviations produce alerts

The fleet SHALL alert within 20 minutes of onset when a GitOps Application has been degraded, or unable to compare against its declared source, for 15 minutes. It SHALL alert within 40 minutes of onset when an Application has been out of sync with its declared source for 30 minutes.

#### Scenario: An Application stays degraded
- **WHEN** a GitOps Application reports degraded health for 15 minutes
- **THEN** an alert naming the Application is delivered within 20 minutes of onset

#### Scenario: An Application cannot converge
- **WHEN** a GitOps Application remains out of sync for 30 minutes despite automated reconciliation
- **THEN** an alert naming the Application is delivered within 40 minutes of onset

#### Scenario: A sync completes normally
- **WHEN** an Application is briefly out of sync during a routine sync that converges within 30 minutes
- **THEN** no alert is delivered

### Requirement: Host storage faults produce alerts

The fleet SHALL alert within 10 minutes when a host storage pool is not fully healthy, when a pool device reports read, write or checksum errors, or when a required media pool or encrypted media mount is absent. It SHALL alert within 1 hour after a pool scrub completes with errors, and within 1 hour when a monitored disk reports a failing or degraded health assessment. It SHALL alert within 1 hour when a monitored filesystem stays below its declared free-space threshold.

#### Scenario: A pool degrades
- **WHEN** a host storage pool leaves its fully healthy state
- **THEN** an alert naming the pool and its state is delivered within 10 minutes

#### Scenario: The media pool is not mounted
- **WHEN** the host's media pool or one of its required encrypted media mounts is absent
- **THEN** an alert naming the missing mount is delivered within 10 minutes

#### Scenario: A disk reports failing health
- **WHEN** a monitored disk's health self-assessment reports failure or a degraded condition
- **THEN** an alert naming the disk is delivered within 1 hour

#### Scenario: A filesystem runs low on space
- **WHEN** a monitored filesystem stays below its declared free-space threshold
- **THEN** an alert naming the filesystem is delivered within 1 hour

### Requirement: Failed host services produce alerts

The fleet SHALL alert when a host systemd unit has stayed in a failed state for 10 minutes, within 15 minutes of the failure.

#### Scenario: A host unit fails
- **WHEN** a systemd unit on a monitored host enters the failed state and stays there for 10 minutes
- **THEN** an alert naming the host and unit is delivered within 15 minutes of the failure

### Requirement: Unreachable service endpoints produce alerts

The fleet SHALL probe the declared administrator and household service endpoints, including the media server, the central identity service and the GitOps control plane, through the same entrance that serves them. It SHALL alert within 10 minutes of onset when an endpoint has failed its probe continuously for 5 minutes. A redirect to central sign-in SHALL count as a successful answer from an endpoint protected by entrance authentication.

#### Scenario: The media server stops answering
- **WHEN** the media server endpoint fails every probe for 5 minutes
- **THEN** an alert naming the endpoint is delivered within 10 minutes of onset

#### Scenario: A protected endpoint redirects to sign-in
- **WHEN** a probe of an administrator endpoint receives the entrance's redirect to central sign-in
- **THEN** the endpoint is counted as answering

### Requirement: Expiring certificates produce alerts

The fleet SHALL alert while at least 14 days of validity remain on any TLS certificate that an entrance serves or that the cluster manages for an entrance. It SHALL also alert when the cluster has reported a managed entrance certificate as not ready for 1 hour.

#### Scenario: Renewal is stuck
- **WHEN** a served or managed entrance certificate approaches expiry without being renewed
- **THEN** an alert naming the certificate and its expiry is delivered while at least 14 days of validity remain

#### Scenario: A managed certificate is not ready
- **WHEN** the cluster reports a managed entrance certificate as not ready for 1 hour
- **THEN** an alert naming the certificate is delivered

### Requirement: Missing telemetry is a fault

The fleet SHALL alert within 15 minutes when a declared telemetry source stops reporting. Missing data SHALL NOT be treated as healthy. An alert about a missing source SHALL identify that source, distinct from the condition the source would have reported.

#### Scenario: A host exporter stops
- **WHEN** a declared host telemetry source stops answering collection
- **THEN** an alert naming that source is delivered within 15 minutes, and its storage alerts are not treated as resolved

### Requirement: Loss of monitoring alerts from outside the fleet

Monitoring SHALL continuously emit a heartbeat that leaves the fleet only when alert evaluation and delivery work end to end. A service outside the fleet SHALL notify the fleet owner through both delivery channels within 30 minutes after heartbeats stop arriving, whatever the cause, including loss of the compute guest, the host, power or network connectivity. A notification channel that only relays messages it receives SHALL NOT be counted as this external watchdog.

#### Scenario: The whole host goes down
- **WHEN** the host running the compute guest loses power
- **THEN** the external watchdog notifies the fleet owner within 30 minutes

#### Scenario: Alert evaluation stops while the cluster runs
- **WHEN** applications keep running but alert evaluation or alert routing stops
- **THEN** heartbeats stop and the external watchdog notifies the fleet owner within 30 minutes

#### Scenario: Heartbeats resume
- **WHEN** heartbeats arrive again after an outage
- **THEN** the external watchdog reports the recovery

### Requirement: Alerts reach the fleet owner through two independent channels

Alerts SHALL be delivered to the fleet owner. Every alert SHALL carry a severity. A critical alert SHALL be delivered through two independent third-party delivery channels. A lower-severity alert SHALL be delivered through at least one of them. Delivery SHALL report both firing and resolution. When delivery through one channel fails, an alert about that failure SHALL be delivered through the other channel.

#### Scenario: A critical alert fires
- **WHEN** a critical alert fires
- **THEN** the fleet owner receives it through both delivery channels, and receives a resolution notice when it clears

#### Scenario: One channel's credential is revoked
- **WHEN** notifications through one delivery channel fail
- **THEN** the fleet owner receives an alert about the failed channel through the other channel

### Requirement: Alert notifications contain no secrets

Alert notifications, heartbeats and their delivery logs SHALL NOT contain secret values. That includes delivery credentials, the watchdog heartbeat address, runtime-secret contents, and application credentials. Notifications MAY contain object names, hosts, namespaces, severities, measured values and links to administrator interfaces.

#### Scenario: An alert concerns a Secret-backed workload
- **WHEN** an alert fires for a workload that consumes runtime Secrets
- **THEN** the notification identifies the workload without including any Secret value

### Requirement: Alert delivery credentials are managed secrets

Delivery-channel credentials and the watchdog heartbeat address SHALL be managed secrets. They SHALL be stored encrypted in source control, materialized only for the component that delivers alerts, and absent from evaluated configuration, generated manifests, generated documentation and dashboards. Without a credential, delivery through that channel SHALL fail visibly. A placeholder or plaintext substitute SHALL NOT be used instead.

#### Scenario: Manifests are generated
- **WHEN** monitoring manifests and documentation are generated from the declaration
- **THEN** they reference the delivery credentials and heartbeat address without containing their values

#### Scenario: A delivery credential is missing
- **WHEN** a declared delivery credential has not been provisioned
- **THEN** that channel's delivery fails visibly and the missing heartbeat or delivery failure is reported, rather than silently delivering nowhere

### Requirement: Host telemetry crosses only the private host–guest link

Host telemetry sources SHALL be reachable only from the compute guest over the private host–guest network. They SHALL NOT be reachable from the household LAN, the tailnet or the internet. Exposing host telemetry SHALL grant the guest read-only telemetry access and no other new access to the host.

#### Scenario: A LAN client requests host metrics
- **WHEN** a client on the household LAN or tailnet connects to a host telemetry port
- **THEN** the connection is refused or dropped

#### Scenario: The in-cluster collector scrapes the host
- **WHEN** the collector running in the compute guest requests host telemetry over the private host–guest network
- **THEN** it receives the telemetry and gains no ability to change host state

### Requirement: Monitoring does not gate the platform

No other Application, deployment wave, identity phase transition, bootstrap step or compute-guest replacement step SHALL wait on monitoring health or depend on monitoring components. When monitoring is absent, degraded or failing to sync, GitOps reconciliation of every other Application, the identity rollout, and application workloads SHALL continue unchanged. A host telemetry source failing SHALL NOT fail host activation or stop other host services.

#### Scenario: The monitoring Application is degraded
- **WHEN** a monitoring Application is degraded or cannot sync
- **THEN** every other Application continues to sync in its declared order, and no later wave waits on monitoring

#### Scenario: A host exporter fails to start
- **WHEN** a host telemetry service fails during host activation
- **THEN** activation completes, other host services keep running, and the missing source raises an alert once collection notices it

### Requirement: Monitoring resource use is bounded

Monitoring components SHALL declare bounded compute, memory and storage consumption, so that monitoring growth cannot exhaust resources other workloads need. Metrics history SHALL have a declared retention bound and SHALL stop growing before it exhausts the storage that holds it.

#### Scenario: Metrics volume grows
- **WHEN** collected metrics grow beyond expectations
- **THEN** monitoring components hit their own declared limits, and other workloads keep their resources

### Requirement: Metrics history survives compute-guest replacement

Bounded metrics history SHALL live on host-retained storage and SHALL remain queryable after the compute guest is replaced while that storage survives. Dashboards, data sources and alert rules SHALL be recreated from the declaration. Dashboard database state and alert-routing runtime state, including silences, are disposable and need not survive. This requirement SHALL NOT be read as a backup or off-host durability guarantee for metrics history.

#### Scenario: The compute guest is replaced
- **WHEN** the compute guest is destroyed and rebuilt while host-retained storage survives
- **THEN** metrics recorded before the replacement remain queryable, and the declared dashboards and alert rules return without manual restoration

#### Scenario: A dashboard is edited in the user interface
- **WHEN** an administrator changes a declared dashboard through the dashboard user interface
- **THEN** the change is refused or discarded at the next redeployment, and the declaration remains the source of dashboards
