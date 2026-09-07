{ config, lib, ... }:
let
  system = "x86_64-linux";
  compute = config.den.hosts.${system}.hvn-hyp1.settings.virtualization.compute;
  cluster = config.den.clusters.prod-home;
  retained = lib.mapAttrsToList (name: entry:
    "${name}: ${entry.path} -> ${entry.guestPath}; guest ${toString entry.uid}:${toString entry.gid}, mode ${entry.mode}, readOnly=${lib.boolToString entry.readOnly}"
  ) compute.retainedPaths;
  secrets = lib.mapAttrsToList (source: entry:
    "${source}.age -> ${entry.namespace}/${entry.name}:${entry.key} (${entry.type})"
  ) compute.runtimeSecrets;
  routes = lib.mapAttrsToList (name: route:
    "${name}: ${lib.concatMapStringsSep ", " (hostname: "https://${hostname}${route.pathPrefix}") route.hostnames}; auth=${route.auth}; backend=${route.namespace}/${route.service}:${toString route.port}"
  ) cluster.routes;
in
{
  # Only declaration leaves enter this text. Do not reference self.packages or
  # rendered derivations here: reading instructions on Darwin must not build Linux.
  perSystem = { pkgs, ... }: {
    packages.household-operations = pkgs.writeText "household-operations.txt" ''
      Household operations — declaration inventory, not deployment authorization

      Authority: evaluated host hvn-hyp1 and cluster prod-home at the selected
      immutable source. Nix owns declared settings and connections; UI changes to
      managed fields may be overwritten. Undeclared users, history and content
      remain application-owned. Rendered resources establish desired state, not
      runtime readiness. Active OpenSpec proposals are not current contracts;
      see docs/architecture/decisions/0003-independent-ingress-and-canonical-identity.md
      and 0004-declarative-application-configuration.md for rationale.

      SELECT AND RETAIN (repository root; FLAKE is an approved immutable reference)
      Production artifacts target ${system}, regardless of workstation architecture.
      Use an authorized Linux builder; guidance itself can be built on Darwin.
        OS=$(nix build --no-link --print-out-paths "$FLAKE#nixosConfigurations.${compute.instance}.config.system.build.computeBundle")
        ENVIRONMENT=$(nix build --no-link --print-out-paths "$FLAKE#nixidyEnvs.${system}.prod-home.environmentPackage")
        ARGO_BOOTSTRAP=$(nix build --no-link --print-out-paths "$FLAKE#nixidyEnvs.${system}.prod-home.bootstrapPackage")
        BOOTSTRAP=$(nix build --no-link --print-out-paths "$FLAKE#packages.${system}.household-bootstrap")
        BUNDLE=$(nix build --no-link --print-out-paths "$FLAKE#packages.${system}.household-bootstrap-bundle")
        RECOVERY=$(nix build --no-link --print-out-paths "$FLAKE#packages.${system}.household-recovery")
        JELLYFIN_IMAGE=$(nix build --no-link --print-out-paths "$FLAKE#packages.${system}.jellyfin-image")
      Retain the immutable source/lock, these closures, matching recovery points,
      runtime credentials and independent management identity outside the guest.
      Same-host copies are recovery points, NOT independent backups.
      Copy selected closures with nix copy to the separately verified host; never
      accept incident-time host-key discovery as verification or forward an agent.

      COMPUTE AND APPLICATION DELIVERY ARE INDEPENDENT
      Host descriptor: /etc/homelab/compute.json
      Project=${compute.project}; instance=${compute.instance}; address=${compute.address}
      On the authorized Incus host, with OS copied into its Nix store:
        compute-guest inspect
        compute-guest create --bundle "$OS"
      Replacement (separate deletion authorization):
        compute-guest replace --bundle "$OS" --confirm ${lib.escapeShellArg compute.instance}
      These generic commands preserve declared external inputs; they do not
      deliver applications. OS activation uses the selected bundle's system
      closure and the existing host management path, separately from Argo changes.
      Serialize OS activation, replacement and identity staging with maintenance;
      do not nest compute-guest inside its own lifecycle lock.

      FRESH CLUSTER, THEN NORMAL ARGO OWNERSHIP
      Read "$BUNDLE/operations.txt" for native identity-image import and bootstrap
      sequencing. images/kanidm-provision.tar is an uncompressed native-importable
      archive: import it before provisioning Jobs, after every guest replacement,
      and when that image changes. Missing image must not trigger registry fallback.
      Stage all declared credentials through agenix/rekey, not Git or Nix strings.
      With KUBECONFIG explicitly targeting the fresh guest:
        "$BOOTSTRAP/bin/household-bootstrap" --fresh-cluster
      This is non-pruning, no-live-Git bootstrap and refuses existing Argo
      Applications. Successful apply is not readiness or completed first setup.
      Publish the selected rendered directories to the reviewed Git source, then:
        kubectl apply -f "$ARGO_BOOTSTRAP/"
      Normal reconciliation belongs to Argo, not a second static lifecycle. Source:
        ${cluster.repository} (branch ${cluster.branch})
      Nixidy application directories are symlinks: any authorized selected-directory
      apply uses a trailing slash, e.g. kubectl apply -f "$ENVIRONMENT/$APPLICATION/".
      Do not run environment-wide prune. Retire ordinary resources through their
      Argo owner; namespaces/PVs/PVCs require a separate retained-data decision.

      FIRST SETUP IS NOT A REPLACEMENT PROCEDURE
      On a genuinely empty Kanidm database, use the pinned server's native
      recover-account operation for admin and idm_admin, escrow both generated
      recovery passwords securely, and stage only idm_admin's recovery password
      as identity/kanidm-provision:idm-admin-password through agenix/rekey.
      Do not reset either account on replacement. User passkey enrollment remains
      interactive; administrator membership is granted only after policy succeeds.
      Bootstrap gap: all-at-once static apply does not perform native account
      recovery or provide an interactive escrow/staging sequence. Provisioning may
      wait/fail until this prerequisite is completed; consult the pinned server
      CLI and actual runtime state, not an invented automatic password command.
      Complete Jellyfin's native first-run wizard via its declared native route.
      Stage that administrator's matching JELLYFIN_OWNER_USERNAME/PASSWORD/EMAIL
      for media configuration; retained Seerr requires its existing owner (id 1).
      Seerr setup uses its native Jellyfin login API. Never repeat either first-run
      wizard over retained state. Verify authenticated library access, playback
      and recorded user state rather than merely a listening port.

      DESIGNATED RETAINED PATHS (host -> guest; IDs are guest IDs)
      ${lib.concatStringsSep "\n      " retained}
      Host ID translation base=${toString compute.idmapBase}; size=${toString compute.idmapSize}.
      Recovery destination: ${compute.recoveryPath}
      Separate SSH identity: ${compute.identityPath}
      Separate legacy media: ${compute.mediaSource} -> ${compute.mediaPath} (read-only export).
      Keep original media and runtime credentials separately; guest root, K3s
      database and regenerable caches are not substitutes for these inputs.

      RUNTIME SECRET NAMES ONLY (agenix source -> Kubernetes Secret:key)
      Source directory: .secrets/hosts/${compute.instance}/
      ${lib.concatStringsSep "\n      " secrets}
      No values are included here. Keep encryption/rekey identities, declared
      runtime_host_key.age/public-key pairing and secret files outside the guest.
      Missing credentials must fail closed; never generate replacement identities
      to unblock a restore or copy plaintext credentials into the Nix store.

      QUIESCED EXPORT / RESTORE / EXPLICIT RESUME
      Read household-recovery's own CLI guidance for exact validation, writer
      ordering, native PostgreSQL backup, displaced state and failure handling:
        "$RECOVERY/bin/household-recovery" --help
      On the separately authorized Linux Incus host, choose POINT explicitly and
      METRICS_DIRECTORY as an existing directory scraped by node exporter:
        "$RECOVERY/bin/household-recovery" export /etc/homelab/compute.json "$POINT" "$METRICS_DIRECTORY"
      Inspect the complete point and POINT.session/journal before explicit resume:
        "$RECOVERY/bin/household-recovery" resume /etc/homelab/compute.json "$POINT" "$METRICS_DIRECTORY"
      A restore is a separate, destructive decision, using the matching selected
      recovery package and a trusted complete point, with its own session as the
      CLI guidance requires; do not treat these commands as a single script:
        "$RECOVERY/bin/household-recovery" restore /etc/homelab/compute.json "$POINT" "$METRICS_DIRECTORY"
        "$RECOVERY/bin/household-recovery" resume /etc/homelab/compute.json "$POINT" "$METRICS_DIRECTORY"
      Neither export nor restore automatically resumes writers. Failed/partial
      operations stay stopped: inspect journal/staging/displaced state, never
      blindly resume. Do not concurrently operate Argo, Incus, OS delivery or
      compute-guest. Loss of the entire guest/cluster is a separate reconstruction
      case: this CLI's live-cluster quiesce/session path is not proof of empty-host
      restore; retain matching artifacts and require a demonstrated procedure.

      DECLARED CLIENT ROUTES
      ${lib.concatStringsSep "\n      " routes}
      Private gateway NodePort=${toString cluster.ingress.nodePort}.
      Trusted proxy CIDRs: ${builtins.toJSON cluster.ingress.trustedProxyCIDRs}
      Empty trusted peers are not a configured production ingress. Independently
      deploy remote/home edges only after private-origin reachability, narrow peer
      trust, valid primary/backup TLS, forwarding-header and bypass checks pass.
      Backup native-client URLs do not prove fresh OIDC login. Canonical identity
      remains https://${builtins.head cluster.routes.idm.hostnames}; prepare and
      authorize same-name identity DNS failover as well as application DNS, account
      for TTL/caches, and verify callbacks/passkeys with actual clients. Neither
      entrance survives loss of the home connection or application origin.

      UNPASSED GATES / EVIDENCE BOUNDARY
      This file reports evaluated declarations only, not full platform acceptance.
      Record native Darwin, disposable Linux and production evidence separately.
      Production inspection/deployment, real credentials, DNS/router/tailnet changes,
      provider/indexer connections and notification delivery require authorization.
      Verify physical encryption/mounts/capacity, Incus preseed conflicts, subordinate
      IDs, routes, read-only legacy media and independent host recovery before use.
      GPU/transcoding and target ${system} compatibility remain hardware gates.
      Off-host backup/restore and client-dependent identity flows need their own
      evidence. Preserve legacy Hermes until its separate cutover is authorized.
    '';
  };
}
