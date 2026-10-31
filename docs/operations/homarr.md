# Homarr portal

Homarr is the application start page, not an authorization proxy for linked
services. The declared `home` route uses the existing Gateway and wildcard TLS
at `home.plus2.danielvicory.dev` and its backup-domain counterpart. Jellyfin
remains private: its shortcut needs the same LAN/Tailscale access as before.

## Implemented boundary

- Homarr **v2.10.1**, pinned by OCI digest, one replica, SQLite under `/appdata`.
  The image labels revision `df8d03b13452bb50c55a424187e1fa188ab510d2`;
  the release tag is one commit later. The [upstream comparison](https://github.com/homarr-labs/homarr/compare/df8d03b13452bb50c55a424187e1fa188ab510d2...0f0987d2ed013c93ce30c1c00786983d29f4b956)
  changes only the changelog and package version, not the researched auth/API
  or recovery code. Runtime evidence identifies the image by digest.
- Static retained `homarr` PV/PVC; `/srv/state/homarr` in the guest maps to
  `/var/lib/homelab/compute-1/state/homarr` on the host. Guest identity
  `1000:1000`, mode `0700`; storage remains host-owned and encrypted at rest.
  `5Gi` is the PV capacity declaration, not a filesystem quota.
- Stock entrypoint starts as root with only CHOWN, DAC_OVERRIDE, SETUID and
  SETGID, then drops to PUID/PGID 1000. No privileged container, Docker socket,
  host API mount, Kubernetes RBAC, or mounted service-account token.
- Startup/readiness/liveness use `/api/health/live` (SQLite and Redis), not
  upstream's unconditional `/api/health/ready`. Requests: 100m CPU/256Mi;
  limits: 2 CPU/1Gi. Long-lived browser streams have no Gateway request timeout.
- OIDC only. Kanidm's `homarr` client requests `openid profile email groups_name`
  with PKCE; `groups` contains short names. `homarr-users` nests the existing
  `homelab-admin` and `jellyfin-users` groups. No person joins the administrator
  group merely to use the portal.
- Encryption key comes through agenix/rekey and the existing runtime-Secret
  staging flow. Kanidm provisioning publishes only its generated client secret
  to `portal/homarr-oidc`; Homarr never receives the Kanidm administrator password.
- Ingress is deny-all during `initial`, Gateway-only on TCP 7575 during `ready`.
  Egress remains the cluster's existing default; no integration credentials are
  installed. Server-side URL fetches and widgets are therefore an additional
  boundary, not permission to probe arbitrary private services.

Current OpenSpec access, management, secrets and retained-state contracts apply.
Board appearance and application-internal state remain Homarr-owned; this adds
no new fleet contract or Preserve dependency.

## Before the first deployment

1. Generate and rekey `portal--homarr--SECRET_ENCRYPTION_KEY` for `hvn-hyp1`
   through the existing agenix tooling. Its master-encrypted input belongs at
   `.secrets/hosts/compute-1/portal--homarr--SECRET_ENCRYPTION_KEY.age`.
   The resource declares an inline 32-byte/64-hex-character generator. Track
   genuine encrypted input and host-rekeyed output before deployment; never
   substitute an example value. Back up the master decryption identity outside
   this repository. Do **not** regenerate this key when restoring state.

   From this workspace, use the explicit path-flake action (the `agenix` wrapper
   otherwise discovers the enclosing work repository):

   ```sh
   system=$(nix eval --impure --raw --expr builtins.currentSystem)
   nix run "path:.#agenix-rekey.$system.generate" -- \
     .secrets/hosts/compute-1/portal--homarr--SECRET_ENCRYPTION_KEY.age
   nix run "path:.#agenix-rekey.$system.rekey"
   ```

   The rekey step may need your hardware-held master identity. Do not pass
   `--force-generate` for an existing key.
2. Keep `settings.kubernetes.services.homarr.phase = "initial"`. Render and
   validate the configuration, then use the normal operator-approved deployment
   procedure. This PR does not deploy anything. `homarr-retained` supplies the
   namespace and storage; identity's wave-2 PostSync Job publishes the OIDC
   Secret before the wave-3 Homarr workload starts.
3. Confirm the identity provisioning Job succeeded and the runtime Secrets have
   the expected **key names**, without printing values:

   ```sh
   kubectl -n identity get job kanidm-provision
   kubectl -n portal get secret homarr -o json | jq '.data | keys'
   kubectl -n portal get secret homarr-oidc -o json | jq '.data | keys'
   kubectl -n portal rollout status statefulset/homarr --timeout=5m
   ```

   Expect `SECRET_ENCRYPTION_KEY` and `clientSecret`, respectively. Secret
   changes delivered as environment variables require a Homarr rollout after
   publication; staging a new Secret does not update a running process.

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
| Content | Jellyfin and Seerr app shortcuts | Kanidm, Argo CD, Radarr, Sonarr, Prowlarr, SABnzbd; media shortcuts as useful |
| Credential-free widget | Optional date/time | Date/time; no weather, service credentials or controls |
| Layout | Few large tiles; separate Mobile layout | Simple grouped links; separate Mobile layout |

Use browser-facing URLs from [Declared routes](../operations.md#declared-routes).
Create ordinary **apps/links**, not integrations. Leave server-side app status
checks off. Do not create dead Immich tiles; leave room for later services.
Check at roughly 390px wide and on desktop; use the protected Mobile layout,
large labels and no custom CSS. A three-column starting layout is sufficient
for two app tiles; adjust in the UI rather than adding custom responsive code.

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

### Access acceptance before publication

Use distinct browser profiles, not merely an already-authenticated tab. Test
both declared hostnames after publication; use the private canonical path first.

| Identity/scenario | Expected result |
| --- | --- |
| Daniel / `homelab-admin` | OIDC succeeds; Infrastructure is home on desktop/mobile; both private boards usable; management available. |
| Media-only / `jellyfin-users`, not admin | OIDC succeeds; Daniel+ Home is home on desktop/mobile; direct Infrastructure URL denied, absent from switcher; no edit, management, integration or request controls. |
| Unrelated Kanidm account | Kanidm denies the Homarr authorization request; no portal grant. |
| Unauthenticated/incognito | Neither private board renders via its direct URL; no operational data or onboarding claim after initialization. Login page or denial is acceptable. |
| Family links | Jellyfin/Seerr require their own login and retain the user's permissions, quotas and approval workflow. No privileged API actions originate in Homarr. |
| Membership change | Successful fresh login reconciles exact group names and removes absent memberships. An empty group array removes non-Everyone memberships. Check UI group membership after each login. |

Kanidm and Homarr do not continuously share sessions. Membership synchronization
runs on successful OIDC login; **missing/non-array groups claims skip sync**.
Existing Homarr sessions are not instantly revoked by Kanidm removal. The
configured session lifetime is one hour; API keys are separate and nonexpiring.
Do not issue family API keys. For urgent revocation, contain portal exposure and
invalidate Homarr sessions/keys as well as revoking Kanidm access; do not rely
on disabling the IdP account alone.

Only after these checks pass, set Homarr phase to `ready`, regenerate manifests
and generated docs, review, and deploy through the normal procedure. Until then,
DNS/TLS declarations do not mean that the portal is publicly published. No root
website redirect or changes to unrelated service authentication are included.

## Backup and fresh-install recovery

**A retained volume is not a backup.** Until Preserve has an approved capture
policy, the operator must take an encrypted off-host backup after initial UI
setup, after material edits and before every upgrade. This iteration creates no
backup scheduler, repository, retention policy or claim that Preserve protects it.

### Full portable capture

1. Hold automated sync for both the root `apps` Application and `homarr`, using
   the same procedure as [identity recovery](identity.md#if-kanidm-sign-in-to-argo-cd-fails).
   Record the prior sync policies so they can be restored exactly.
2. Scale `statefulset/homarr` to zero and wait until `homarr-0` is deleted. Do not
   copy a live SQLite database, omit WAL files, or allow Argo to restart writers.
3. On the host, stream the complete guest-visible directory to encrypted storage:

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
4. Retain the original master-encrypted Homarr key and its independent decryption
   custody. Retain/recover Kanidm's database, stable user identities and client
   registration through its own recovery path; the provisioning Job republishes
   the client secret. Fresh unrelated Kanidm user UUIDs are not the old identities.
   Keep the OIDC configuration and secret references with the revision.
5. Restore the replica and prior automated-sync settings; observe live health,
   sign-in and both boards. Keep the pre-upgrade capture until recovery is proven.

### Restore without old compute or Kubernetes state

1. Keep Homarr at `initial`. Reconstruct storage, compute, Secrets and identity
   using the normal lower-layer recovery path. Do not restore the old Kubernetes
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

3. Invalidate historical sessions **offline before starting the restored copy**:
   with SQLite tooling against the stopped guest's `/srv/state/homarr/db/db.sqlite`,
   execute `DELETE FROM "session";`. This exact v2.10.1 operation was exercised
   in the disposable recovery rehearsal: the old cookie was rejected and a fresh
   login retained the board/link/grants. It does not revoke API keys; review and
   revoke unwanted keys separately before releasing ingress.
4. Supply the **same encryption key** and start the **same pinned Homarr release**
   that made the capture. Reconstruct the static PV/PVC from declarations, pointing
   at the restored retained path. Do not substitute a newly provisioned dynamic
   volume. Restore outside the live installation for a rehearsal.
5. Verify `/api/health/live`, successful fresh OIDC login, both boards' titles,
   shortcuts, ACLs and desktop/mobile homes. Check a media-only account and an
   anonymous direct URL again. Inspect any approved encrypted integration data
   separately if integrations are added later; the link-only portal has none.
6. Restore previous sync settings. Return to `ready` only after acceptance.
   Upgrade forward only after a fresh capture and rehearsal. Automatic migrations
   do **not** establish downgrade compatibility; rollback means restoring the
   matching pre-upgrade data, configuration and key, not merely an older image.

Homarr also has **Management → Tools → Backup** and an onboarding restore flow.
Its SQLite ZIP includes `db.sqlite` and `metadata.json`; metadata contains the
**plaintext encryption key**. Encrypt the ZIP before storing or transferring it.
It is not a replacement for the complete directory (certificates/files) or IdP
backup. Import can re-encrypt integration secrets for a different target key,
but restore the same version first; the importer does not enforce a general
version-compatibility guarantee. OIDC-only recovery does not support the
credentials-only `recreate-admin` command unchanged.

Preserve's future input is deliberately small: retained key `homarr`, complete
application directory, **stopped-writer** consistency, original encryption-key
custody, exact version/configuration, and independently recoverable Kanidm
identity. Preserve owns future cadence, retention, off-host targets and restore
policy. No Preserve code or deployment prerequisite is added here.

## Automation and future capability assessment

The [v2.10.1 REST schema](https://github.com/homarr-labs/homarr/blob/v2.10.1/apps/docs/public/api/open-api-schema.json)
can create/update apps and boards, add tiles, and set a user's home. Group CRUD,
global permissions, group defaults and board ACL grants still use internal
`tRPC` procedures. ACL writes replace the complete permission list. REST/tRPC
API keys act as their creator and do not expire. Initial UI configuration plus
backup is smaller and safer than an admin-key bootstrap client or reconciler.
No long-lived automation key or application database seeder is installed.

| Capability | Existing Homarr security model | Recommendation |
| --- | --- | --- |
| Media discovery/requests | Seerr search/request uses the saved shared API key, not the viewer's Seerr identity; requests do not carry per-viewer identity. Approve/decline are privileged shared actions. | Keep links. Identity-preserving requests need additional upstream/delegation development; never give the family the global administrative key. |
| Jellyfin activity/recent media | Saved Jellyfin key or credentials; activity can disclose other viewers, devices and network details. No Kanidm-to-Jellyfin user-token propagation. | Admin-only if later approved; assess actual credential scope and exposed fields first. |
| Immich photos | Shared account API key; album widget can select random timeline photos when album is omitted. Not per-viewer Immich authorization. | Wait for Immich deployment; dedicated narrowly scoped account/key and explicit approved album, not the owner's timeline. |
| Infrastructure information/controls | Date/time and ordinary links need no service credentials. API widgets/actions inherit saved credentials; Docker/Kubernetes controls add authority. | Links/clock initially; read-only, admin-only data before controls. No sockets or Kubernetes token/RBAC. |
| Custom widgets | Another data/code boundary. Board viewers can see widget integration data; custom integration requests need full integration access, even for GET. | Not a household least-privilege workaround. Review credentials, server-side URLs and output disclosure separately. |
| MCP / Assistant / agents | Act within the authenticated Homarr user's permissions; keys act as creator. Integration requests still use saved service credentials. | No initial setup. Later use a narrowly scoped actor, not an admin key or unrestricted integration access. |
| More Nix/API automation | REST handles many apps/tiles; private group/ACL APIs add version coupling and destructive replacement semantics. | Consider a one-shot supported API importer only when recurring manual work justifies it; do not start with reconciliation. |

Sources, pinned to the deployed release: [OIDC/group sync](https://github.com/homarr-labs/homarr/blob/v2.10.1/packages/auth/events.ts),
[home precedence](https://github.com/homarr-labs/homarr/blob/v2.10.1/packages/api/src/router/board.ts),
[backup implementation](https://github.com/homarr-labs/homarr/blob/v2.10.1/apps/nextjs/src/app/api/backup/import/route.ts),
[Seerr request identity](https://github.com/homarr-labs/homarr/blob/v2.10.1/packages/integrations/src/overseerr/overseerr-integration.ts),
[custom-widget security](https://github.com/homarr-labs/homarr/blob/v2.10.1/apps/docs/docs/management/custom-widgets/requests-and-security.mdx),
[MCP](https://github.com/homarr-labs/homarr/blob/v2.10.1/apps/docs/docs/management/mcp.mdx),
[Kanidm group nesting](https://kanidm.github.io/kanidm/stable/accounts/groups.html#nested-groups).

## Verification shipped with this change

```sh
system=$(nix eval --impure --raw --expr builtins.currentSystem)
nix build --no-link \
  "path:.#checks.$system.homarr-contracts" \
  "path:.#checks.$system.homarr-encryption-key" \
  "path:.#checks.$system.identity-contracts" \
  "path:.#checks.$system.public-edge-contracts" \
  "path:.#checks.$system.prod-home-manifests-schema" \
  "path:.#checks.$system.prod-home-manifests-policy" \
  "path:.#checks.$system.prod-home-manifests-fresh" \
  "path:.#checks.$system.argocd-application-health"
```

The Homarr checks cover private publication in every identity/Homarr phase pair,
Gateway-only admission, non-administrative media eligibility, exact OIDC
callback/scope boundaries, secret-before-consumer ordering, and real 64-hex-key
generation. The native policy matrix includes the new workload, storage,
Application and secret-publication resources rather than excluding them.

Disposable native ARM64 container/browser rehearsals exercised the pinned image,
its UID/capability startup, OIDC-only external-admin-group onboarding, mobile
layout, full stopped-directory recovery and native ZIP export/import onto fresh
instances. The recovery fixture used throwaway **credentials authentication**:
private-board anonymous refusal, fresh login, title/link/home/inherited-admin
grant preservation and offline session invalidation were observed. It had no
integrations, so encrypted service-credential decryption was not exercised.
Production Kanidm claims, the media-only ACL matrix, clean-assets mobile
appearance and native x86 cluster behavior still require the acceptance steps
above; the rehearsal does not claim those results.
