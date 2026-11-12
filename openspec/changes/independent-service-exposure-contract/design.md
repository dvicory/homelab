## Context

See `proposal.md` for motivation. Today's Gateway serves public and private routes on one entry; optional NGINX roles perform public filtering and a second TLS termination. PR #122 supplies resolved service-owned route metadata shared by renderers and documentation. PRs #106 and #115 contain independent hardening, fixture corrections and release updates, not the selected public/private Gateway split. Reuse those outputs rather than creating another registry or repeating their work. The existing identity lifecycle, independent recovery and Preserve ownership boundaries remain unchanged.

## Goals / Non-Goals

**Goals:**

- Put public/private route separation and all HTTP policy at the Gateway.
- Preserve direct private access while a remote TCP entrance is absent or unavailable.
- Retain bootstrap safety and administrator authorization without adding application phases.
- Prove the selected path in disposable networks before a public box exists.

**Non-Goals:**

- Select DNS, ACME, CDN or hosting providers, or allocate production addresses.
- Own application startup or configuration reconciliation.
- Define media storage layout, Preserve-owned application protection policy, lifecycle-owner wiring, capture scheduling, retention, off-host routing, verification, or restore workflow; Kanidm's retained boundary and native export capability remain application facts rather than protection policy.
- Duplicate the independent recovery path required by `management-boundaries`.
- Claim live behavior from rendered manifests.
- Change the service-by-service exposure list, add a generic access-provider framework, or implement automatic home failover.

## Decisions

### One resolved route model, separate gateway entries

Use PR #122's `flake.clusterRoutes.<cluster>.routes` projection and the same records passed to Nixidy. Explicit site declarations select routes; service-owned defaults do not publish them. Keep hostname, authentication and exposure policy in the site declaration and backend defaults beside the service.

Keep the existing `household` Gateway as the private, ordinary-TLS entry. Add a separate public Gateway and data plane for relay traffic. Two Gateways keep client-address policy, receiving ports and network selectors separate; a second listener on today's Gateway would still share Gateway-wide trust and pod admission.

Each eligible HTTPRoute retains one owner and backend declaration. Attach it to the private Gateway; attach it to the public Gateway only when its exposure is public. Apply existing identity and application bootstrap gates before either attachment. The route's administrator SecurityPolicy continues to protect every attachment and remains ordered before the route.

Reuse the declared certificates and name-scoped identity certificate grant at the Gateway. Update Gateway-owned backend policies and the identity/Homarr owners' explicit admission rules for the intended data planes; do not grant access to the whole Gateway namespace.

### TCP transport and client-address trust

The selected transport is a TCP relay with trusted client-address metadata, not source-preserving routing. Use the NixOS HAProxy TCP-mode module to pass application TLS unchanged and prepend PROXY protocol v2. Use the native WireGuard module for an authenticated private link independent of Tailscale; the route model does not depend on either network product. The relay holds no application TLS keys and does not inspect HTTP.

The public Gateway requires transport metadata on its dedicated receiver. Admit only the declared WireGuard peer to that receiver; reject missing or malformed metadata rather than falling back to ordinary direct mode. Keep the private Gateway on ordinary TLS without PROXY metadata. Verify that the selected immutable Envoy release implements these semantics through its supported API, rather than assuming the old trusted-XFF mode is equivalent.

Host forwarding, bridge filtering, the guest firewall and Pod policies must agree on the allowed peer and public receiver. WireGuard peer authentication and source restrictions alone are not a port-access policy. The peer must not reach private Gateway ports, backend Services, Kubernetes API, SSH, Incus or other management endpoints, including through an alternate routed or bridge path.

Envoy is the first HTTP policy owner. It discards client-supplied forwarding, user-identity and request-ID headers, obtains the client address from the direct connection or trusted transport metadata, and generates the request identifier seen by the backend and Gateway log. The encrypted relay cannot generate or sanitize HTTP headers. A compromised relay can forge reported client addresses, so those addresses never grant administrator or application authority.

Transparent source-preserving routing avoids a relay process but adds source-permission and return-routing complexity. It is not the selected implementation. Direct-home public forwarding remains an optional later entrance: it must use the public-only boundary and cannot send ordinary TLS to a receiver that requires PROXY metadata. This cutover preserves direct private home access without adding an unused home-public listener.

### Backend and identity TLS

Generic backend TLS requires hostname and certificate-chain verification against system roots. Kanidm's canonical identity hostname is the first identity-route hostname and remains the issuer, SNI, and certificate identity through both direct and secondary-edge entrances. Failover changes DNS routing, not identity. Gateway and provisioning clients receive no private-CA runtime trust input. Certificate issuance remains a separate operational concern; switching Kanidm to private PKI requires a contract change.

### Identity lifecycle and private bootstrap

Treat initial, provisioning, and normal operation as explicit desired states. Initial deploys only the retained identity service and TLS input. Provisioning adds the encrypted `idm_admin` credential, cross-namespace publication RBAC within the identity Application, and an idempotent PostSync provisioning Job that creates named administrators with no administrator-group membership while every administrator route remains absent. Normal grants that membership and publishes each administrator route in the same Argo Application as its SecurityPolicy, with the policy ordered before the route.

