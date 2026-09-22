## 1. Declared Route Contract

- [ ] 1.1 Add typed route fields for one or more non-empty hostnames, backend service, authentication mode, private/public exposure, backend protocol/TLS and declared trust source, and request timeouts; verify absent required declarations fail evaluation without introducing a separate boolean presence flag.
- [ ] 1.2 Render internal Gateway routes and backend isolation from the declared inventory; verify generated manifests contain the declared hostnames, services, trust policy, timeouts, and narrow pod selectors.
- [ ] 1.3 Render independent public entrances from only public routes; have each edge consumer validate its own hostname cardinality/domain-family policy, verify private routes are absent, and verify a rejected shape fails closed.

## 2. Proxy and Backend Trust

- [ ] 2.1 Add explicit direct and trusted-edge ingress modes with fail-closed peer-list consistency; verify direct mode derives identity from its peer, declared public edges require exact trusted peers, and the gateway accepts forwarded identity only from those peers.
- [ ] 2.2 Strip client-supplied forwarding, identity, and request-ID metadata at the public edge, generate a fresh trusted request identifier there, configure the gateway to preserve it unchanged, and emit queryless structured access logs; verify the rendered configurations enforce each boundary.
- [ ] 2.3 Configure generic backend TLS chain verification from each route's declared trust source, and configure Kanidm strict hostname verification for its primary declared identity hostname through public-PKI system roots; verify no disabled verification, invented backend-hostname field, or private-CA runtime trust input remains.
- [ ] 2.4 Pin the Gateway controller to `docker.io/envoyproxy/gateway:v1.9.1@sha256:0049bcb384c591c6a6dd043fe5c9929ef6e74f230e12dd678d2d3701df9b301e` and the data-plane to `docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4`; verify evaluated and generated resources use those exact multi-architecture identities.

## 3. Identity Lifecycle and Ownership

- [ ] 3.1 Add explicit initial, provisioning, and normal identity phases; verify initial omits provisioning inputs, provisioning runs only after its RBAC prerequisite while administrator access stays absent, and normal publishes each administrator policy before its route.
- [ ] 3.2 Keep the canonical identity hostname, issuer, SNI, and public-PKI certificate identity stable across direct and failover entrances; verify Gateway and provisioning clients use system roots without private trust inputs.
- [ ] 3.3 Keep cross-namespace Secret publication rights with the provisioning prerequisite owner and limit permissions to create plus name-scoped patch without read, list, watch, update, or delete; verify the rendered Role and RoleBinding precede the Job.
- [ ] 3.4 Record only the retained `identity-kanidm` boundary, stable host/guest/pod locations, and native export capability as future Preserve input; verify this change declares no export path, capture schedule, retention, State, Realization, ProtectionPolicy, Route, Target, Integration, adapter, verification, recovery point, or restore workflow.
- [ ] 3.5 Document the executable initial → provisioning → normal procedure; verify guidance requires private `recover-account`, immediate escrow/encryption, durable human authentication, successful provisioning and private login before normal exposure, and forbids plaintext persistence.

## 4. Convergence and Evidence

- [ ] 4.1 Order retained state before workloads, Gateway CRDs before the controller, the controller before Gateway resources, cross-namespace RBAC before provisioning, and administrator policy before route publication; verify child readiness uses actual health rather than annotations alone.
- [ ] 4.2 Add focused evaluation checks for route filtering, edge hostname-policy rejection, direct/trusted-edge client-address handling, request-ID preservation, queryless logs, three-phase fail-closed identity activation, exact image identity, real Argo dependencies, bootstrap guidance, unique desired-state ownership, public-PKI trust, Preserve seam ownership, and generated-manifest freshness.
- [ ] 4.3 Keep live DNS, certificate, public/private routing, spoofed-header, authentication, long-request, logging, and unrelated-application failure-isolation gates open until exercised on deployed infrastructure; require a live two-layer request proof that captures one fresh edge-generated request identifier unchanged in both edge and gateway logs, with queryless paths, and report structural and live results separately.
