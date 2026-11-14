# Identity operations

Kanidm runs in the `identity` namespace. The Gateway protects administrator
routes with OIDC from Kanidm. Argo CD and Grafana also sign users in through Kanidm.

## Canonical name and certificate renewal

Kanidm uses `https://id.bzfx.net` regardless of the application domain or
entrance. Keep that hostname and its descendants exclusive to identity.

Cloudflare must be authoritative for the certificate zones, including
`bzfx.net`, before issuance. The existing `cloudflare-api-token` runtime
Secret needs `Zone - DNS - Edit` and `Zone - Zone - Read` permissions on
`bzfx.net` and the existing application-certificate zones. Do not grant a
global API key or assume an old zone-scoped token includes a new zone.

Cert-manager uses the existing direct Cloudflare DNS-01 solver. If the
token must change, use the existing agenix/rekey runtime-secret flow;
never put the token in manifests or command arguments.

The Gateway references `identity/kanidm-tls` through a name-scoped
ReferenceGrant. Each independent public edge needs its own
`tls.identity.certificate` and `tls.identity.key` inputs covering the
canonical identity name. Application wildcard certificates are not a
substitute. Cert-manager remains the only writer of cluster TLS Secrets.

## Configure application sign-in

Set each route's `auth` policy in `home.nix`:

- `app-managed` leaves sign-in and access control to the application; it does
  not require the application to use OIDC.
- `admin-gateway` requires Kanidm administrator sign-in at the Gateway.
  Any application login and access checks still apply.

For an application's own Kanidm login, configure `native-oidc` beside the
service, including callbacks, scopes and Secret references. Callback and
login-start paths must start with `/`. Selecting a service does not publish
its route; route declarations and publication phases control access.

Administrator routes use one Kanidm client per route, available only to
`homelab-admin`. Eligible users see each application's `displayName` on
Kanidm's home page. The Gateway uses `gateway/oidc-<route>`.
Argo CD and Grafana share their route clients with their native logins:
provisioning also writes `argocd/argocd-kanidm-oidc` and
`monitoring/grafana-oidc`, respectively.

Argo CD and Grafana require **both** Gateway and application sign-in.
Both request the same permissions, so approval is reused until those
permissions change. Argo CD may still show its own login button; its
Kanidm tile starts the application's sign-in directly.

### Client and Secret safety

Provisioning owns every Kanidm OAuth2 client and deletes undeclared
clients, including manually created ones. Declare new clients in Nix.