An operator runs Kanidm's supported `recover-account` flow through a private interactive Kubernetes session. The command prints the generated credential only to that session. The operator immediately escrows or encrypts it, selects provisioning so the named people are created, then enrolls durable human authentication and verifies private native login. Only then may the operator select normal.

Recovery output may be visible only in that private interactive operator session. It must not be persisted in Git, generated documentation, CI or service logs, durable agent transcripts, or ordinary workspace files. Generated operations guidance must state these handling rules.

### Immutable Gateway identity and ordered convergence

Keep controller, data-plane and chart selection compatible and immutable. Use the reviewed release selected by the implementation, including separately approved updates from PR #115; do not restore an older version to satisfy this planning document. This cutover does not itself select a package upgrade.

Argo Applications follow real prerequisites: retained state precedes workloads, Gateway CRDs precede the controller, the controller precedes Gateway resources, cross-namespace RBAC precedes the provisioning Job, and administrator SecurityPolicies precede their routes within one normal-only Application. A parent Application reports readiness only after each child Application reports its actual healthy status; a sync-wave annotation alone is not readiness evidence.

### Declared desired-state ownership

Desired-state ownership is a declaration, not a live-cluster observation. For every generated object identity `(apiGroup, kind, namespace, name)` and every generated source directory, exactly one declared Argo Application owns it. Renderers must reject duplicate claims and must not silently let a second Application or source directory emit the same object. Live owner references, labels, or field managers can be inspected as deployment evidence but do not replace the declared ownership map.

### Kanidm contributes facts to Preserve

The Preserve M1 authority is `first-class-state-protection`. Its StateSlot describes reusable data semantics; State gives the concrete logical resource stable identity; Realization identifies the one authoritative live capability boundary; access projections expose the same boundary to runtimes; ProtectionPolicy, Route, Target, lifecycle-owner Integration, recovery evidence, and restore authorization remain Preserve-owned.

This change contributes only the retained `identity-kanidm` boundary, its stable host/guest/pod locations, and the fact that Kanidm provides a native export capability. A future application-native Integration must establish the facility's exact invocation, output location, cadence, consistency, fidelity, quiescence, version, native point, and restore constraints before selecting it.

This change creates no capture schedule, retention, Route, Target, adapter, verification, or restore workflow. A known retained boundary or native capability is not protection evidence.

### Layered evidence

Use evaluation for route attachments, phase gates, SecurityPolicy ordering, metadata policy, peer restrictions and unique ownership. Reuse the existing host-firewall and Kubernetes API fixtures, but replace the legacy NGINX-only path witness with an actual TCP relay, WireGuard link and rendered Envoy Gateway in owned test networks. Fixture keys and certificates are generated for that environment; no dummy production host, provider account or production credential is needed.

The combined proof checks TLS, public/private hostname separation, administrator and native application sign-in, spoofed headers and transport metadata, request identifiers, queryless logs, long requests, peer containment, direct private access after relay/link loss, and isolation during startup and replacement. A green declaration check or the older NGINX fixture is not a substitute.

Deployment acceptance remains a separate gate for the real addresses, link, DNS, certificates and client paths. Independent substrate recovery remains governed by `management-boundaries`.

## Migration Plan

1. Build on the resolved route model from PR #122. Keep public transport unconfigured and the current private path unchanged while implementing and proving the new path in fixtures.
2. Migrate renderers, host/guest networking, backend admission, generated policy checks and runtime fixtures together. Remove the obsolete NGINX roles, trusted-HTTP-edge mode, their options and callers; retain no compatibility aliases or second HTTP-policy owner.
3. Do not change route exposure values as part of that cutover. Review the intended service list separately before commissioning. Keep existing identity/Homarr/Seerr gates; Jellyfin's initContainer already finishes initialization before its runtime starts.
4. Commission only after the disposable proof and the required network-isolation startup/replacement checks pass. Supply real peer addresses and agenix-managed keys then. If the public path fails, close that entry and retain private access; do not fall back to publishing the shared private endpoint.

## Risks / Trade-offs

- A transport peer can forge reported client addresses or stop forwarding. Limit it to the public receiver and keep authorization independent of address metadata.
- Separate data planes add resource use. Keep the split explicit rather than hiding incompatible trust modes on a shared receiver.
- NetworkPolicy has known startup and replacement gaps. Reuse the existing enforcement/recovery work and hold deployment until the required isolation is demonstrated or independently enforced.
- Actual link MTU, bandwidth, DNS and certificate operation need commissioning checks; fixture success cannot establish those facts.
- Direct-home public entry is not automatic failover and does not remove the shared origin's failure domain.
- Kubernetes Secret creation cannot be name-scoped by RBAC. Preserve the existing narrow patch permissions, publication ownership and no-read boundary.
- Public PKI and private identity bootstrap retain their existing operational dependencies; do not add another credential or phase mechanism during this cutover.
- Kanidm's retained state and native export capability remain application facts, not backup or recovery evidence.
