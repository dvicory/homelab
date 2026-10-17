## 1. Declaration and ownership

- [x] 1.1 Declare the LDAPS listener and Service, household group and account policies. Evaluate phases and prove explicit administrator MFA plus operator-owned household membership in the real provisioning run.
- [x] 1.2 Pin the official LDAP plugin as the normal Linux flake package `jellyfin-ldap-plugin`, bundle its installer into the existing `jellyfin-provisioner-image`, and use that same image with an explicit installer command after first-start provisioning, without an additional helper image; reject an incompatible Jellyfin ABI and prove replacement of another plugin version on restart.
- [x] 1.3 Configure the loaded plugin through Jellarr without installing another plugin or overwriting plugin-owned user links; prove repeat reconciliation and existing local administrator recovery.

## 2. Acceptance

- [x] 2.1 Exercise the committed images and commands through the native Docker `household-sign-in-runtime` app/CI lane, materializing the same Python suite and manifests on an owned disposable native x86_64 Linux Docker host as root and pulling the actual selected immutable verified registry helpers. The canonical identity hostname already resolves to `127.0.0.1`, with no app-owned host-resolution edits: real Kanidm, Jellyfin and Seerr household sign-in, outsider/empty/wrong-password refusals, administrator POSIX-password sign-in, membership changes and repeat provisioning. Preserve all authentication/security assertions, credentials, deadlines, workload ownership, native administrator/Seerr identities, and established-session HTTP 200 versus fresh-login denial; do not introduce a Docker VM envelope. Disposable Linux acceptance and [hosted CI run 39026785505](https://github.com/dvicory/homelab/actions/runs/39026785505) passed at feature commit `0e0af6e1`, using the selected verified images published from main `d3302d35`. Live acceptance remains task 3.2.
- [x] 2.2 Prove certificate verification in the application lane and Kubernetes NetworkPolicy in the separate directory K3s/kernel VM gate: only the declared Jellyfin workload reaches LDAPS; an undeclared Pod is refused.
- [x] 2.3 Prove restart preserves directory user IDs and identity outage refuses directory sign-in while the local administrator still works.
- [x] 2.4 Prove a later all-persons MFA floor works after enrolling a household user's MFA credential and separate POSIX password, without changing their Jellyfin/Seerr identity.

## 3. Operator handoff

- [x] 3.1 Document membership, POSIX enrollment, credential boundaries, later MFA migration, verified registry release selection, native disposable Docker prerequisites and rollback; regenerate manifests and documentation with no drift and pass focused checks after binding the actual verified release.
- [ ] 3.2 After explicit consumer merge/authentication rollout approval, accept live household sign-in from a real media client and Seerr; publish Seerr only after that acceptance. The owner's port-forward Seerr sign-in using a Jellyfin account is accepted separately; household directory sign-in and live deployment remain open. Registry delivery requires no manual helper import or host activation.
