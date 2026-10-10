## 1. Kanidm client and secret publication

- [x] 1.1 Add the aspect settings `identity.settings.adminGroup` and `argocd.settings.oidc` (client name, scopes with `groups_name`, Secret name and key), and derive issuer, callbacks, Secret namespace and label, and the server selector from the cluster entity where each is used; verify `identity-contracts` checks `argocd-redirects-match-route` and `argocd-admin-group-matches-kanidm` pass
- [x] 1.2 Provision the `argocd` OAuth2 client (confidential, PKCE required) next to `household-admin`, and publish both through `clients.json`; verify `client-secrets-declared-without-create` passes
- [x] 1.3 Declare `gateway/oidc-client` and `argocd/argocd-kanidm-oidc` without data in the `identity` Application, and replace the publication Role with per-client `get`/`patch` Roles limited to each Secret's name; verify `provisioning-rbac-before-job` and `initial-provisioning-absent` pass
- [x] 1.4 Make the provisioning script loop over `clients.json`: per client, set strict redirects, replace scope maps, and apply only `data` to the declared Secret, with group membership still granted last; verify `nix build .#packages.x86_64-linux.kanidm-provision-image` succeeds (shellcheck runs in `writeShellApplication`)
- [x] 1.5 Admit argocd-server to `kanidm-private` in phase `normal` only; verify the `argocd-sign-in-normal-only` check passes

## 2. Argo CD sign-in

- [x] 2.1 Set `url` and `additionalUrls` from the route hostnames, `oidc.config` in phase `normal` only, `policy.default: ""`, `scopes: [groups]`, and `g, homelab-admin, role:admin` in `normal`; verify `argocd-sign-in-normal-only` and `argocd-client-secret-reference` pass
- [x] 2.2 Render `admin.enabled` as true before phase `normal` and false in `normal`; verify `argocd-local-admin-normal-disabled` passes and the generated `argocd-cm` has `admin.enabled: "false"`

## 3. Gateway session and generated state

- [x] 3.1 Set `refreshToken: true` on administrator SecurityPolicies; verify `admin-gateway-session-renews` passes
- [x] 3.2 Regenerate `generated/manifests/prod-home` with `nix run .#sync-prod-home-manifests`, track the new files, and verify `prod-home-manifests-fresh`, `prod-home-gitops-source`, and `ssa-defaults-contracts` pass
- [x] 3.3 Update `docs/operations/identity.md` with the Argo CD sign-in procedure and the kubectl recovery for failed Kanidm sign-in; verify `openspec validate argocd-kanidm-sign-in --strict` passes

## 4. Live acceptance (operator)

- [x] 4.1 After sync, confirm the `kanidm-provision` Job completed and both client Secrets hold their key; verify with `kubectl -n argocd get secret argocd-kanidm-oidc -o jsonpath='{.data}' | jq 'keys'`, which prints only the key name `clientSecret`, and an `argocd.argoproj.io/tracking-id` annotation on both Secrets
- [x] 4.2 Sign in to Argo CD through Kanidm as an administrator-group member and confirm the admin role; verify that **User Info** lists `homelab-admin` and that an Application sync succeeds
- [x] 4.3 Confirm that a Kanidm account outside `homelab-admin` cannot sign in to Argo CD; verify that Kanidm shows access denied, or that Argo CD shows no Applications
- [x] 4.4 Keep an Argo CD page open for more than 15 minutes; verify that the Gateway renews the session without a 302 on API or stream requests
- [x] 4.5 Confirm that local `admin` sign-in is rejected; verify that `argocd-cm` has `admin.enabled: "false"` and that signing in as `admin` with the local password fails
