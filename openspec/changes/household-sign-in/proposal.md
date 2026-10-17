## Why

Household members need their own Jellyfin accounts, and Seerr signs people in with their Jellyfin login. Today Jellyfin knows only the declared local administrator, so every other account would be a separate Jellyfin password that the operator creates and resets by hand, outside the central identity service. The owner wants to invite the household to Seerr, so household sign-in has to exist first.

The owner chose Kanidm accounts through Jellyfin's official LDAP plugin and Kanidm's read-only LDAP gateway. Jellyfin 12.1 has no native OIDC, and the community OIDC plugin is archived upstream (see design.md).

## What Changes

- Kanidm serves its read-only LDAPS gateway. Only Jellyfin's pods may connect to it.
- A Kanidm household group, `jellyfin-users`, decides who may sign in to Jellyfin. Provisioning creates it; operators add and remove its members in Kanidm.
- Members of the household group may hold a password-only Kanidm credential. The same password signs them in to Kanidm and, through LDAP, to Jellyfin and Seerr.
- **BREAKING (identity policy):** Kanidm applies the strictest policy of all of a person's groups, and its built-in all-persons group requires MFA by default. Provisioning lowers that all-persons floor to `any`, so a person outside the administrator group may hold a password-only credential. The administrator group keeps its MFA minimum, now as one of the declared account policies, and its members' web password never works for LDAP.
- Administrators who want LDAP sign-in set a separate Kanidm POSIX password. Their passkey or MFA sign-in for Kanidm and every OIDC application does not change.
- Jellyfin runs the official LDAP plugin, pinned in the normal Linux flake package `jellyfin-ldap-plugin`. Its files and installer are bundled into the existing `jellyfin-provisioner-image`; the plugins init container uses that same image with an explicit installer command before the stock runtime starts. No additional helper image is introduced. Jellarr configures it through Jellyfin's plugin API. Members of the administrator group become Jellyfin administrators at sign-in; leaving the group removes that at the next sign-in. Everyone else is refused, and no Jellyfin account is created for them.
- Seerr needs no change: its Jellyfin login accepts these people.
- The declared local Jellyfin administrator stays a local account with its agenix password. It remains the break-glass sign-in and the account the provisioner, Jellarr bootstrap, and Seerr helper use. Directory sign-in does not convert or link any existing local account.

Current behavior: Jellyfin and Seerr accept only Jellyfin-local accounts; Kanidm has no LDAP listener and every Kanidm person needs MFA.
Target behavior: a member of the household or administrator group signs in to Jellyfin and Seerr with Kanidm credentials; the local administrator keeps working, including while Kanidm is down.

Non-goals:

- No OIDC sign-in, "Sign in with Kanidm" button, or Quick Connect changes.
- No conversion of the owner's existing Jellyfin account `daniel` to directory sign-in. That needs a new break-glass administrator and a Seerr helper redesign; design.md lists it as an owner decision.
- No household membership in Nix. Household members are not fleet users.
- No per-group Jellyfin library permissions; directory users see all libraries.
- No revocation of existing Jellyfin sessions when someone leaves a group.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `access-control`: adds requirements for household sign-in to the media server through the central identity service, media administration from the central administrator group, declared administrator credential strength, password-only household members, a directory reachable only by declared consumers, Seerr sign-in through the media server, and operator-owned household membership.
- `jellyfin-lifecycle`: adds pinned plugins installed before the runtime and a declared administrator that stays local; extends the startup ownership boundary to plugin binaries, Jellarr-owned plugin settings, and plugin-owned user links.

## Impact

- `modules/den/aspects/kubernetes/services/identity.nix`: LDAPS listener and Service port, NetworkPolicy rule for Jellyfin, household group, and declared account policies.
- `pkgs/by-name/kanidm-provision-image/package.nix`: applies the declared account policies and requires their policy document. Its changed immutable registry release must be selected with the matching consumer configuration.
- `pkgs/by-name/jellyfin-ldap-plugin/package.nix`, `pkgs/by-name/jellyfin-provisioner-image/package.nix` and `modules/flake/packages.nix`: normal pinned LDAP package/installer bundled into the existing provisioner. Publish and verify that existing image through accepted main before selecting it; no new helper namespace.
- `modules/den/aspects/kubernetes/services/jellyfin.nix`: plugins init container and Jellarr plugin configuration.
- Tests: `identity-contracts`, `jellyfin-contracts`, `identity-provision-runtime`, the native Docker `household-sign-in-runtime` app/CI lane and the separate directory K3s/kernel VM gate. The native lane materializes the same Python suite and committed manifests in an owned disposable root-run x86_64 Linux Docker fixture; it pulls the actual selected immutable verified helper digests and its canonical identity hostname must already resolve to loopback.
- `docs/operations/identity.md` and `docs/operations/jellyfin.md`.
- Regenerated `generated/manifests/prod-home` selects the actual unmodified verified main release alongside its required policy/plugin configuration. Registry publication is separate from owner-approved consumer merge/authentication rollout; no manual helper import or producer-derived fallback remains. Acceptance evidence is recorded in `tasks.md`; owner live household acceptance remains open and Seerr remains `initial`.
