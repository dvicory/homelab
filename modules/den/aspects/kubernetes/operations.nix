{
  config,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  identityPhase = cluster.settings.kubernetes.services.identity.phase;
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

        ## Deploy configuration

        Argo tracks `${cluster.branch}` from `${cluster.repository}`.
        Publishing to that ref can change running services.

        ```sh
        nix run .#sync-prod-home-manifests
        jj file track generated/manifests/prod-home
        ```

        Commit the generated YAML and check `prod-home-manifests-fresh`
        against that Git revision before syncing.

        ## Declared routes

        | Service | Exposure | Canonical URL | Secondary URL | Backend |
        | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" routeRows}

        Public edges publish only `public` routes. The `idm` canonical hostname
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

        Wait for `retained-storage` to become Healthy before syncing stateful
        applications.

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

        ### Gateway authentication failures

        Start with the Gateway access logs. Find the request by timestamp and
        `request_id`; check `status`, `response_flags`, and `upstream`. Check
        Kanidm's pod health and logs for the same time window.

        Inspect the OAuth success and failure counters on the private
        `/stats/prometheus` endpoint. Counters show OAuth outcomes, not the cause
        of a failure. The declared stack does not configure a scraper or alerts;
        inspect these counters manually.

        Keep the OAuth2 text logger at `critical`. Do not enable verbose OAuth2
        logging or add `%RESPONSE_CODE_DETAILS%` to access logs: both can expose
        credential material. Other warning logs and queryless access logs remain
        available.

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