Different clients must not write the same key in the same namespace and
Secret. **With the currently selected helper, give different clients
separate Secrets**, even when they would use different keys. Sharing a
Secret requires the fix to pass the merged-main release workflow and a
separately reviewed change selecting that helper image through the
[verified helper release workflow](jellyfin.md#deliver-helper-images).
Use the unmodified receipt at `assets/helper-release/verified.json`;
editing helper source does not change the deployed image.

Administrator clients must use `homelab-admin` as their `eligibleGroup`.
Homarr uses `homarr-users`, which includes `homelab-admin` and
`jellyfin-users`. Provisioning manages that aggregate, not household
membership or person credentials. Homarr board permissions are separate:
portal eligibility does not confer administration. See
[Homarr operations](homarr.md) for private onboarding and recovery.

Before reconciling clients or publishing Secrets, provisioning revokes
all existing client scope maps, including undeclared clients. It restores
declared access only after successful reconciliation. A failed run can
leave access revoked: inspect the `kanidm-provision` Job logs, repair the
reported problem and rerun provisioning. Revocation requires a reachable
Kanidm API and proceeds client by client; do not assume a failure revoked
every client.

### Verify application upgrades

After upgrading Argo CD or Grafana:

1. Confirm `kanidm-provision` completed and check both the Gateway and
   application sign-ins with an administrator.
2. Inspect the application's authorization request in the browser. Confirm
   its callback and requested scopes still match the declaration; do not
   copy tokens, authorization codes or cookies into logs or reports.
3. Switch between the Gateway and application sign-ins. With unchanged
   permissions, approval should not repeat. Changed permissions require
   fresh approval.
4. Confirm a non-administrator cannot gain application access.

## Bootstrap

Administrator routes remain disabled during `initial` and `provisioning`.
Confirm TLS certificates are Ready before recovering accounts.

1. Run Kanidm `recover-account` for the stock accounts through a private
   interactive `kubectl exec` session. Immediately encrypt or escrow
   the output; do not save it in ordinary files.
2. Encrypt and track the `idm_admin` credential. Select `provisioning`
   before running agenix-rekey. Commit the host-rekeyed ciphertext and
   generated manifests, then activate the host to stage the runtime
   Secret. Wait for the `kanidm-provision` PostSync Job to complete.
3. Enroll credentials for a new administrator through Kanidm's
   enrollment flow: password-plus-MFA or an optional passkey.
   Verify native login over the private canonical identity route
   before selecting `normal`. Already-enrolled accounts need no repeat.
4. Select `normal`, wait for provisioning to complete, and verify
   protected administrator access.

## Argo CD sign-in

Argo CD signs in through Kanidm in phase `normal`. Members of
`homelab-admin` get Argo CD's admin role; everyone else gets nothing.
Argo CD's local `admin` account is enabled only before phase `normal`.
It is not a break-glass path: it sits behind the Gateway's Kanidm
sign-in, so it cannot help when Kanidm is down. Recover with kubectl on
the host instead.

1. After Argo syncs, confirm that the `kanidm-provision` Job completed
   and that both client Secrets hold their key. The commands print only
   key names:

   ```sh
   kubectl -n identity get job kanidm-provision
   kubectl -n gateway get secret oidc-argocd -o jsonpath='{.data}' | jq 'keys'
   kubectl -n argocd get secret argocd-kanidm-oidc -o jsonpath='{.data}' | jq 'keys'
   ```

   Expect `["client-secret"]` and `["clientSecret"]`. If either is empty,
   check the Job's logs.
2. Open the Argo CD entry on Kanidm's home page, or open the canonical
   Argo CD URL and choose **Log in via Kanidm**. Approve the one-time
   Kanidm consent.
3. Open **User Info** and confirm that the groups include
   `homelab-admin`. Confirm admin rights by refreshing or syncing an
   Application.
4. Confirm that signing in as the local `admin` is rejected.

### If Kanidm sign-in to Argo CD fails

Run these commands on the host. The cluster API does not depend on
Kanidm, so kubectl works even when Kanidm is down. If the Gateway
sign-in still works and only Argo CD's Kanidm sign-in fails, you can
enable the local account for the repair:

1. Hold automated sync so self-heal does not revert your change. The
   root `apps` Application restores the `argocd` Application, so hold
   both:

   ```sh
   for app in apps argocd; do
     incus --project compute exec compute-1 -- k3s kubectl -n argocd patch application "$app" \
       --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
   done
   ```

2. Enable the local account:

   ```sh
   incus --project compute exec compute-1 -- k3s kubectl -n argocd patch configmap argocd-cm \
     --type merge -p '{"data":{"admin.enabled":"true"}}'
   ```

3. Sign in as `admin` with the local password you escrowed for
   `argocd-secret`. Fix the cause and publish the fix.
4. Restore automated sync on `apps`. Its sync restores the `argocd`
   Application, whose sync sets `admin.enabled` back to `"false"`:

   ```sh
   incus --project compute exec compute-1 -- k3s kubectl -n argocd patch application apps \
     --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```

   Confirm that `argocd-cm` shows `admin.enabled: "false"` again.

## Household media credentials

The official Jellyfin LDAP plugin uses Kanidm's private, certificate-verified
LDAPS gateway. Operators own `jellyfin-users` membership; provisioning creates
the group and its policy but does not replace its members. `homelab-admin`
membership stays declaration-owned and grants Jellyfin administration at
directory sign-in. Removing membership affects the next login, not existing
sessions.

Using the matching Kanidm CLI as an authorized identity operator:

```sh
kanidm person create <name> "<display name>"
kanidm person posix set <name>
kanidm group add-members jellyfin-users <name>
kanidm person credential create-reset-token <name>
```

Give the reset link privately to the person. Household non-administrators
may enroll a password-only web credential; LDAP accepts that primary password
only until they set a POSIX password. The declared `idm_all_persons` floor is
`any`, which allows password-only enrollment for all non-administrators, not
only this group. Administrator policy explicitly requires MFA or stronger
and disables primary-password LDAP fallback.

Administrators retain web MFA/passkeys and set a **separate POSIX password**.
In [Credentials](https://id.bzfx.net/ui/update_credentials), reauthenticate
as yourself, choose **UNIX Password → Set UNIX Password**, submit the new
password, then choose **Save Changes**. Household members can use the same
self-service page if they want a separate directory password; operators do
not set passwords for them.

That password authenticates LDAP, not Kanidm web sign-in. Do not grant
household members machine access or use an administrator's web password as
the directory password.

For later all-persons web MFA adoption, first enroll every affected person's
MFA/passkey and separate POSIX password. Verify media login with that password,
then change the declared `accountPolicies` floor in `identity.nix` to `mfa`.
A live-only policy change is overwritten by provisioning. Repeat Kanidm MFA,
Jellyfin and Seerr sign-in after reconciliation; account IDs must not change.
This is a credential migration, not a Jellyfin account migration.

POSIX accounts enter Kanidm's anonymous directory view; private LDAPS does
not make the corresponding anonymous HTTPS Unix-account attributes private.

## Server configuration changes

Changing the declared `server.toml` replaces Kanidm's Pod and interrupts
identity service and dependent sign-ins. Before syncing, confirm host-level
kubectl access that does not depend on Kanidm and allow for that interruption.

The replacement waits if its exact configuration revision is missing; it
cannot reuse an older revision. If it stays Pending with `FailedMount`, check
the ConfigMap named by its volume and Argo CD's sync error. Fix publication
before retrying the sync; restarting the Pod cannot supply a missing revision.

TLS Secret renewal is separate; this change does not add certificate reload.

## Upgrade

This deployment does not schedule local backups.

Run `kanidmd domain upgrade-check` and take a restorable backup before
upgrading. Upgrade minor releases sequentially; successful database
migrations cannot be downgraded. Match the CLI version to the server.

## Gateway authentication failures

Start with the Gateway access logs. Find the request by timestamp and
`request_id`; check `status`, `response_flags`, and `upstream`. Check
Kanidm's pod health and logs for the same time window.

Inspect the OAuth success and failure counters on the private
`/stats/prometheus` endpoint. Counters show OAuth outcomes, not the cause
of a failure. Monitoring does not scrape them by design: Kanidm's
application metrics are out of its scope, so inspect these counters
manually. Monitoring probes Kanidm's `/status` through the Gateway and
alerts when it stops answering ([`monitoring.md`](monitoring.md)).

Keep the OAuth2 text logger at `critical`. Do not enable verbose OAuth2
logging or add `%RESPONSE_CODE_DETAILS%` to access logs: both can expose
credential material. Other warning logs and queryless access logs remain
available.
