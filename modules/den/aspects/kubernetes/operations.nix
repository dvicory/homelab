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

        ## Deploy configuration

        Argo tracks `${cluster.branch}` from `${cluster.repository}`.
        Publishing to that ref can change running services.

        ```sh
        nix run .#sync-prod-home-manifests
        jj file track generated/manifests/prod-home
        ```

        Commit the generated YAML and check `prod-home-manifests-fresh`
        against that Git revision before syncing.

        A child Application's `ComparisonError` blocks later parent sync waves,
        even when its existing workloads are Healthy. Inspect the child's
        conditions and repair its source; normal reconciliation resumes when
        the error clears and the child is healthy. This can delay unrelated
        later-wave applications. It does not stop running workloads or pause
        independently syncing child Applications.

        ## Declared routes

        | Service | Exposure | Canonical URL | Secondary URL | Backend |
        | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" routeRows}

        Public edges publish only `public` routes. The `requests` route is
        declared public but is omitted from Gateway and edge configuration
        while Seerr remains in the `initial` phase. The `idm` canonical hostname
        remains the identity issuer across direct and secondary-edge access;
        failover changes DNS, not the issuer or certificate identity.

        For `direct` ingress, point each hostname at the host's LAN or Tailscale
        address. TCP 443 forwards to the guest's NodePort. For `trustedEdges`,
        point DNS at the edge.

        ## Kanidm bootstrap

        Administrator routes remain disabled during `initial` and `provisioning`.
        Confirm TLS certificates are Ready before recovering accounts.

        1. Run Kanidm `recover-account` for the stock accounts through a private
           interactive `kubectl exec` session. Immediately encrypt or escrow
           the output; do not save it in ordinary files.
        2. Encrypt and track the `idm_admin` credential. Select `provisioning`
           before running agenix-rekey. Commit the host-rekeyed ciphertext and
           generated manifests, then activate the host to stage the runtime
           Secret. Wait for the `kanidm-provision` PostSync Job to complete.
        3. Verify native login over the private canonical identity route using
           password-plus-MFA or a passkey. Administrator accounts require MFA.
        4. Select `normal`, wait for provisioning to complete, and verify
           protected administrator access.

        ### Upgrade Kanidm

        Run `kanidmd domain upgrade-check` and take a restorable backup before
        upgrading. Upgrade minor releases sequentially; successful database
        migrations cannot be downgraded. Match the CLI version to the server.

        ## Retained state

        | Retained key | Host path | Guest path | Guest UID:GID | Mode | Access |
        | --- | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" stateRows}

        A retained path is not a backup. Incus propagates host mounts one way;
        after restoring a source, recreate affected pods to refresh child
        mounts.

        The `retained-directories` Sync hook creates declared directories before
        later waves in its own Application. It is not a cross-Application
        declaration barrier: a consumer may be declared while the hook refuses,
        but it cannot start against a missing directory or create substitute data.
        Like the other retained-storage resources, the hook resists pruning and
        Application deletion; `BeforeHookCreation` replaces the Job on the next
        sync without removing retained data.
        Wait for `retained-storage` to become Healthy before syncing stateful
        applications.

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

        ## Media process access and verification

        Arr and SAB retain their private primary identities. Their read-only
        LinuxServer startup hook adds the declared media group to `abc` before
        the daemon starts; Kubernetes supplementary groups alone do not survive
        the image's user switch. Do not relax media directory permissions.
        SAB initialization preserves or seeds its native default `*` category
        before managing `movies` and `tv`, so first-start defaults cannot replace
        those directories.

        `nix build .#checks.x86_64-linux.media-runtime` runs the pinned native
        services and producer jobs in a disposable Docker VM. It checks native
        libraries/profiles/scores, credential handshakes and refusals, repeated
        reconciliation, real daemon access, and preserved unmanaged video bytes.
        Provider APIs redact credentials; successful echoes are not authentication
        proof. This gate does not prove Kubernetes RBAC, Incus mount propagation,
        or the MergerFS/XFS recovery boundary; keep those separate checks.

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

        Manage operator secrets with `agenix edit` and rekey under
        `.secrets/hosts/`; use `agenix generate` for generated secrets.
        Never put plaintext credentials or recovery output in Git, Nix
        outputs, images, documentation, or logs.

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

        For `READY=False`, inspect the Certificate's `status.conditions` and
        run `kubectl -n cert-manager describe challenge`. Avoid repeated
        issuance attempts: Let's Encrypt production rate limits can block
        recovery.

        ## Lifecycle and bootstrap

        Build both bundles from the same commit on the physical Linux Incus host:

        ```sh
        nix build .#nixosConfigurations.${computeInstance}.config.system.build.computeBundle --out-link guest-bundle
        nix build .#packages.x86_64-linux.household-bootstrap-bundle --out-link bootstrap-bundle
        ```

        Run guest lifecycle commands as root.

        Adopt and inspect an existing guest:

        ```sh
        compute-guest adopt
        compute-guest inspect
        ```

        Create a new guest:

        ```sh
        compute-guest create --bundle ./guest-bundle
        ```

        Replace an existing guest (**destructive**):

        ```sh
        compute-guest replace --bundle ./guest-bundle --confirm ${computeInstance}
        ```

        Once the new or replacement guest is Running, bootstrap it as root:

        ```sh
        ./bootstrap-bundle/bin/household-bootstrap-host /etc/homelab/compute.json --confirm ${computeInstance}
        ```

        ## Verify

        With `KUBECONFIG` selecting the guest's cluster:

        ```sh
        ./bootstrap-bundle/bin/household-bootstrap --status
        ./bootstrap-bundle/bin/household-bootstrap --check-ready
        ```

        `--check-ready` covers the node, Argo seed, and bootstrap Jobs.
        Also verify service routes, TLS, and native login.

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
