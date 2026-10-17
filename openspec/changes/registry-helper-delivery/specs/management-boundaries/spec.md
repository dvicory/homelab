## ADDED Requirements

### Requirement: Routine helper releases are independent of the guest OS generation

A committed release of a Nix-built Kubernetes workload helper SHALL be consumable through ordinary application reconciliation without host activation, guest OS generation changes, guest replacement, or routine manual image import. The release SHALL preserve the deployment domain's control-plane identity and retained application state. This guarantee SHALL NOT transfer application-internal behavior or runtime credential ownership to the artifact publisher.

#### Scenario: A helper implementation changes
- **WHEN** an eligible helper release is selected in desired state
- **THEN** application reconciliation consumes that release without changing or replacing the guest OS generation or requiring an operator to import its image
- **AND** control-plane identity and retained application state remain usable

### Requirement: Helper artifacts become eligible only after immutable publication verification

Desired state SHALL select a helper by its manifest digest and verified target platform. Before selection, the exact artifact SHALL be published and retrievable using the consumer's access boundary, and its identity SHALL match the declared producer output. A mutable tag, an unverified publication receipt, or an artifact for another platform SHALL NOT substitute for that identity. Invalid or unavailable selection SHALL fail visibly rather than silently selecting a different artifact.

#### Scenario: Publication exists but consumers cannot retrieve it
- **WHEN** a publisher can access an artifact but the intended consumer cannot retrieve its declared digest
- **THEN** the artifact is not eligible for selection

#### Scenario: Artifact identity or platform differs
- **WHEN** the artifact retrieved for a proposed release differs from the declared producer output or target platform
- **THEN** selection is refused and no alternative artifact is selected

#### Scenario: The selected artifact is unavailable
- **WHEN** a workload has no verified cached copy and cannot retrieve its selected digest
- **THEN** it fails visibly rather than using a mutable tag or another helper image

### Requirement: Helper publication is trusted and secret-free

Only an explicitly authorized trusted publisher SHALL receive artifact-publication authority. Publication SHALL accept only an exact same-repository merged-main push whose required CI has succeeded. Pull-request and manual sources SHALL NOT receive publication authority. The publisher SHALL verify the permitted source and artifact identity before publishing a candidate; publication alone SHALL NOT authorize production selection. Public helper artifacts, identity records, and publication diagnostics SHALL contain no production credential values or private keys. Runtime credentials SHALL remain in the established secret-delivery flow rather than becoming build or publication inputs.

#### Scenario: Required CI passes for a merged-main release
- **WHEN** all required CI succeeds for an exact same-repository merged-main push
- **THEN** a separate trusted publisher automatically publishes its verified artifact without a per-release approval click
- **AND** producer code runs without publication credentials
- **AND** production selection still requires the existing test, review, and merge gates

#### Scenario: An untrusted source requests publication
- **WHEN** a pull request, manual run, fork, or unauthorized source supplies a candidate artifact
- **THEN** publication is refused without executing its code with publication authority

#### Scenario: A public release is prepared
- **WHEN** the trusted publisher prepares helper artifacts and release inputs
- **THEN** their contents and diagnostics are checked for production credential values and private keys before publication
- **AND** runtime credentials remain outside those artifacts
