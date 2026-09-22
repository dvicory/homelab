## Context

See `proposal.md` for motivation. Den already holds a cluster route inventory consumed by Gateway API rendering and independent edge proxies. Kanidm supplies shared identity. The stable `management-boundaries` capability already owns independent recovery access. Preserve's active `first-class-state-protection` change owns stable State identity, protection policy and Route/Target resolution, lifecycle-owner Integration matching, recovery evidence, and restore authorization. This contract must state service-facing route, trust, bootstrap, and Kanidm state facts without freezing Nix option names, selecting a public-edge provider, or creating a parallel protection model.

## Goals / Non-Goals

**Goals:**

- Keep service routes, public exposure, authentication, TLS trust, and timeout intent coherent across independently reconciled entrances.
- Make proxy trust and first identity bootstrap fail closed.
- Distinguish static configuration proof from live acceptance evidence.

**Non-Goals:**

- Choose DNS, ACME, CDN, tunnel, or public cloud providers.
- Own application startup or configuration reconciliation.
- Define media storage layout, application protection policy, lifecycle-owner wiring, capture scheduling, retention, off-host routing, verification, or restore workflow.
- Duplicate the independent recovery path required by `management-boundaries`.
- Claim live behavior from rendered manifests.

## Decisions

### One route model, multiple consumers

Keep one typed route inventory in Den. Gateway rendering consumes every enabled route. Each independent public entrance consumes only routes whose exposure is public. Hostnames are declared route entrances; only Kanidm's backend identity name is called canonical. This avoids a second hostname or authentication inventory and makes accidental publication structurally detectable.

Alternatives considered: separate ingress inventories are easier for each renderer but drift silently; deriving public exposure from hostnames makes security policy implicit.

### Explicit trust modes

Represent direct internal ingress and trusted-edge ingress as distinct modes. Trusted-edge mode requires an exact peer allowlist. The public edge removes client-supplied forwarding and identity metadata, reconstructs sanitized values from its peer connection, and generates or normalizes the trusted request identifier. The internal gateway accepts forwarded client identity only from configured edge peers and propagates the trusted request identifier; direct mode derives client identity from its own peer connection. Both layers log queryless paths.

For Kanidm, public PKI is a durable contract rather than an implementation preference: its canonical identity hostname is covered by a publicly trusted certificate, and Gateway plus provisioning clients use system roots with strict hostname verification. They receive no private-CA runtime trust input. Certificate issuance remains a separate operational concern; switching to private PKI requires a contract change.

### Two-phase identity bootstrap

Treat initial and normal operation as explicit desired states. Initial state deploys only the retained identity server and TLS input. An operator runs Kanidm's supported `recover-account` flow through a private interactive Kubernetes session. The command necessarily prints the generated credential to that session. The operator immediately escrows or encrypts the resulting credential as appropriate, enrolls durable human authentication, encrypts the normal provisioning credential, and then selects normal state. Normal state enables provisioning and dependent OIDC publication.

Recovery output may be visible only in that private interactive operator session. It must not be persisted in Git, generated documentation, CI or service logs, durable agent transcripts, or ordinary workspace files.

### Kanidm contributes facts to Preserve

The Preserve M1 authority is `first-class-state-protection`. Its StateSlot describes reusable data semantics; State gives the concrete logical resource stable identity; Realization identifies the one authoritative live capability boundary; access projections expose the same boundary to runtimes; ProtectionPolicy, Route, Target, lifecycle-owner Integration, recovery evidence, and restore authorization remain Preserve-owned.

PR #23 contributes facts for that later model without importing or modifying Preserve implementation: the retained `identity-kanidm` boundary, its stable host/guest/pod locations, and discovery that Kanidm provides a native online-backup/export facility. A future application-native Integration must establish the facility's exact invocation, consistency, fidelity, quiescence, version, native point, and restore constraints before it can satisfy a Route. Preserve M1 deliberately leaves application-native/database States for its later M5 milestone, so this change records future integration input rather than instantiating Preserve objects or implementing an adapter.

PR #23 configures no Kanidm backup cadence or retention. The Preserve workstream owns protection intent, policy, Routes, Targets, lifecycle-owner wiring, capture scheduling through the selected owner, retention, off-host routing, verification, and recovery workflow. No PR #23 object may claim that retained Kanidm state is protected merely because the state boundary or native capability is known.

### Evidence is layered

Evaluation checks cover schemas, rendered resources, RBAC shape, route filtering, trust policy, lifecycle gating, image identity, generated documentation, and non-overlapping declared/generated desired-state ownership. Deployment acceptance separately exercises DNS, certificates, public and private paths, spoofed headers, request-ID propagation, queryless logs, long requests, authentication, and unrelated-application failure isolation. Independent substrate recovery remains governed by `management-boundaries`; this change does not restate that requirement.

## Risks / Trade-offs

- A declarative public classification can still be paired with incorrect external DNS or firewall state; live acceptance must detect that mismatch.
- Kubernetes RBAC cannot restrict Secret `create` by name. The normal-phase publisher therefore receives namespace-wide create plus name-scoped patch and no read, list, watch, update, or delete permission.
- Public PKI removes private trust distribution but couples Kanidm availability to a valid publicly trusted certificate. Issuance and renewal need separate operational ownership.
- The two-phase transition is intentionally manual. It confines generated recovery credentials to a private interactive session but requires immediate escrow/encryption and an explicit state change.
- Kanidm's native online-backup/export capability is discovery evidence, not a protection claim. Preserve must validate its semantic guarantees and owner lifecycle before selecting it for a Route.
