## Context

See `proposal.md` for motivation. Den already holds a cluster route inventory consumed by Gateway API rendering and independent edge proxies. Kanidm supplies shared identity. The stable `management-boundaries` capability already owns independent recovery access. Preserve's active `first-class-state-protection` change owns stable State identity, protection policy and Route/Target resolution, lifecycle-owner Integration matching, recovery evidence, and restore authorization. This contract must state service-facing route, trust, bootstrap, and Kanidm state facts without freezing Nix option names, selecting a public-edge provider, or creating a parallel protection model.

## Goals / Non-Goals

**Goals:**

- Keep service routes, public exposure, authentication, TLS trust, and timeout intent coherent across independently reconciled entrances.
- Make proxy trust and first identity bootstrap fail closed.
- Make desired-state ownership and convergence observable before deployment.
- Distinguish static configuration proof from live acceptance evidence.

**Non-Goals:**

- Choose DNS, ACME, CDN, tunnel, or public cloud providers.
- Own application startup or configuration reconciliation.
- Define media storage layout, Preserve-owned application protection policy, lifecycle-owner wiring, capture scheduling, retention, off-host routing, verification, or restore workflow; Kanidm's retained boundary and native export capability remain application facts rather than protection policy.
- Duplicate the independent recovery path required by `management-boundaries`.
- Claim live behavior from rendered manifests.

## Decisions

### One route model, consumer-owned hostname policy

Keep one typed route inventory in Den. A route is present when it is declared; no separate boolean presence flag is part of this contract. Gateway rendering consumes each declared route, while each independent public entrance consumes only declared routes whose exposure is public. Every route has one or more declared hostnames plus its backend service, authentication mode, exposure, backend TLS/trust declaration, and timeout policy.

The shared inventory deliberately does not prescribe hostname count, order, or domain families. A public-edge consumer declares and validates those constraints itself before emitting configuration; the current two-family edge may therefore require its own primary/backup shape without making that shape a universal route rule. Kanidm is the exception to generic naming: its canonical identity hostname is the first (primary) hostname in its identity route.

### Explicit trust modes and request identity

Represent direct internal ingress and trusted-edge ingress as distinct modes. Trusted-edge mode requires an exact peer allowlist. The public edge removes client-supplied forwarding, end-user identity, and request-ID metadata, reconstructs trusted client-address metadata from its peer connection, and generates a fresh trusted request identifier. The internal gateway accepts forwarded client-address metadata only from configured edge peers and preserves that request identifier unchanged; direct mode derives the client address from its own peer connection. Both layers log queryless paths. Live acceptance must observe the same non-empty identifier in the edge and gateway logs for one request.

Generic backend TLS requires hostname and certificate-chain verification against system roots. Kanidm's canonical identity hostname is the first identity-route hostname and remains the issuer, SNI, and certificate identity through both direct and secondary-edge entrances. Failover changes DNS routing, not identity. Gateway and provisioning clients receive no private-CA runtime trust input. Certificate issuance remains a separate operational concern; switching Kanidm to private PKI requires a contract change.

### Identity lifecycle and private bootstrap

Treat initial, provisioning, and normal operation as explicit desired states. Initial deploys only the retained identity service and TLS input. Provisioning adds the encrypted `idm_admin` credential, cross-namespace publication RBAC within the identity Application, and an idempotent PostSync provisioning Job that creates named administrators with no administrator-group membership while every administrator route remains absent. Normal grants that membership and publishes each administrator route in the same Argo Application as its SecurityPolicy, with the policy ordered before the route.

An operator runs Kanidm's supported `recover-account` flow through a private interactive Kubernetes session. The command prints the generated credential only to that session. The operator immediately escrows or encrypts it, selects provisioning so the named people are created, then enrolls durable human authentication and verifies private native login. Only then may the operator select normal.

Recovery output may be visible only in that private interactive operator session. It must not be persisted in Git, generated documentation, CI or service logs, durable agent transcripts, or ordinary workspace files. Generated operations guidance must state these handling rules.

### Immutable Gateway identity and ordered convergence

The Gateway controller and data-plane use the exact immutable multi-architecture image references required by the contract:

- `docker.io/envoyproxy/gateway:v1.9.1@sha256:0049bcb384c591c6a6dd043fe5c9929ef6e74f230e12dd678d2d3701df9b301e`
- `docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4`

Argo Applications follow real prerequisites: retained state precedes workloads, Gateway CRDs precede the controller, the controller precedes Gateway resources, cross-namespace RBAC precedes the provisioning Job, and administrator SecurityPolicies precede their routes within one normal-only Application. A parent Application reports readiness only after each child Application reports its actual healthy status; a sync-wave annotation alone is not readiness evidence.

### Declared desired-state ownership

Desired-state ownership is a declaration, not a live-cluster observation. For every generated object identity `(apiGroup, kind, namespace, name)` and every generated source directory, exactly one declared Argo Application owns it. Renderers must reject duplicate claims and must not silently let a second Application or source directory emit the same object. Live owner references, labels, or field managers can be inspected as deployment evidence but do not replace the declared ownership map.

### Kanidm contributes facts to Preserve

The Preserve M1 authority is `first-class-state-protection`. Its StateSlot describes reusable data semantics; State gives the concrete logical resource stable identity; Realization identifies the one authoritative live capability boundary; access projections expose the same boundary to runtimes; ProtectionPolicy, Route, Target, lifecycle-owner Integration, recovery evidence, and restore authorization remain Preserve-owned.

This change contributes only the retained `identity-kanidm` boundary, its stable host/guest/pod locations, and the fact that Kanidm provides a native export capability. A future application-native Integration must establish the facility's exact invocation, output location, cadence, consistency, fidelity, quiescence, version, native point, and restore constraints before selecting it.

This change creates no capture schedule, retention, Route, Target, adapter, verification, or restore workflow. A known retained boundary or native capability is not protection evidence.

### Layered evidence

Evaluation checks cover route declarations and filtering, trust policy, lifecycle gating, exact image identity, Argo ordering and child health declarations, bootstrap guidance, generated resources, and unique declared Application/object/source ownership. Deployment acceptance separately exercises DNS, certificates, public and private paths, spoofed headers, two-layer request-ID propagation, queryless logs, long requests, authentication, and unrelated-application failure isolation. Independent substrate recovery remains governed by `management-boundaries`; this change does not restate that requirement.

## Risks / Trade-offs

- A declarative public classification can still be paired with incorrect external DNS or firewall state; live acceptance must detect that mismatch.
- Public-edge hostname cardinality is intentionally consumer-owned, so every edge must validate its own required shape before publishing.
- Kubernetes RBAC cannot restrict Secret `create` by name. The provisioning publisher therefore receives namespace-wide create plus name-scoped patch and no read, list, watch, update, or delete permission.
- Public PKI removes private trust distribution but couples Kanidm availability to a valid publicly trusted certificate. Issuance and renewal need separate operational ownership.
- The three-phase transition is intentionally manual. It confines generated recovery credentials to a private interactive session and keeps administrator exposure absent until provisioning succeeds.
- Kanidm's native export capability is discovery evidence, not a protection claim. Preserve must validate its semantic guarantees and owner lifecycle before selecting it.
