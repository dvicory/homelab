## ADDED Requirements

### Requirement: Explicit capability request tool

Hermes MUST expose a Nix-managed `sandbox_request_access` plugin tool that accepts a batch of typed capability proposals, requested scope, optional bounded duration, and model rationale. Ordinary terminal or network denial MUST NOT automatically invoke an approval UI.

#### Scenario: Agent learns missing permission
- **GIVEN** a tool result containing a requestable structured denial
- **WHEN** the agent determines the operation is necessary
- **THEN** it MAY combine that capability with other anticipated needs in one `sandbox_request_access` call

#### Scenario: No implicit prompt
- **GIVEN** a denied request that includes a suggested capability
- **WHEN** the agent does not call `sandbox_request_access`
- **THEN** Hermes MUST NOT show an approval prompt or activate authority

### Requirement: Canonical broker preparation before approval

The plugin MUST send the proposed batch to the broker for validation and canonical preparation before requesting user approval. Approval security facts MUST be rendered from the broker response, not from model rationale. The decision MUST reference an opaque broker request ID rather than resubmitting model-controlled capability data.

#### Scenario: Canonical policy diff
- **GIVEN** a valid prepared request
- **WHEN** Hermes asks the user for approval
- **THEN** the prompt SHALL show exact normalized origins, ports, address mode, private pins when applicable, scope, expiry, credentials, filesystem effects, and VM recreation effects
- **AND** model rationale SHALL be visibly separate and non-authoritative

#### Scenario: Preparation failure
- **GIVEN** an invalid, unsupported, or structurally unsafe capability proposal
- **WHEN** the plugin asks the broker to prepare it
- **THEN** the tool SHALL return the broker's stable denial to the agent
- **AND** MUST NOT invoke user approval

### Requirement: Existing Hermes approval integration

The plugin SHOULD reuse Hermes' existing paired-user and surface-specific approval mechanism. A denial, timeout, callback failure, or malformed response MUST fail closed. Approval choices MUST map only to broker-supported scopes.

#### Scenario: Approved task grant
- **GIVEN** a canonical request whose requested task scope is permitted
- **WHEN** the paired user approves
- **THEN** the plugin SHALL submit an approved decision for the request ID
- **AND** return active grant identifiers and retry guidance to the agent

#### Scenario: Approval timeout
- **WHEN** the Hermes approval callback times out or raises an error
- **THEN** the plugin MUST record or submit a denied decision
- **AND** no capability may become active

#### Scenario: Persistent approval choice
- **GIVEN** the user selects an existing `always` choice
- **WHEN** immutable policy permits the exact capability to be remembered for the profile or executor
- **THEN** the prompt MUST state that a durable local rule will be created
- **AND** the broker SHALL store it as a listable and revocable exact rule

### Requirement: Approval-fatigue controls

The broker MUST enforce persistent request coalescing, denial cooldowns, one pending request per environment, and bounded prompt budgets. The plugin MUST honor suppressed and existing-pending responses without opening another prompt.

#### Scenario: Duplicate pending request
- **GIVEN** an equivalent canonical request already pending
- **WHEN** the agent submits it again
- **THEN** the broker SHALL return the existing request ID
- **AND** Hermes MUST NOT open a second approval prompt

#### Scenario: Repeated denied request
- **GIVEN** a request fingerprint denied within its cooldown
- **WHEN** the agent resubmits the same authority
- **THEN** the broker SHALL return `approval.request_suppressed` with cooldown metadata
- **AND** no prompt SHALL be shown

#### Scenario: Prompt budget exhausted
- **GIVEN** a task has reached its configured new-request budget
- **WHEN** it proposes another non-remembered capability
- **THEN** the broker MUST suppress the request until the rolling window resets or the user changes policy out of band

### Requirement: Batch and remembered-rule behavior

Capability batches MUST be normalized and deduplicated before fingerprinting. Initial Hermes approval is all-or-nothing for one batch. The user MUST be able to list and revoke active grants and remembered rules without a Nix rebuild.

#### Scenario: Duplicate entries in a batch
- **WHEN** a model submits semantically identical origin capabilities more than once
- **THEN** the broker SHALL present and store one canonical capability

#### Scenario: User wants a subset
- **GIVEN** a batch containing an unwanted capability
- **WHEN** the user denies the batch
- **THEN** no entry in that batch may activate
- **AND** the agent MAY submit a smaller non-suppressed batch after the cooldown rules permit it

#### Scenario: Revoke remembered access
- **GIVEN** a profile-scoped remembered origin rule
- **WHEN** the user invokes the plugin's list/revoke operation for that rule
- **THEN** future matching tasks MUST no longer auto-activate it
- **AND** active grants derived from it MUST be revoked according to the selected revocation scope

### Requirement: Minimal Hermes patch surface

Hermes core changes MUST be generic to trusted task environment authority and MUST NOT contain Gondolin policy, network bundle, credential, or approval-scope semantics. Policy and grant behavior SHALL live in the plugin and broker.

#### Scenario: Environment-backed tool coverage
- **GIVEN** a task authority binding registered through the generic hook
- **WHEN** terminal, file, patch, search, execute-code, background/process, status, or cleanup resolves the task environment
- **THEN** every surface SHALL use the same canonical authority-bearing environment key without separate tool-specific patches

## Mechanism

- A Nix-built Hermes plugin registers `sandbox_request_access`, `sandbox_access_list`, and `sandbox_access_revoke` tools and the relevant session/Kanban lifecycle hooks.
- The plugin uses the broker control client and imports only the generic Hermes task-environment authority registration API.
- Hermes' existing approval provider remains responsible for CLI, gateway, Telegram, and other paired-user interaction. The plugin passes canonical broker summaries and interprets approved/denied scope choices.
- Broker `access_requests` rows implement request IDs, fingerprints, state, pending uniqueness, cooldown, and rolling budget accounting across gateway restarts.
- Nix options define default cooldown, prompt budget, allowed scopes, duration ceiling, and whether durable profile/executor rules are available for `hermes-qa`.
