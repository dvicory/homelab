## Context

See `proposal.md` for scope. Kanidm 1.11.2, stock Jellyfin 12.1 and Seerr 3.4.1 are already pinned. Jellyfin's provisioner and Seerr's helper use the declared local administrator. Jellarr owns selected API configuration, not plugin binaries or directory membership.

The disposable proof established that Kanidm combines group policies using their strictest credential minimum. Its built-in `idm_all_persons` MFA floor prevents a household group from permitting password-only enrollment by itself. The owner approved password-only non-administrators, explicit MFA/passkey web sign-in for administrators, and password-only LDAP sign-in with a separate administrator POSIX password.

## Goals / Non-Goals

**Goals:** Preserve local recovery and existing account IDs; use central group membership for new directory users; keep binaries pinned and configuration API-owned; prove the credential boundaries against the real pinned services.

**Non-Goals:** No conversion of an existing local account, session revocation, OIDC plugin, public directory endpoint, machine-access grants for household members, or automatic Seerr publication.

## Decisions

### Declare credential policies before granting administration

Provisioning lowers `idm_all_persons.credential_type_minimum` to `any`, explicitly sets the administrator group to `mfa` with primary-credential LDAP fallback disabled, and sets the household group to `any` with fallback enabled. Kanidm still accepts a passkey as a strong web credential. This permits password-only enrollment for every non-administrator, not just household members; only the household and administrator groups may sign in to Jellyfin.

Administrator LDAP authentication uses an operator/user-set POSIX password. It does not replace their web credential or authenticate OIDC. Household users without a POSIX password use their primary password through fallback. A user who sets a POSIX password must use that password for LDAP. POSIX enrollment exposes those accounts to Kanidm's read-only anonymous directory view; LDAPS is limited by NetworkPolicy to Jellyfin Pods.

Provisioning creates the household group without overwriting its members. It clears administrator membership before fallible policy/client reconciliation and restores declared administrators only after those operations succeed. People, credentials, and local Jellyfin accounts are not reset.

### Use the official LDAP plugin over certificate-verified LDAPS

Pin LDAP Authentication v24 and its target ABI 12 in a Nix-built plugin installer image. A Jellyfin major-version mismatch fails evaluation. The init container runs after first-start provisioning, replaces the declared plugin's binaries, removes other versions of that plugin, and disables its automatic updates. The official stock runtime remains unchanged.

Jellarr finds the loaded plugin as `LDAP-Auth` and applies selected configuration through its API. It does not request installation from a plugin repository. Anonymous search needs no service-account credential. The search filter includes only household and administrator groups; the administrator filter includes only the administrator group. TLS verification remains enabled. The plugin owns its directory-to-Jellyfin links, and Jellarr must preserve them.

An existing local `daniel` remains local: its directory password cannot authenticate that account. Another central administrator can obtain an LDAP-backed Jellyfin administrator account. The local account remains Seerr's owner and the automation/recovery credential.

### Verify the applications and the network boundary separately

`household-sign-in-runtime` runs the committed manifests' images and commands in a disposable Docker VM, with a test CA and generated credentials. It exercises real provisioning, plugin installation, Jellarr, LDAP/Jellyfin/Seerr sign-in, membership changes, restart and identity outage. Kubernetes NetworkPolicy enforcement is tested on the disposable K3s fixture; Docker alone cannot establish it. Existing identity-provision acceptance retains OAuth2 and Secret publication coverage.

### Later MFA adoption is a credential migration

Before raising the household/all-persons credential floor to `mfa`, enroll each affected user's second factor or passkey and a separate POSIX password, then verify LDAP/Jellyfin/Seerr sign-in with that password. Change the declared policy, not just live state that provisioning will overwrite. No Jellyfin/Seerr database or user-ID migration is required. Acceptance must prove that the separate LDAP password keeps working and the MFA web credential is not accepted as the LDAP password.

## Risks / Trade-offs

- Lowering the all-persons floor permits password-only web enrollment for all non-administrators. Explicit administrator policy is mandatory before restoring its membership.
- LDAP is single-factor even for administrators; it does not provide MFA on media clients. Network isolation, certificate verification and group admission remain required.
- POSIX-visible directory attributes may also be visible through Kanidm's anonymous HTTPS Unix-account API. Do not promise directory confidentiality merely because its LDAP port is private.
- Group removal affects the next sign-in; existing Jellyfin/Seerr sessions are not revoked by this change.
- The owner must import the new provisioner/plugin images before a merge reaches Argo. Retained plugin configuration and credentials remain unchanged on rollback; remove the LDAP plugin configuration/initializer together when disabling directory sign-in.
- Seerr stays `initial` until owner and household sign-in are accepted. Operator deployment, credential enrollment and live-device acceptance are separate gates, not inferred from VM success.
