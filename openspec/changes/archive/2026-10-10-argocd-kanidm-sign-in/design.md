## Context

See `proposal.md` for motivation. Current state that shapes the design:

- The `identity` Application (sync wave 2) runs Kanidm 1.11.2 and a PostSync Job, `kanidm-provision`. The Job applies `state.json` with `kanidm-provision`, replaces the scope maps of the `household-admin` client, publishes Kanidm's generated client secret, and grants `homelab-admin` membership last.
- Before this change, the Job created `gateway/oidc-client` itself, and its Role allowed `create` on every Secret in `gateway`.
- The `identity-gateway` Application (wave 4, phase `normal` only) holds the `argocd-admin` SecurityPolicy. That policy gates the `argocd` route with the `household-admin` client and does not forward identity.
- Argo CD 3.5.2 (chart 10.6.0) runs with `admin.enabled: "true"`, the chart placeholder `url: https://argocd.example.com`, no `oidc.config`, and `policy.default: ""`.
- Every Application uses `ServerSideApply=true`. In that mode Argo CD compares with structured-merge diff (`controller/state.go` calls `WithStructuredMergeDiff`).
- Cluster DNS rewrites the Kanidm issuer hostname to `kanidm.identity.svc.cluster.local`. The NetworkPolicy `identity/kanidm-private` admits only Gateway proxies and the `identity` namespace. argocd-server has no egress policy.

## Goals / Non-Goals

**Goals:**

- Satisfy the `access-control` delta with Argo CD's own OIDC client against Kanidm.
- Give every value that Kanidm and Argo CD must share one owner, and check the match by evaluation.
- Remove the provisioning Job's right to create Secrets, for the existing Gateway client and the new one alike.

**Non-Goals:**

- No Dex, no Argo CD CLI sign-in through Kanidm, and no Argo CD roles other than admin.
- No change to how the fleet ACL fills `homelab-admin`.

## Decisions

### Argo CD's own OIDC client, confidential, with PKCE

Argo CD uses its built-in `oidc.config` with a new Kanidm client named `argocd`. Dex adds a component and solves nothing here.

The client is confidential (`public = false`) and keeps PKCE required (`allowInsecureClientDisablePkce = false`). In Argo CD 3.5.2 (`util/oidc/oidc.go`), PKCE runs on the server: the verifier goes in the state cookie, and the server redeems the code with the client secret. A public browser-side client is therefore not needed.

Kanidm registers exactly `https://<host>/auth/callback` for each Argo CD route hostname, with strict redirect checking. Argo CD sets `url` to the first hostname and `additionalUrls` to the rest. `RedirectURLForRequest` (`util/settings/settings.go`) then sends the callback that matches the request's host.

No `http://localhost:8085/auth/callback` is registered. The Gateway gate already blocks non-browser clients on the public route, so CLI sign-in could not work through it anyway.

### Group claim: `groups_name`

In Kanidm 1.11.2, `extra_claims_for_account` (`server/lib/src/idm/oauth2.rs`) emits the `groups` claim as follows:

- Scope `groups` adds group UUIDs and SPNs (`name@domain`).
- Scope `groups_name` adds short group names.

The claim appears in both the ID token and userinfo. Argo CD therefore requests `openid profile email groups_name`, reads RBAC `scopes: [groups]`, and maps `g, homelab-admin, role:admin`. It needs neither `requestedIDTokenClaims` nor `enableUserInfoGroups`.

`process_requested_scopes_for_identity` returns `AccessDenied` unless every requested scope is in a scope map of a group the user belongs to. The Job maps those exact four scopes to `homelab-admin` only, so Kanidm itself refuses Argo CD sign-in to non-members. Argo CD's empty `policy.default` is the second barrier.

Alternatives considered:

- SPNs depend on the Kanidm domain.
- UUIDs are assigned at runtime and are unknown to evaluation.
- A custom claim map would add state that `kanidm-provision` merges and does not prune.

