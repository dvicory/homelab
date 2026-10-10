## 1. Declaration

- [ ] 1.1 Add optional, non-empty `displayName` to the route inventory, set it on the `argocd` route, and require it and a DNS-label route name on every administrator route; verify evaluation fails for an administrator route without a display name or with a dotted name
- [ ] 1.2 Derive one Kanidm client per administrator route, named after the route, with Gateway redirects, landing, scopes, and Gateway Secret `gateway/oidc-<route>`; add Argo CD's redirects, scopes, Secret, and `/auth/login` landing to client `argocd`; remove `argocd.settings.oidc.clientName`; verify `identity-contracts` checks `one-client-per-admin-route` and `argocd-shares-route-client` pass
- [ ] 1.3 Point each administrator SecurityPolicy at its route's client and Gateway Secret; verify `admin-policy-uses-route-client` passes
- [ ] 1.4 Declare each client Secret without data, with one `get`/`patch` Role per Secret named `kanidm-client-secret-<secret>`; verify `client-secrets-declared-without-create` passes

## 2. Provisioning

- [ ] 2.1 Publish each client's secret to every Secret listed for it, and delete Kanidm OAuth2 clients missing from `clients.json` after publication and before granting membership; verify `nix build .#packages.x86_64-linux.kanidm-provision-image` succeeds
- [ ] 2.2 Extend `identity-provision-runtime`: pre-existing undeclared clients, including one with `.` in its name, are deleted, both Argo CD Secrets hold Kanidm's secret, client `argocd` has the Gateway and Argo CD redirects, and the ID token still names `homelab-admin`; verify the test passes

## 3. Generated state and documentation

- [ ] 3.1 Regenerate `generated/manifests/prod-home` and verify `prod-home-manifests-fresh` and `ssa-defaults-contracts` pass
- [ ] 3.2 Update `docs/operations/identity.md` for per-application clients and hand-made client removal; verify `openspec validate per-application-sign-in --strict` passes
