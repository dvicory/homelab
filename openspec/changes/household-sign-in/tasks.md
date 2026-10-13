## 1. Declaration and ownership

- [ ] 1.1 Declare the LDAPS listener and Service, household group and account policies. Evaluate phases and prove explicit administrator MFA plus operator-owned household membership in the real provisioning run.
- [ ] 1.2 Pin and install the official LDAP plugin after first-start provisioning; reject an incompatible Jellyfin ABI and prove replacement of another plugin version on restart.
- [ ] 1.3 Configure the loaded plugin through Jellarr without installing another plugin or overwriting plugin-owned user links; prove repeat reconciliation and existing local administrator recovery.

## 2. Acceptance

- [ ] 2.1 Exercise the committed images and commands against real Kanidm, Jellyfin and Seerr: household sign-in, outsider/empty/wrong-password refusals, administrator POSIX-password sign-in, membership changes and repeat provisioning.
- [ ] 2.2 Prove certificate verification and Kubernetes NetworkPolicy: only the declared Jellyfin workload reaches LDAPS; an undeclared Pod is refused.
- [ ] 2.3 Prove restart preserves directory user IDs and identity outage refuses directory sign-in while the local administrator still works.
- [ ] 2.4 Prove a later all-persons MFA floor works after enrolling a household user's MFA credential and separate POSIX password, without changing their Jellyfin/Seerr identity.

## 3. Operator handoff

- [ ] 3.1 Document membership, POSIX enrollment, credential boundaries, later MFA migration, image imports and rollback; regenerate manifests and documentation with no drift and pass focused checks.
- [ ] 3.2 After explicit merge approval and owner image imports, accept live household sign-in from a real media client and Seerr; publish Seerr only after that acceptance. Owner port-forward local-administrator sign-in was accepted on 2026-10-13; household/live deployment remains open.