### Aspect settings own the shared values

Each shared value is a Den aspect setting with a default, owned by the aspect it describes. Any aspect reads it from `cluster.settings.kubernetes.services.<aspect>.<name>`, so `modules/den/clusters/home.nix` needs no new lines.

- `identity.settings.adminGroup` (default `homelab-admin`): the Kanidm group whose members administer Homelab. `identity.nix` provisions it; `argocd.nix` maps it to `role:admin`.
- `argocd.settings.oidc`: Argo CD's Kanidm client. `clientName` (default `argocd`), `scopes` (default `openid profile email groups_name`), and `secretName`/`secretKey` (default `argocd-kanidm-oidc`/`clientSecret`). `argocd.nix` configures Argo CD from it; `identity.nix` provisions the client and publishes its Secret from it.

Each aspect derives the rest from the cluster entity where it uses it:

- `argocd.nix`: the issuer `https://<idm hostname>/oauth2/openid/<clientName>` and `url`/`additionalUrls` from the `argocd` route hostnames.
- `identity.nix`: the callbacks `https://<hostname>/auth/callback`, after asserting that the `argocd` route's `pathPrefix` is `/`; the Secret's namespace from the route; the `app.kubernetes.io/part-of: argocd` label that Argo CD requires; and the NetworkPolicy peer from the route's namespace and `backendPodSelector`.

`identity-contracts` renders both aspects and asserts that they agree. The Job's `KANIDM_ADMIN_GROUP` value serves as the independent witness for the RBAC group.

### Client secrets: declared without data, filled by the Job

Kanidm generates OAuth2 client secrets; this repository's Kanidm is unpatched and cannot load one. The Job remains the only writer of the secret value. What changes is who creates the object.

