## Context

See `proposal.md` for motivation. Current state that shapes the design:

- The `identity` Application (sync wave 2) provisions two Kanidm OAuth2 clients through its PostSync Job: `household-admin` for the Gateway and `argocd` for Argo CD's own sign-in. `clients.json` lists each client, its scopes, and one Secret that receives its generated secret.
- The `identity-gateway` Application (wave 4, phase `normal` only) holds one SecurityPolicy per administrator route. Every policy uses client `household-admin` and Secret `gateway/oidc-client`.
- Kanidm 1.11.2 lists each OAuth2 client on which a person holds a scope map, with the client's `displayname` and `oauth2_rs_origin_landing`. It has no setting that hides a client from that list.
- The Job runs `kanidm-provision --no-auto-remove`, so a client that disappears from `state.json` stays in Kanidm. That flag exists to keep people and their credentials when they leave the declaration.
- Envoy Gateway reads an OIDC client secret from key `client-secret`. Argo CD reads `$<secret>:<key>` only from Secrets in its own namespace labeled `app.kubernetes.io/part-of: argocd`.

## Goals / Non-Goals

**Goals:**

- One Kanidm client, and one Kanidm list entry, per administrator application, each landing on its application.
- Kanidm holds no OAuth2 client that the declaration does not contain.
- The Job still creates no Secret and may patch only the Secrets declared for it.

**Non-Goals:**

- No per-application groups, and no Kanidm sign-in for applications with their own logins.
- No change to identity phases, the Gateway's refresh-token session, or Argo CD RBAC.

## Decisions

### One client per administrator route, named after the route

The identity aspect derives one client from each route with `auth = "admin"`. The client name is the route name, so client `argocd` serves route `argocd`. Its SecurityPolicy uses that client's issuer, client ID, and Gateway Secret. The route name also becomes part of Kubernetes object names, so evaluation requires a lowercase DNS label that starts with a letter, which Kanidm's name syntax also accepts.

When an application also signs users in itself, the identity aspect adds the application's needs to its route's client instead of creating a second client. Argo CD is the only such application. Its client gets Argo CD's `/auth/callback` redirects next to the Gateway's `/oauth2/callback` redirects, the union of both scope lists, and Argo CD's Secret next to the Gateway Secret. `argocd.settings.oidc.clientName` goes away; Argo CD's client ID is its route name.

Each requested scope must be mapped to the user's group, or Kanidm refuses the request. The Job maps the union, `openid profile email homelab_admin groups_name` for Argo CD, to the administrator group only, so both the Gateway's and Argo CD's requests succeed for members and fail for everyone else.

Alternatives considered:

- Rename the shared client. The list entry would remain and could still open only one application.
- Drop the Gateway gate in front of Argo CD and use only Argo CD's client. That removes a protection layer from the most powerful application, and the media routes would still need a Gateway client.

### Display name on the route, landing on the application

The route inventory gains an optional, non-empty `displayName`. The identity aspect requires it on every administrator route and uses it as the client's Kanidm display name. A route is already the declared entrance for one application, so the name people see for it belongs there, not in a separate list keyed by route.

Each client lands on its route's first URL. Argo CD's client lands on `/auth/login`. In Argo CD 3.5.2, `HandleLogin` (`util/oidc/oidc.go`) accepts an empty `return_url` and returns to the base path, so one click in Kanidm signs the user in to Argo CD.

### Client Secrets: one Gateway Secret per route, plus the application's own

Every client publishes to `gateway/oidc-<route>` with key `client-secret`. Argo CD's client also publishes to `argocd/argocd-kanidm-oidc` with key `clientSecret`, unchanged. The Job writes the same Kanidm-generated value to both.

Publication Roles are named `kanidm-client-secret-<secret>`, one per Secret, with only `get` and `patch` on that Secret. Naming them per client would put two Roles with one name in the `identity` source directory, whose generated file names must be unique.

Alternative considered: one Secret in `argocd`, read by the SecurityPolicy through a ReferenceGrant. Envoy Gateway needs key `client-secret`, so Argo CD's key would change on a live Secret, and the `gateway` namespace would gain read access into `argocd`. Two copies written by one Job keep each namespace self-contained.

### The Job removes undeclared clients

After it publishes every declared client's secret and before it grants membership, the Job lists Kanidm's OAuth2 clients and deletes each one that `clients.json` does not name. It accepts any name in Kanidm's own syntax, including `.`, so a hand-made client cannot block the Job. A failed deletion fails the Job, so membership stays empty, as for any other provisioning failure. Deleting before the grant matters because a leftover registration may still map scopes to the administrator group; granting membership first would let administrators sign in through an application nobody declared.

Alternatives considered:

- Drop `--no-auto-remove`. `kanidm-provision` would then also delete people and groups that leave the declaration, which the identity design deliberately avoids.
- A list of retired client names. It would need editing for every removal and would miss clients created by hand.

Kanidm in this repository serves only Homelab, so the declaration owns every OAuth2 client. A client created by hand is deleted on the next Job run. `docs/operations/identity.md` says so.

## Risks / Trade-offs

- [Rollout gap] The `identity` sync prunes `gateway/oidc-client` before `identity-gateway` (wave 4) switches the SecurityPolicy to `gateway/oidc-argocd`. → The Argo CD route returns an error for that gap, typically a minute or two, then recovers. The cluster API is unaffected.
- [Missing image] The Job image tag changes. If it is not imported before the merge, the Job cannot start, `oidc-client` is already pruned, and the Argo CD route stays down. → Import the image before merging; recovery is the kubectl path in `docs/operations/identity.md`.
- [Existing sessions] Open sessions hold `household-admin` tokens. Their refresh fails once that client is deleted. → One extra Kanidm sign-in.
- [Consent] Client `argocd` requests a new scope set. → Kanidm asks for consent once.
- [Hand-made clients] Any OAuth2 client created outside the declaration is deleted. → Documented; declare clients in Nix instead.

## Migration Plan

1. Build the new provisioning image from the merge candidate and import it into `compute-1` before merging.
2. Merge. Argo CD syncs `identity`; its Job updates client `argocd`, publishes `gateway/oidc-argocd`, deletes `household-admin`, and grants membership. Then `identity-gateway` switches the SecurityPolicy.
3. Confirm that Kanidm lists one Argo CD entry, that the entry signs in to Argo CD, and that `household-admin` is gone.

Rollback: revert the commit. The Job recreates `household-admin` and republishes `gateway/oidc-client`. Client `argocd` keeps working for Argo CD's own sign-in.
