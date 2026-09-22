## 1. Declared Route Contract

- [ ] 1.1 Add typed route fields for non-empty declared hostnames, backend identity, authentication mode, private/public exposure, backend TLS, and request timeouts; verify invalid and incomplete routes fail evaluation.
- [ ] 1.2 Render internal Gateway routes and backend isolation from the declared inventory; verify generated manifests contain the declared hostnames, services, trust policy, timeouts, and narrow pod selectors.
- [ ] 1.3 Render independent public entrances from only public routes; verify private routes are absent and public routes preserve declared hostnames and trusted request identifiers.

## 2. Proxy and Backend Trust

- [ ] 2.1 Add explicit direct and trusted-edge ingress modes with fail-closed peer-list consistency; verify direct mode derives identity from its peer, enabled public edges require exact trusted peers, and the gateway accepts forwarded identity only from those peers.
- [ ] 2.2 Strip client-supplied forwarding and identity metadata at the public edge, generate or normalize the trusted request identifier there, propagate it through the gateway, and emit queryless structured access logs; verify the rendered proxy configurations enforce each boundary.
- [ ] 2.3 Configure strict backend TLS chain and canonical identity-hostname verification through public-PKI system roots for Kanidm; verify no disabled verification or private-CA runtime trust input remains.
- [ ] 2.4 Pin the Gateway controller and data-plane images to exact multi-architecture digests; verify evaluated and generated resources use those identities.

## 3. Identity Lifecycle and Ownership

- [ ] 3.1 Add explicit initial and normal identity phases; verify initial evaluation omits provisioning credentials, jobs, OIDC publication, integration resources, and cross-namespace RBAC.
- [ ] 3.2 Enable provisioning and dependent integration only in normal phase; verify runtime secret paths and publication rights resolve from the selected cluster resources.
- [ ] 3.3 Move cross-namespace Secret publication rights to the integration owner and keep permissions to create plus name-scoped patch without read, list, watch, update, or delete; verify the rendered Role and RoleBinding.
- [ ] 3.4 Record the retained `identity-kanidm` boundary, its stable host/guest/pod locations, and Kanidm's intrinsic native online-backup/export constraints as future input to Preserve `first-class-state-protection`; verify PR #23 imports no Preserve implementation and creates no StateSlot, State, Realization, ProtectionPolicy, Route, Target, Integration, adapter, schedule, retention, verification, or restore workflow.
- [ ] 3.5 Document the private bootstrap procedure; verify guidance states that `recover-account` prints the generated credential only to the private interactive operator session, requires immediate escrow/encryption, and forbids persistence in Git, generated docs, CI/service logs, durable agent transcripts, and ordinary workspace files.

## 4. Convergence and Evidence

- [ ] 4.1 Order retained state, CRDs, controllers, identity, Gateway, and integration applications through declared Argo CD waves and child `Application` health propagation; verify readiness advances only when the child reports its actual health, not from annotations alone.
- [ ] 4.2 Add focused evaluation checks for route filtering, direct/trusted-edge identity handling, request-ID propagation, queryless logs, lifecycle gating, RBAC ownership, public-PKI trust, Preserve seam ownership, and generated-manifest freshness; run the affected Nix checks.
- [ ] 4.3 Keep live DNS, certificate, public/private routing, spoofed-header, request-ID, authentication, long-request, logging, and unrelated-application failure-isolation gates open until exercised on deployed infrastructure; verify campaign evidence reports structural and live results separately.