The `identity` Application declares one Secret per client: `gateway/oidc-client` and `argocd/argocd-kanidm-oidc`. Each has `type: Opaque`, the labels its consumer needs (`app.kubernetes.io/part-of: argocd` for Argo CD's `$<secret>:<key>` lookup), and no `data`. Each client gets a Role, `kanidm-client-secret-<client>`, in the Secret's namespace with only `get` and `patch` on that one `resourceName`. Its RoleBinding names the `kanidm-provision` ServiceAccount.

The Job applies `{metadata: {name, namespace}, data: {<key>: …}}` with server-side apply as field manager `identity-provisioner`. If the Secret is missing, the API server refuses the apply because the Job has no `create` right, and the Job fails instead of minting an object.

Why this does not fight Argo CD:

- Argo CD applies with server-side apply as `argocd-controller`. That manager never owns `data`, and server-side apply removes only fields that the applying manager previously owned. Argo CD's apply leaves `data` alone.
- Argo CD diffs these Applications with `StructuredMergeDiff` (`gitops-engine/pkg/diff/diff.go`). That function runs the structured-merge-diff `Updater.Apply` over live `managedFields`. Fields that another manager owns and the desired object omits stay in the predicted live object, so they report no drift. Server-side diff would do the same, because it is a real dry-run apply.
- `Secret.data` is a granular map, so ownership is per key.
- Argo CD's client-side-apply migration only touches the `kubectl-client-side-apply` manager, not `identity-provisioner` (`gitops-engine/pkg/sync/sync_context.go`).
- Runtime Secrets already rely on the same property: the runtime-Secret publisher uses server-side apply with field manager `homelab-runtime-secrets` and preserves keys owned by others.

Why the `identity` Application owns these Secrets:

- It already owns the cross-namespace publication RBAC.
- Its sync phase completes before its own PostSync Job starts.
- The AppProject allows both `gateway` and `argocd` as destinations.
- The Secrets exist from phase `provisioning`, because the Job publishes there too, just as it does today.

Live adoption: `gateway/oidc-client` already exists, untracked, with data owned by `identity-provisioner`. Argo CD adopts it on the first sync and adds its tracking annotation; the values are unchanged.

The old Role and RoleBinding `gateway/kanidm-client-secret` are pruned, and the renamed pair takes over. Kubernetes cannot restrict `create` by name, so per-client names are what make the narrower Roles possible. They also keep the generated file names (`Role-<name>.yaml`) unique within the `identity` source directory.

Rejected alternatives:

- **Patching a key into `argocd-secret`.** The Job would need `patch` on the Secret that holds `admin.password`.
- **Copying the Kanidm secret into agenix by hand.** It is manual, and it drifts whenever Kanidm rotates the secret.
- **Letting the Job create the Secret.** It would need namespace-wide `create`, which in `argocd` would let the Job mint cluster or repository Secrets that Argo CD trusts.

### Network path

argocd-server reaches the issuer for discovery, keys, and code exchange. It resolves the canonical hostname through the existing CoreDNS rewrite to the Kanidm Service, and it verifies Kanidm's public certificate with the system roots in its image. The provisioning Job already uses this same path, so nothing depends on the host's public address, which has no hairpin DNAT.

The only new rule is a phase-`normal` ingress entry on `kanidm-private` for pods matching the `argocd` route's `backendPodSelector` in the route's namespace, on port 8443. argocd-server has no egress policy, so no egress rule is needed.

### Phase gating

- **`initial`:** the `argocd` Kanidm client, its Secrets, and its RBAC are absent.
- **`provisioning`:** they are provisioned alongside `household-admin`, while `homelab-admin` stays empty.
- **`normal` only:** `oidc.config`, the `g, homelab-admin, role:admin` policy line, the argocd-server ingress rule, and `admin.enabled: "false"`.

`url`, `additionalUrls`, `policy.default: ""`, and `scopes: [groups]` are rendered in every phase. They describe where Argo CD is served and deny by default.

### Local admin disabled in phase `normal`

`argocd.nix` renders `admin.enabled` as `!(identity phase == "normal")`. Before phase `normal`, Kanidm sign-in to Argo CD is not declared, so the local `admin` account is the only way in. In phase `normal`, it is disabled.

The local account is not kept as break-glass. It sits behind the Gateway's Kanidm gate, so it is unreachable whenever Kanidm is down, which is when break-glass matters. A separate setting to disable it later would add a step and state without adding a recovery path.

Independent recovery from `management-boundaries` remains: the Argo CD controller syncs Git without Kanidm, and the operator can use the cluster API on the host (`incus --project compute exec compute-1 -- k3s kubectl ...`). If only Argo CD's Kanidm sign-in fails while the Gateway gate works, the operator can hold automated sync and set `admin.enabled: "true"` in `argocd-cm` by hand (`docs/operations/identity.md`). The agenix `admin.password` keys stay, because phase `initial` needs them.

### Gateway gate kept, with refresh tokens

The gate stays as defense in depth. It does not make Argo CD sign-in impossible:

- The gate handles `/oauth2/callback` and `/logout`; Argo CD uses `/auth/*`.
- Kanidm sessions are shared, so the second sign-in is a redirect plus a one-time consent.

`refreshToken` changes from `false` to `true` on the generated administrator SecurityPolicies, which today means only `argocd-admin`. Without it, the edge session ends with Kanidm's 15-minute access token (`OAUTH2_ACCESS_TOKEN_EXPIRY`). After that every request, including background streams, gets a 302.

Kanidm 1.11.2 issues a refresh token on every authorization-code exchange (`generate_access_token_response`). Its lifetime is the client's `refresh_token_expiry`, 16 hours by default (`OAUTH_REFRESH_TOKEN_EXPIRY`), and each refresh replaces the session.

Trade-off: Envoy now keeps a Kanidm refresh token in a browser cookie. Envoy v1.39.1 (`source/extensions/filters/http/oauth2/filter.cc`) protects it as follows:

- It encrypts the access, ID, and refresh tokens before setting cookies (`encryptToken`). The default is AES-256-CBC keyed by SHA-256 of the filter's HMAC secret. GCM sits behind the runtime guard `oauth2_use_gcm_encryption`, which is off by default.
- It signs domain, expiry, and all three tokens with an HMAC cookie.
- Envoy Gateway v1.9.1 exposes `disableTokenEncryption`, default false, and this change leaves it unset.

A stolen cookie set therefore stays usable until Kanidm rejects the refresh token: when it expires, when its parent Kanidm session ends, or when reuse of an old refresh token makes Kanidm destroy the session. The access token alone would have lasted 15 minutes.

Kanidm refresh tokens are JWE, not JWT, so Envoy cannot read their expiry. The cookie lifetime falls back to Envoy Gateway's `defaultRefreshTokenTTL` of one week. Kanidm stays authoritative for validity; the cookie merely outlives a token that Kanidm will refuse.

This decision does not change a stated contract, so it is not in the delta spec.

### Argo CD session length

`refreshTokenThreshold` stays unset. Argo CD 3.5 can refresh server-side, and Kanidm does issue refresh tokens. However, the behavior of Kanidm's refresh response inside Argo CD's token cache has not been verified, so it is not trivially supported.

Argo CD sessions therefore end when Kanidm's 15-minute ID token expires. Re-authentication is a silent redirect while the Kanidm session lives. Revisit this if live use shows friction.

## Risks / Trade-offs

- [The first sync after this change, ordering] `argocd-cm` (wave -2) can reference `$argocd-kanidm-oidc:clientSecret` before the `identity` Application declares the Secret and the Job fills it. → Argo CD logs a missing-key warning and re-reads labeled Secrets when they change; sign-in starts working after the Job completes.
- [Local admin is disabled in the same sync that enables Kanidm sign-in] If Kanidm sign-in to Argo CD does not work on first use, no Argo CD UI sign-in remains. → The controller keeps syncing Git, and the operator recovers through kubectl on the host (`docs/operations/identity.md`).
- [The Job fails if a declared Secret is missing] For example, if someone deletes it by hand. → The Job retries up to `backoffLimit`; an Argo CD sync recreates the Secret.
- [A refresh-token cookie lives longer than an access token] → Encrypted and HMAC-signed cookies, Kanidm-side expiry and revocation (see above).
- [Group membership is removed while a session is active] Argo CD access ends within 15 minutes: the ID token expires, and Kanidm denies the new authorization because the user no longer holds the scope map. The Gateway session can last longer. Kanidm's refresh grant (`check_oauth2_token_refresh`) checks the parent session, refresh-token replay, and that scopes do not widen, but it does not re-check group membership. → This is accepted, because Argo CD still denies the user. The spec scenario covers new sign-ins. To cut the Gateway session at once, end the user's Kanidm sessions.
- [Kanidm or Argo CD details not exercised before deployment] ES256 signature verification (go-oidc uses the algorithms Kanidm advertises), consent screens, and refresh-grant acceptance by Kanidm for Envoy's request. → Operator live acceptance (task 4).

## Migration Plan

1. Regenerate manifests and publish them to the tracked branch.
2. Argo CD syncs in waves:
   - `argocd`: URL, RBAC, and `oidc.config`.
   - `identity`: Secrets adopted or created, renamed Roles, the new NetworkPolicy rule. The old Roles are pruned and the PostSync Job publishes both client secrets.
   - `identity-gateway`: the refresh-enabled policy.
3. The `argocd` sync sets `admin.enabled: "false"`. The operator verifies Kanidm sign-in to Argo CD and that local `admin` sign-in is rejected.

Rollback: revert the commit. Argo CD returns to local admin only. Kanidm keeps the `argocd` client because `--no-auto-remove` is set; delete it by hand if wanted. Reverting also restores the Job's `create` Role.
