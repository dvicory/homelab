# Homarr operations

Homarr runs in the `portal` namespace. It is an application start page, not an
authorization proxy for linked services. Use the current `home` hostnames in
[Declared routes](../operations.md#declared-routes); Jellyfin still needs its
normal LAN/Tailscale access.

## Prerequisites

- Kanidm owns sign-in and portal eligibility. The `homarr-users` group includes
  `homelab-admin` and `jellyfin-users`; household users do not need administrator
  membership. Follow [Identity operations](identity.md) for identity bootstrap
  and household enrollment.
- Homarr owns board content, ACLs and home defaults in its retained state. Nix
  owns the workload, OIDC configuration, routes and static storage. See
  [Retained state](../operations.md#retained-state) for paths and ownership.
  `/appdata` is the complete application directory, backed by guest path
  `/srv/state/homarr`. The PV capacity declaration is not a filesystem quota.
- Keep independent recovery custody of the encryption key and Kanidm identities.
  Genuine master-encrypted input at
  `.secrets/hosts/compute-1/portal--homarr--SECRET_ENCRYPTION_KEY.age` and the
  current host's rekeyed output are already versioned. Do not routinely generate
  a replacement or use `--force-generate`. For a replacement host, rekey the
  **existing** input using [Runtime-secret references](../operations.md#runtime-secret-references).
  Back up the master decryption identity outside this repository.
- Use an operator workstation with private cluster access for bootstrap.
  Commands using `kubectl` assume `KUBECONFIG` selects the compute guest's
  cluster; commands using `incus` run on its host.

Keep `settings.kubernetes.services.homarr.phase = "initial"` for bootstrap or
recovery. Follow [Deploy configuration](../operations.md#deploy-configuration)
and [Lifecycle and bootstrap](../operations.md#lifecycle-and-bootstrap).
`initial` withholds both Gateway and edge routes and isolates the Pod;
`ready` admits only the Gateway on TCP 7575.

Before onboarding, confirm identity provisioning completed, both runtime
Secrets have their expected **key names**, and the workload becomes Ready:

```sh
kubectl -n identity get job kanidm-provision
kubectl -n portal get secret homarr -o json | jq '.data | keys'
kubectl -n portal get secret homarr-oidc -o json | jq '.data | keys'
kubectl -n portal rollout status statefulset/homarr --timeout=5m
```

Expect `SECRET_ENCRYPTION_KEY` and `clientSecret`, respectively. If the Job
fails or a key is missing, repair provisioning or secret staging before
continuing; do not create an ad-hoc replacement key. Homarr's live health
endpoint is `/api/health/live`, which checks SQLite and Redis.
Endpoint monitoring follows the published route; no Homarr endpoint probe is
expected during `initial`.

## Private onboarding and initial UI setup

First-run onboarding can be claimed anonymously. Do not publish either hostname
before completing this section. The `initial` phase withholds both Gateway and
edge routes and isolates the Pod; it is not merely a hidden `/init` page.

For the wizard alone, port-forward privately:

```sh
kubectl -n portal port-forward --address 127.0.0.1 service/homarr 17575:7575
```

Open `http://127.0.0.1:17575/init`, claim setup, and enter **`homelab-admin`**
exactly as the external administrator group. Homarr then requires an
administrator sign-in. After the canonical-origin sign-in below, finish setup
without discovery, integrations, Workshop, Assistant or MCP; disable anonymous
product analytics. The initial board can be `daniel-home`.
Do not create a local credentials user or enable credentials authentication.

OIDC cannot return to an unregistered localhost origin. To finish signed-in
configuration **without opening the public route**, preserve the registered
canonical HTTPS origin through an operator-only local TLS proxy. One disposable
option is Caddy on the operator's workstation:

1. Resolve `home.plus2.danielvicory.dev` to `127.0.0.1` on that workstation only;
   leave Kanidm DNS unchanged. Keep the loopback port-forward above running.
2. Use this temporary Caddyfile outside the repository:

   ```caddyfile
   https://home.plus2.danielvicory.dev {
     bind 127.0.0.1
     tls internal
     reverse_proxy 127.0.0.1:17575
   }
   ```

   Run Caddy with local permission to bind TCP 443. Trust its temporary local CA
   in the test browser only. This is not a cluster service or a production TLS
   key export. The bind must remain loopback-only.
3. Open that exact HTTPS hostname and sign in through Kanidm. The already
   registered callback is `/api/auth/callback/oidc`. Remove the proxy, local
   hostname override and temporary CA trust after verification.

### Boards and permissions

Create both boards as the administrator. Board slugs cannot contain spaces or
`+`; page titles can. Set both boards **private**, with no Everyone grant.

| Setting | Daniel+ Home | Infrastructure |
| --- | --- | --- |
| Slug | `daniel-home` | `infrastructure` |
| Page/browser title | `Daniel+ Home` | `Infrastructure` |
| `jellyfin-users` board grant | View only | None |
| `homelab-admin` access | Administrator's implicit full access | Administrator's implicit full access |
| Content | Jellyfin and Seerr app shortcuts | Kanidm, Argo CD, Grafana, Radarr, Sonarr, Prowlarr, SABnzbd; media shortcuts as useful |
| Credential-free widget | Optional date/time | Date/time; no weather, service credentials or controls |
| Layout | Few large tiles; separate Mobile layout | Simple grouped links; separate Mobile layout |

Use browser-facing URLs from [Declared routes](../operations.md#declared-routes).
Create ordinary **apps/links**, not integrations. Leave server-side app status
checks off. Check both desktop and roughly 390px-wide Mobile layouts for
usable labels and large tiles; use the built-in layouts rather than custom CSS.

In **Management → Users and groups**:

- Create `jellyfin-users` with **no global permissions**. Give only its board's
  View grant—no board creation/editing, integration use/full access, app editing,
  admin, API keys or operational controls.
- Keep `homelab-admin` as the sole externally synchronized administrator group.
  Set its desktop and mobile home to Infrastructure. Put it before the media
  group if an administrator belongs to both.
- Set **both desktop and mobile** homes of `jellyfin-users` to Daniel+ Home.
- Everyone includes **all authenticated users**, not guests. Give it no global
  permissions, no board grants, and **clear both home defaults**.
- **Clear both server-wide home defaults.** Onboarding writes initial-board
  defaults to Everyone and the server; retaining them is unsafe for this setup.
- Personal home selections override group defaults. Remove the creator's
  automatic initial-board selection or explicitly set Daniel's desktop and
  mobile home to Infrastructure. Administrators can still switch to Daniel+ Home.

Permissions are additive: a restrictive board grant does not cancel a broad
Everyone/global grant. Private boards restrict boards, not app-record secrecy:
signed-in users can retrieve app URLs through Homarr's app API. Never put
credentials, secret query strings or sensitive operational data in app records.

### Verify access

Run this matrix after initial setup, restore, and changes to identity, ACLs or
home defaults. Use distinct browser profiles and fresh sign-ins. Before
publication use the private canonical-origin path above; after publication,
repeat against both declared hostnames.

| Identity/scenario | Expected result |
| --- | --- |
| Daniel / `homelab-admin` | OIDC succeeds; Infrastructure is home on desktop/mobile; both private boards usable; management available. |
| Media-only / `jellyfin-users`, not admin | OIDC succeeds; Daniel+ Home is home on desktop/mobile; direct Infrastructure URL denied, absent from switcher; no edit, management, integration or request controls. |
| Unrelated Kanidm account | Kanidm denies the Homarr authorization request; no portal grant. |
| Unauthenticated/incognito | Neither private board renders via its direct URL; no operational data or onboarding claim after initialization. Login page or denial is acceptable. |
| Family links | Jellyfin/Seerr require their own login and retain the user's permissions, quotas and approval workflow. No privileged API actions originate in Homarr. |
| Membership change | Successful fresh login reconciles exact group names and removes absent memberships. An empty group array removes non-Everyone memberships. Check UI group membership after each login. |

Only after the private checks pass, set Homarr phase to `ready`, regenerate
manifests and generated docs, review, and deploy through
[Deploy configuration](../operations.md#deploy-configuration). Keep `initial`
if onboarding is incomplete or the access matrix fails. DNS/TLS declarations
alone do not mean the portal is published.

## Credentials, membership and revocation

People change Kanidm credentials through its own enrollment/reset and
self-service flows; see [Household media credentials](identity.md#household-media-credentials).
There is no separate Homarr password to rotate. Keep credentials authentication
disabled. After a group change, perform a fresh Homarr OIDC login and check
the resulting membership, board access and home defaults.

Kanidm and Homarr do not continuously share sessions. Membership synchronization
runs on successful OIDC login; **missing/non-array groups claims skip sync**.
An empty group array removes non-Everyone memberships. Existing Homarr sessions
are not instantly revoked by Kanidm removal; the configured session lifetime
is one hour. API keys act as their creator, are separate and do not expire.
Do not issue family API keys.

For urgent revocation:

1. Contain portal exposure by returning to `initial`; do not rely on disabling
   the IdP account alone. Revoke the person's Kanidm eligibility/credentials.
   Household membership belongs in `jellyfin-users`; administrator membership
   is declaration-owned. Do not hand-edit the provisioned `homarr-users` aggregate.
2. Hold automated sync and stop Homarr as in [Full portable capture](#full-portable-capture).
   Invalidate all Homarr sessions using the offline SQL in
   [Restore](#restore-without-old-compute-or-kubernetes-state). This signs
   everyone out; it does not revoke API keys.
3. Keep ingress closed while reviewing and revoking any issued API keys.
   Restart privately, verify fresh sign-in is denied for the removed identity
   and the access matrix still passes for authorized users, then reopen.
   Do not release ingress while an unwanted key remains usable.

Kanidm provisioning publishes the `homarr` client's secret to
`portal/homarr-oidc`; Homarr must never receive the Kanidm administrator
password. After client-secret rotation or runtime-Secret replacement, let
provisioning complete, check the key names as above, then restart Homarr:

```sh
kubectl -n portal rollout restart statefulset/homarr
kubectl -n portal rollout status statefulset/homarr --timeout=5m
```

Secrets supplied as environment variables do not update a running process.
Verify a fresh OIDC login after the rollout. A changed client secret does not
revoke existing Homarr sessions. The application encryption key is persistent
data, **not** a routine credential rotation: preserve it for every backup and
restore; do not replace it underneath existing state.

## Backup and fresh-install recovery

**A retained volume is not a backup.** Take an encrypted off-host backup after
initial UI setup, after material edits and before every upgrade. Do not assume
a backup scheduler or another service protects this state. A usable recovery
set includes the complete application directory, original encryption key,
matching configuration/image, and independently recoverable Kanidm identity.

### Full portable capture

1. Hold automated sync for both the root `apps` Application and `homarr`, using
   the same procedure as [identity recovery](identity.md#if-kanidm-sign-in-to-argo-cd-fails).
   Record the prior sync policies so they can be restored exactly.
2. Scale `statefulset/homarr` to zero and wait until `homarr-0` is deleted. Do not
   copy a live SQLite database, omit WAL files, or allow Argo to restart writers.

   ```sh
   kubectl -n portal scale statefulset/homarr --replicas=0
   kubectl -n portal wait --for=delete pod/homarr-0 --timeout=5m
   ```

   Do not continue if the Pod remains or another writer is running.
3. On the host, stream the complete guest-visible directory to encrypted storage:

   Set `BACKUP_RECIPIENT` to the independently held recovery age recipient.
   Use a new archive filename for each capture; never overwrite the only
   known-good backup.

   ```sh
   set -o pipefail
   incus --project compute exec compute-1 -- \
     tar -C /srv/state/homarr -czf - . |
     age -r "$BACKUP_RECIPIENT" -o homarr-appdata.tgz.age
   ```

   Capture through the guest view so numeric ownership is portable `1000:1000`,
   not this host's mapped `1001000:1001000`. Copy the encrypted result off-host
   and verify it can be decrypted by the recovery identity. Keep the Nix revision,
   exact image digest, Homarr version, capture time, and archive checksum with it.
   A failed pipeline or failed off-host decryption means the capture is unusable.
4. Retain the original master-encrypted Homarr key and its independent decryption
   custody. Retain/recover Kanidm's database, stable user identities and client
   registration through its own recovery path; the provisioning Job republishes
   the client secret. Fresh unrelated Kanidm user UUIDs are not the old identities.
   Keep the OIDC configuration and secret references with the revision.
5. Restore the replica and prior automated-sync settings; observe live health,
   sign-in and both boards. Keep the pre-upgrade capture until recovery is proven.

   ```sh
   kubectl -n portal scale statefulset/homarr --replicas=1
   kubectl -n portal rollout status statefulset/homarr --timeout=5m
   ```

### Restore without old compute or Kubernetes state

1. Keep Homarr at `initial`. Reconstruct storage, compute, Secrets and identity
   using [Compute-loss recovery](../operations.md#compute-loss-recovery) and
   [Identity operations](identity.md). Do not restore the old Kubernetes
   datastore or object UIDs. Hold Homarr/root sync and keep its replica at zero
   until the files are restored. Never initialize over a surviving state directory.
2. Restore into a deliberately empty `/srv/state/homarr`; preserve the complete
   contents and numeric guest ownership. For a replacement using a different host
   ID map, extract through the new guest, not directly into the host-mapped path:

   ```sh
   set -o pipefail
   age -d -i "$BACKUP_IDENTITY" homarr-appdata.tgz.age |
     incus --project compute exec compute-1 -- \
       tar -C /srv/state/homarr -xzpf -
   ```

3. Invalidate historical sessions **offline before starting the restored copy**.
   With SQLite tooling, open the stopped guest's
   `/srv/state/homarr/db/db.sqlite` and execute:

   ```sql
   DELETE FROM "session";
   ```

   This operation targets the v2.10.1 schema; confirm the session table before
   using it on a different release. Failure to open the database or execute the
   statement blocks restart. It does not revoke API keys; review and revoke
   unwanted keys separately before releasing ingress.
4. Supply the **same encryption key** and start the **same pinned Homarr release**
   that made the capture. Reconstruct the static PV/PVC from declarations, pointing
   at the restored retained path. Do not substitute a newly provisioned dynamic
   volume. Restore outside the live installation for a rehearsal.
5. Verify `/api/health/live` and repeat the full [access matrix](#verify-access)
   with fresh OIDC logins. Confirm both boards' titles, shortcuts, ACLs and
   desktop/mobile homes. A restored cookie must no longer authenticate; a new
   onboarding wizard, missing content, decryption errors or unexpected access
   means recovery has not passed. Keep ingress closed and retain the original
   capture while investigating.
6. Restore previous sync settings. Return to `ready` only after acceptance.
   Upgrade forward only after a fresh capture and rehearsal. Automatic migrations
   do **not** establish downgrade compatibility; rollback means restoring the
   matching pre-upgrade data, configuration and key, not merely an older image.

### Native export caveats

Homarr also has **Management → Tools → Backup** and an onboarding restore flow.
Its SQLite ZIP includes `db.sqlite` and `metadata.json`; metadata contains the
**plaintext encryption key**. Encrypt the ZIP before storing or transferring it.
It is not a replacement for the complete directory (certificates/files) or IdP
backup. Import can re-encrypt integration secrets for a different target key,
but restore the same version first; the importer does not enforce a general
version-compatibility guarantee. OIDC-only recovery does not support the
credentials-only `recreate-admin` command unchanged.

