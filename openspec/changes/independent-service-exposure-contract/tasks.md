## 1. Declared Route Contract

- [x] 1.1 Add typed route fields for one or more non-empty hostnames, backend service, authentication mode, private/public exposure, backend protocol/TLS and declared trust source, and request timeouts; verify absent required declarations fail evaluation without introducing a separate boolean presence flag.
- [x] 1.2 Split private and public Gateway data planes, receiving ports and selectors while retaining the private entry; verify rendered parents, listener policies and backend admission cannot attach a private route to public entry.
- [x] 1.3 Attach only eligible public routes to public entry after existing bootstrap gates; verify hostname overrides, undeclared hosts and initial identity/Homarr/Seerr states cannot expose a private or unready backend.
- [x] 1.4 Build on PR #122's resolved route projection without another registry; verify existing route-selection checks and unchanged route inventory when public transport is unconfigured.

## 2. Transport and Backend Trust

- [x] 2.1 Separate ordinary private TLS from the restricted public receiver requiring PROXY metadata; verify valid declared peers work, malformed/missing metadata is rejected, and direct clients cannot supply a trusted relay identity.
- [x] 2.2 Move header sanitation and fresh request-ID generation to the Gateway; verify forged forwarding, user and request-ID values are discarded and backend requests match the Gateway's generated ID and declared client-address source.
- [x] 2.3 Configure generic backend TLS chain verification from each route's declared trust source, and configure Kanidm strict hostname verification for its primary declared identity hostname through public-PKI system roots; verify no disabled verification, invented backend-hostname field, or private-CA runtime trust input remains.
- [x] 2.4 Keep controller and data-plane image references immutable and paired with the selected compatible chart; existing rendered-image checks verify the exact selected references. Preserve separately approved release updates rather than freezing this plan to an older release.
- [x] 2.5 Replace the WireGuard transport with native HAProxy and guest-OS Tailscale, preserving TLS and one PROXY v2 header; use scoped agenix/rekey enrollment without subnet advertisements, incidental DNS changes, broad interface trust, old WireGuard settings or compatibility aliases.
- [x] 2.6 Migrate guest, host, bridge and Pod admission for the guest Tailnet receiver only; verify relay IPv4/IPv6 and alternate-path attempts cannot reach private entry, backends, Kubernetes API, SSH or Incus while existing private forwarding remains unchanged.
- [x] 2.7 Keep approved firewall rules and ownership records across service stop, replace owned rules atomically, retain protection after failed reload, and gate public endpoint startup on loaded restrictions; prove fresh allowed and denied connections across the lifecycle without deleting Incus or Tailscale tables.
- [x] 2.8 Retain the guest's distinct mutable Tailnet identity across replacement with existing host-owned attachments, stage enrollment through the existing secret flow, and reject unintended guest egress through the hypervisor's Tailnet identity; verify identity continuity, return traffic and failure behavior.

## 3. Identity Lifecycle and Ownership

- [x] 3.1 Add explicit initial, provisioning, and normal identity phases; verify initial omits provisioning inputs, provisioning runs only after its RBAC prerequisite while administrator access stays absent, and normal publishes each administrator policy before its route.
- [x] 3.2 Keep the canonical identity hostname, issuer, SNI, and public-PKI certificate identity stable across direct and failover entrances; verify Gateway and provisioning clients use system roots without private trust inputs.
- [x] 3.3 Keep cross-namespace Secret publication rights with the provisioning prerequisite owner and limit permissions to create plus name-scoped patch without read, list, watch, update, or delete; verify the rendered Role and RoleBinding precede the Job.
- [x] 3.4 Record only the retained `identity-kanidm` boundary, stable host/guest/pod locations, and native export capability as future Preserve input; verify this change declares no export path, capture schedule, retention, State, Realization, ProtectionPolicy, Route, Target, Integration, adapter, verification, recovery point, or restore workflow.
- [x] 3.5 Document the executable initial → provisioning → normal procedure; verify guidance requires private `recover-account`, immediate escrow/encryption, durable human authentication, successful provisioning and private login before normal exposure, and forbids plaintext persistence.

## 4. Convergence and Evidence

- [x] 4.1 Order retained state before workloads, Gateway CRDs before the controller, the controller before Gateway resources, cross-namespace RBAC before provisioning, and administrator policy before route publication; verify child readiness uses actual health rather than annotations alone.
- [x] 4.2 Update affected evaluation and rendered-policy checks for Tailnet addresses, guest receiver ownership, enrollment/state, firewall lifetime and transport containment while retaining route, metadata, image and ownership checks; preserve counterfactual rejection of unsafe declarations.
- [x] 4.3 Reuse existing Kubernetes and host-network fixtures for real relay → Tailscale → rendered Envoy → backend proof with locally generated enrollment/certificates; include an actual unprivileged Incus guest, source identity through Kubernetes, retained identity, firewall lifecycle, TLS, private-host rejection, administrator/nonmember and native sign-in, spoofed metadata, queryless logs, long requests, startup/replacement isolation and private access after public-link loss.
- [x] 4.4 Remove obsolete NGINX roles, trusted-HTTP-edge settings, callers and superseded fixtures after the new proof passes; verify affected declaration, policy and runtime gates pass without compatibility aliases, duplicate route models or added application phases.

## 5. Commissioning

- [ ] 5.1 Keep activation pending until the intended service list, real addresses, scoped agenix-managed enrollment, effective Tailnet grants, DNS, certificates and required network-isolation evidence are approved; verify actual client, authentication, logging, long-request and private-recovery paths before rollout. Disposable proof does not complete this task.
