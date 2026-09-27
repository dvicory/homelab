{
  config,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  identityPhase = cluster.settings.kubernetes.services.identity.phase;
  jellyfinAdministrator = cluster.settings.kubernetes.services.jellyfin.administrator;
  seerrPhase = cluster.settings.kubernetes.services.seerr.phase;
  computeInstance =
    config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute.instance;
  retainedPaths =
    config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute.retainedPaths;
  runtimeSecrets = config.flake.clusterResources.prod-home.runtimeSecrets;
  routeRows = lib.mapAttrsToList (
    name: route:
    let
      url =
        hostname:
        "https://${hostname}${
          lib.optionalString (route.pathPrefix != "/") (lib.removeSuffix "/" route.pathPrefix)
        }";
      secondary =
        if builtins.length route.hostnames > 1 then
          url (builtins.elemAt route.hostnames 1)
        else
          "not declared";
    in
    "| `${name}` | `${route.exposure}` | `${url (builtins.head route.hostnames)}` | `${secondary}` | `${route.namespace}/${route.service}:${toString route.port}` |"
  ) cluster.routes;
  stateRows = lib.mapAttrsToList (
    name: entry:
    let
      access = if entry.readOnly then "read-only" else "writable";
    in
    "| `${name}` | `${entry.path}` | `${entry.guestPath}` | `${toString entry.uid}:${toString entry.gid}` | `${entry.mode}` | ${access} |"
  ) retainedPaths;
  secretGroups = lib.groupBy (
    source:
    let
      entry = runtimeSecrets.${source};
    in
    "${entry.namespace}/${entry.name}"
  ) (builtins.attrNames runtimeSecrets);
  secretRows = lib.mapAttrsToList (
    target: sources:
    let
      refs = map (source: "`${source}` → `${runtimeSecrets.${source}.key}`") sources;
      entry = runtimeSecrets.${builtins.head sources};
    in
    "| `${target}` | ${lib.concatStringsSep ", " refs} | `${entry.type}` |"
  ) secretGroups;
