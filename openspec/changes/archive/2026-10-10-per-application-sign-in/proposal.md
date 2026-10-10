## Why

Kanidm lists every OAuth2 client a person may use as an application on its home page. Today the Gateway protects every administrator route with one shared client, `household-admin`. That client shows up as a "Household administration" application that has no page of its own. Kanidm requires a landing URL, so it opens Argo CD, next to the real "Argo CD" application. As more administrator applications arrive, the shared client stays a single entry that can open only one of them.

The shared client also ties every administrator route to one registration, one client secret, and one token audience. Kanidm cannot record which application someone signed in to, a leaked Gateway client secret belongs to every route, and grants cannot later differ per application.

## What Changes

- Each administrator application gets its own Kanidm OAuth2 client, named after its route. The Gateway's sign-in for that route uses that client.
- An application that also signs users in itself shares its route's client. Argo CD's Gateway sign-in and Argo CD's own sign-in use one `argocd` client, so Kanidm shows one Argo CD entry. That entry starts Argo CD's Kanidm sign-in directly.
- Each administrator route declares the name people see for it. Kanidm shows that name, and each entry opens its application.
- The provisioning Job removes Kanidm OAuth2 clients that the declaration no longer contains. The `household-admin` client and its "Household administration" entry go away on the first run.
- Each client's secret is published into a Gateway Secret for that route, plus any Secret the application itself needs. The Job may read and patch only those named Secrets, as today.

Current behavior: one shared Kanidm client gates all administrator routes, and Kanidm shows it as an application that opens Argo CD.
Target behavior: Kanidm shows one entry per administrator application, each opening that application, and a sign-in for one application does not authenticate another.

Non-goals:

- No change to who may use administrator applications. The `homelab-admin` group, filled from the fleet `admins` role, still receives every grant.
- No per-application groups yet. Separate clients make them possible later.
- No Kanidm sign-in for applications that use their own logins, such as Jellyfin or Seerr.
- No change to identity phases, route exposure, or the runtime-Secret flow.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `access-control`: adds requirements that the identity service offers each administrator application once, that a sign-in for one administrator application does not grant another, and that the declaration owns every application registration in the identity service.

## Impact

- `modules/den/aspects/kubernetes/services/identity.nix`, `argocd.nix`, `modules/den/schema/cluster.nix` (route display name), `modules/den/clusters/home.nix`, and the provisioning image `pkgs/by-name/kanidm-provision-image/package.nix`.
- Kanidm: client `argocd` gains the Gateway callbacks and scopes; client `household-admin` is deleted.
- Kubernetes: `gateway/oidc-client` is replaced by `gateway/oidc-argocd`; publication Roles are named per Secret; the `argocd-admin` SecurityPolicy uses client `argocd`.
- `modules/tests/identity-contracts.nix`, `modules/tests/identity-provision-runtime.nix`, and `docs/operations/identity.md`.
- Generated manifests under `generated/manifests/prod-home/` must be regenerated. The provisioning image tag changes and must be imported into the guest before the merge deploys.
- Administrator routes added later, such as the media applications, must each declare a display name.
