## 2. Host and guest configuration

- [x] 2.1 Add the Den compute entity and NixOS-owned Incus envelope using
  existing aspect, settings, persistence, and access-resolution conventions.
  Supply native preseed with Nix attrsets; instance operations only verify its
  resources. Declare isolated non-root host ID translation, resource limits,
  private networking, retained directories, and node-essential startup
  prerequisites. Application-only storage must not gate node boot. Verify
  exact evaluated option leaves, host-specific inclusion, safe expanded
  settings, and a conflict check before first preseed adoption.
- [x] 2.2 Add the standalone secret-free guest image and K3s configuration
  against the unchanged pinned nixpkgs: current user-namespace runtime
  settings, overlayfs snapshotter, bundled networking, and disabled unused
  ingress/dynamic storage components. Verify generated guest configuration
  parses under the pinned tools and that the guest artifact contains no
  runtime private key. Record builder limitations rather than claiming an
  unbuilt image passed.
- [x] 2.3 Integrate host-managed runtime guest identity using existing
  secretRequests/agenix-rekey conventions, atomic staging, translated
  ownership, read-only attachment, and separate pinned host/guest SSH trust.
  Support re-staging and explicit identity rotation under the lifecycle lock.
  Missing or mismatched private/public identity blocks the identity-dependent
  path without substituting a generated key.

## 3. Downstream workload integration

The later workload cuts own application manifests, service-specific routes,
retained claim bindings, and application runtime acceptance. They must consume
this compute boundary without widening its isolation or lifecycle interface.

- [ ] 3.1 Add workload resources and independently pinned application artifacts
  without coupling their release to the guest operating-system generation.
- [ ] 3.2 Use stable Nix-delivered manifest names and one Argo reconciliation
  owner with retained-resource protection; do not introduce a second inventory
  or pruning controller.
- [ ] 3.3 Add operator-private workload access and any service-specific
  network policy without public listeners or broad trusted interfaces.

## 4. Lifecycle and recovery tooling

- [x] 4.1 Provide thin application-neutral inspection, creation, and
  acknowledged replacement operations over Incus. Preserve host serialization,
  structured absence handling, effective-envelope verification, declared
  retained-path and identity preflight, artifact acquisition before
  destruction, and bounded management readiness. Use standard NixOS commands
  and explicit SSH trust rather than a deployment frontend or workload
  framework.

## 5. Local integration and operator evidence

- [x] 5.1 Run focused local evaluation/build checks for the host, guest,
  platform images, and lifecycle packages. Verify unrelated fleet outputs still
  evaluate without changing the lockfile. Report evaluated derivations
  separately from built outputs.

## 6. Runtime acceptance and production gates

The platform revision does not claim target-runtime replacement acceptance.
Production inspection, credential provisioning, deployment, and destructive
operations remain separately authorized. A later workload cut must supply the
representative service operation and replacement evidence before claiming
application recovery.

- [ ] 6.1 Obtain permission for read-only host inspection, then check actual
  encryption/mounts, free space, kernel/cgroups, Incus resources,
  subordinate-ID collisions, route collisions, and independent management
  access. Stop before any required storage-permission or isolation expansion.
- [ ] 6.2 Obtain permission for secret provisioning and host/guest deployment;
  check conflicts before first preseed adoption, create only approved
  resources, and verify effective unprivileged maps and actual network
  restrictions. Prove node boot with application-only storage unavailable.
- [ ] 6.3 Execute the later cut's target-runtime replacement scenario on an
  appropriate Linux/KVM runner. Record artifact preparation, guest creation,
  registry pulls, first reconciliation, source-loss behavior, replacement,
  and second reconciliation. Only successful target evidence closes that
  later acceptance gate.
- [ ] 6.4 Before routine replacement begins, add an operator-invoked retirement
  flow for superseded compute bundle GC roots and matching Incus images.
  Require an explicit target, preserve a verified rollback point, refuse
  resources referenced by an instance, and check host capacity before deletion.
