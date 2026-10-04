## Why

The Gateway already requires a Kanidm administrator before it forwards a request to Argo CD, but it forwards no identity. Argo CD then asks for its local `admin` password, so GitOps administration depends on one shared local credential instead of the named administrators that the fleet ACL already declares.

## What Changes

- Argo CD signs users in through Kanidm. Members of the Kanidm administrator group, which provisioning fills from the fleet `admins` role, receive Argo CD's built-in admin role.
- Every other identity receives no Argo CD access. Kanidm refuses to issue Argo CD sign-in to non-members, and Argo CD's default policy grants nothing.
- Kanidm sign-in to Argo CD is declared only in identity phase `normal`. Phases `initial` and `provisioning` keep today's behavior.
- The local Argo CD `admin` account is enabled only before phase `normal`, and disabled in phase `normal`. It cannot serve as break-glass: it sits behind the Gateway's Kanidm gate, so it is unreachable whenever Kanidm is down. Recovery uses kubectl on the host, which does not depend on Kanidm.
- The Gateway's administrator OIDC gate in front of Argo CD stays as defense in depth. It now renews its session with Kanidm's refresh token, so open Argo CD pages keep working after the 15-minute access token expires.
- Argo CD's configured external URL changes from the chart placeholder to the declared Argo CD route hostnames.
- Kanidm client Secrets, both the existing Gateway `oidc-client` and the new Argo CD one, are declared in Git without data. The provisioning Job may only read and patch those named Secrets. It loses the right to create Secrets in the `gateway` namespace and never gains it in `argocd`.

Current behavior: the Gateway gate admits Kanidm administrators, then anyone holding the local `admin` password administers Argo CD.
Target behavior: only a Kanidm administrator-group member who signs in to Argo CD through Kanidm administers it; the local account is disabled.

Non-goals:

- No Argo CD CLI sign-in through Kanidm. The Gateway gate blocks non-browser clients on the public route; CLI use stays on the Kubernetes API (`argocd --core`) or a private port-forward.
- No read-only or per-project Argo CD roles, and no change to who is in the fleet `admins` role.
- No change to the identity phase model, the Gateway route inventory, or the agenix runtime-Secret flow.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `access-control`: adds requirements that GitOps administration comes only from central sign-in by the administrator group, that other identities get no GitOps access, and that the local GitOps administrator exists only before central sign-in.

## Impact

- `modules/den/aspects/kubernetes/services/identity.nix`, `argocd.nix`, and the provisioning image `pkgs/by-name/kanidm-provision-image/package.nix`.
- New aspect settings with defaults: `identity.settings.adminGroup` and `argocd.settings.oidc`. `modules/den/clusters/home.nix` does not change.
- New Kanidm OAuth2 client `argocd`; Secrets `gateway/oidc-client` and `argocd/argocd-kanidm-oidc` declared without data in the `identity` Application, with data filled by the provisioning Job; per-client publication Roles renamed to `kanidm-client-secret-<client>` with `get`/`patch` only; Kanidm ingress from `argocd-server`; `refreshToken: true` on administrator SecurityPolicies.
- `modules/tests/identity-contracts.nix` and `docs/operations/identity.md`.
- Generated manifests under `generated/manifests/prod-home/` must be regenerated.
- Depends on the identity phases and administrator-route gating proposed by the active `independent-service-exposure-contract` change.
