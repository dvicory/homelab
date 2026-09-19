## ADDED Requirements

### Requirement: Durable workload state does not depend on disposable compute state

Durable workload state SHALL remain recoverable without restoring a lost compute instance root, Kubernetes datastore, container-image cache, or prior Kubernetes object identities. Recovery procedures SHALL identify durable host-owned data separately from disposable control-plane state.

#### Scenario: Compute and cluster state are lost

- **WHEN** the instance root, Kubernetes datastore, and container cache are absent while declared durable storage, configuration, secrets, and artifact sources remain available
- **THEN** recovery reconstructs the compute domain and workload without restoring those disposable components

#### Scenario: Durable storage is reattached

- **WHEN** replacement compute reattaches declared retained storage
- **THEN** the workload uses the existing application state with its declared identity and does not initialize substitute state