in
{
  perSystem =
    { ... }:
    {
      files.file."docs/operations.md".text = ''
        <!-- provenance: generated from evaluated Den/Nix declarations by modules/den/aspects/kubernetes/operations.nix; keep the committed copy in sync. -->
        # Household operations

        ## Current stack

        - **Environment:** `${cluster.environment}`
        - **Cluster:** `prod-home`
        - **Host:** `${cluster.hostName}` (`${cluster.hostSystem}`)
        - **Compute guest:** `${computeInstance}`
        - **Ingress:** `${cluster.ingress.mode}` on NodePort `${toString cluster.ingress.nodePort}`
        - **Identity phase:** `${identityPhase}`
        - **Seerr publication phase:** `${seerrPhase}`

        ## Deployment flow

        ```text
        Nix/Den -> rendered manifests -> pull-request review ->
        merge tracked deployment ref -> Argo reconciliation
        ```

        The host bootstrap hands the replacement guest to Argo through the
        canonical root Application. Argo then reconciles the tracked deployment
        ref.

        Once this production path is active, merging generated manifests to
        the tracked ref changes production desired state.

        ## Declared routes

        | Service | Exposure | Canonical URL | Secondary URL | Backend |
        | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" routeRows}

        Public edges publish only `public` routes. The `requests` route is
        declared public but is omitted from Gateway and edge configuration
        while Seerr remains in the `initial` phase. The `idm` canonical hostname
        remains the identity issuer across direct and secondary-edge access;
        failover changes DNS, not the issuer or certificate identity.

        In `direct` ingress mode every declared hostname must resolve to an
        address that reaches the physical host — its LAN uplink for LAN
        clients or its Tailscale address for tailnet clients. The host DNATs
        TCP 443 to the compute guest's NodePort without terminating TLS or
        rewriting the client source, so the guest sees the real peer address.
        In `trustedEdges` mode this forward does not exist and reachability is
        the edge's responsibility.

        ## Kanidm bootstrap

        The checked-in `initial` phase keeps the identity route private and
        omits the provisioning credential, Job, and administrator policy.

        Certificates are issued in-cluster by cert-manager through the
        `letsencrypt-prod` ClusterIssuer (Let's Encrypt production, Cloudflare
        DNS-01). The operator prerequisite is the Cloudflare DNS-edit token
        `cert-manager--cloudflare-api-token--api-token` runtime secret;
        `gateway/gateway-tls` and `identity/kanidm-tls` are Certificate
        resources. Check issuance with `kubectl get certificate -A` and note
        the shared Let's Encrypt rate limits.

        1. Through an authorized private interactive `kubectl exec` session,
           run Kanidm `recover-account` for the stock accounts. Immediately
           escrow or encrypt the output; do not copy it into ordinary files.
        2. Encrypt the `idm_admin` credential with agenix/rekey and commit
           `provisioning`. Wait for the identity Application's publication RBAC
           and PostSync provisioning Job to succeed. Administrator routes stay
           absent while the Job creates the named people and client.
        3. Enroll durable human authentication for those people and verify
           native login over the private canonical identity route.
        4. Commit `normal`; wait for the provisioning Job to grant administrator
           membership. Argo then publishes each administrator route together
           with its policy, ordered before the route.

        Never persist plaintext recovery output in Git, generated files, CI,
        service logs, durable agent transcripts, or ordinary workspace files.

        The retained `identity-kanidm` path and Kanidm's native online-export
        capability are facts for a future Preserve integration. This change
        defines no capture schedule, retention, target, adapter, recovery point,
        or restore policy.

        ## Retained state

        | Retained key | Host path | Guest path | Guest UID:GID | Mode | Access |
        | --- | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" stateRows}

        A retained path is not a backup. Incus propagates host mounts one way;
        after restoring a source, recreate affected pods to refresh child
        mounts.

        ## Jellyfin storage and startup

        The stable compute attachment is `/srv/media`; its replaceable merged
        filesystem is `/srv/media/data`. Jellyfin consumes only the semantic
        `/srv/media/data/library` directory, mounted read-only as `/media`.
        `/config` is the statically bound retained volume. `/cache` is a
        disposable 4 GiB `emptyDir` under a 5 GiB container ephemeral-storage
        limit.

        Before deployment, encrypt and rekey a strong, unique password for
        Jellyfin administrator `${jellyfinAdministrator}` as
        `jellyfin--jellyfin-admin--password` for `${computeInstance}`. Use the existing
        password instead if restoring already initialized state; this secret
        does not reset it. Missing input fails closed. The patched
        initContainer creates the initial administrator through its internal
        `SetupServer`. No stock-runtime backend is externally routable until
        provisioning succeeds. The subsequent one-shot Jellarr Job owns the
        `Movies` library at `/media/movies`, the `Shows` library at
        `/media/tv`, and selected supported API settings.

        ## Seerr first-owner boundary

        The checked-in `initial` phase starts Seerr privately. After Jellyfin's
        patched initializer and Jellarr Job succeed, the media-configuration
        PostSync Job uses Jellyfin's owned administrator Secret once to claim
        Seerr's distinguished owner. It selects and synchronizes the `Movies`
        library, then installs the standard Radarr and Sonarr connections.
        The declared `media/media-runtime` `SEERR_API_KEY` is used for subsequent
        reconciliation; it cannot authorize the pre-owner API.

        Verify the Seerr Job succeeded, `/settings/public` reports
        `initialized=true`, the `Movies` library remains enabled, and both
        standard Arr servers have their intended profiles. Only then commit
        `settings.kubernetes.services.seerr.phase = "ready"` and let Argo
        publish the native-auth `requests` route. Never switch to `ready`
        before first-owner initialization: the fresh setup page is claimable.
        Configarr and Seerr perform immediate Git reconciliation and separate
        six-hour repair runs; an unhealthy dependency must be repaired before
        publishing Seerr.

        ## Runtime-secret references

        This table contains references only. Never put plaintext Secret values
        in Git, the Nix store, manifests, images, or this document. Each source
        is either operator-supplied through agenix (`agenix edit`/rekey under
        `.secrets/hosts/`) or a generated value produced by `agenix generate`.
        `gateway-tls` and `kanidm-tls` are not listed: cert-manager issues them
        in the cluster from its Cloudflare DNS-01 ClusterIssuer.

        | Kubernetes Secret | Source -> key | Type |
        | --- | --- | --- |
        ${lib.concatStringsSep "\n" secretRows}

        ## Certificates

        cert-manager issues TLS in the cluster: the `letsencrypt-prod`
        ClusterIssuer does Cloudflare DNS-01 (the `cloudflare-api-token` runtime
        Secret) and writes `gateway-tls` in `gateway` and `kanidm-tls` in
        `identity`. Check issuance inside the guest:

        ```sh
        kubectl get clusterissuer letsencrypt-prod
        kubectl get certificate -A
        ```

        A `READY=False` Certificate's `status.conditions` and
        `kubectl -n cert-manager describe challenge` name the failing step.
        Let's Encrypt production limits repeated identical issuances, so a
        flapping Certificate or weekly guest rebuilds will eventually stall
        new issuance until the window clears.

        ## Lifecycle and bootstrap

        Two artifacts are built from the same checkout of this repository on the
        physical Linux Incus host:

        ```sh
        nix build .#nixosConfigurations.${computeInstance}.config.system.build.computeBundle --out-link guest-bundle
        nix build .#packages.x86_64-linux.household-bootstrap-bundle --out-link bootstrap-bundle
        ```

        `guest-bundle` is the guest image (`metadata.tar.xz`, `rootfs.tar.xz`,
        `system`). `bootstrap-bundle` holds the bootstrap commands with their
        pinned manifests (`bin/household-bootstrap-host`,
        `bin/household-bootstrap`, `manifests/`).

        Run `compute-guest` as root:

        ```sh
        compute-guest adopt
        compute-guest inspect
        compute-guest create --bundle ./guest-bundle
        compute-guest replace --bundle ./guest-bundle --confirm ${computeInstance}
        ```

        `replace` is destructive and requires the exact
        `--confirm ${computeInstance}` acknowledgement.

        For a newly created or replacement Running guest before Argo handoff, run
        as root:

        ```sh
        ./bootstrap-bundle/bin/household-bootstrap-host /etc/homelab/compute.json --confirm ${computeInstance}
        ```

        The host command validates the descriptor, guest, kubeconfig, node
        placement, Argo state, and runtime-secret inventory before it mutates
        namespaces, stages runtime Secrets, seeds Argo's restricted `default`
        project, and applies the canonical root Application.

        ## Verify

        With `KUBECONFIG` selecting the guest's cluster:

        ```sh
        ./bootstrap-bundle/bin/household-bootstrap --status
        ./bootstrap-bundle/bin/household-bootstrap --check-ready
        ```

        `--status` reports the declared Argo controllers and bootstrap Jobs.
        `--check-ready` waits for the replacement node, Argo seed, and declared
        bootstrap Jobs. Service acceptance additionally requires the route,
        certificate, origin trust, and native-login checks owned by this edge
        cut.

        ## Failure and retry

        Fix the reported preflight prerequisite and start a new explicit
        operation. Retry only declared terminal failed hook Jobs:

        ```sh
        ./bootstrap-bundle/bin/household-bootstrap --retry-jobs
        ```

        Missing, active, unknown, or non-terminal Jobs are refused.

        ## Compute-loss recovery

        ```text
        replace guest (attach retained state) -> verify retained mounts ->
        stage runtime Secrets -> seed Argo -> apply root Application ->
        Argo reconciles Git
        ```

        Replace the disposable guest root, K3s datastore, cache, and object
        identities from declared inputs; never restore the old K3s datastore
        over the replacement.

      '';
    };
}
