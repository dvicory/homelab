{
  config,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  identityPhase = cluster.settings.kubernetes.services.identity.phase;
  seerrPhase = cluster.settings.kubernetes.services.seerr.phase;
  requestsRouteNote = lib.optionalString (seerrPhase == "initial") ''
    The `requests` route is declared public but is omitted from Gateway and
    edge configuration while Seerr remains in the `initial` phase.

  '';
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
    "| `${name}` | `${route.exposure}` | `${url (builtins.head route.hostnames)}` | `${secondary}` | `${route.namespace}/${route.service}:${toString route.port}` | `${route.auth}` |"
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
  runbooks = lib.attrNames (
    lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".md" name) (
      builtins.readDir ../../../../docs/operations
    )
  );
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

        | Service | Exposure | Canonical URL | Secondary URL | Backend | Auth |
        | --- | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" routeRows}

        `admin` requires Gateway administrator sign-in; `native` uses the
        application's own sign-in.

        Public edges publish only `public` routes. The `idm` canonical hostname
        remains the identity issuer across direct and secondary-edge access;
        failover changes DNS, not the issuer or certificate identity.

        ${requestsRouteNote}For `direct` ingress, point each hostname at the host's LAN or Tailscale
        address. TCP 443 forwards to the guest's NodePort. For `trustedEdges`,
        point DNS at the edge.

        ## Retained state

        | Retained key | Host path | Guest path | Guest UID:GID | Mode | Access |
        | --- | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" stateRows}

        A retained path is not a backup. Incus propagates host mounts one way;
        after restoring a source, recreate affected pods to refresh child
        mounts.

        Wait for `retained-storage` to become Healthy before syncing stateful
        applications. Its `retained-directories` hook creates the declared
        directories and refuses, rather than creating substitute data, when the
        persistent state root is missing. The hook survives pruning and
        Application deletion.

        ## Runtime-secret references

        Manage operator secrets with `agenix edit` and rekey under
        `.secrets/hosts/`; use `agenix generate` for generated secrets.
        Never put plaintext credentials or recovery output in Git, Nix
        outputs, images, documentation, or logs.

        For a single-line credential that must not end in a newline, run this
        in Bash at the repository root, replacing `<source>` with its table
        entry. Input is hidden and kept out of command arguments; the temporary
        editor contains only commands, never the credential:

        ```sh
        (
          set +x
          umask 077
          editor=$(mktemp)
          trap 'rm -f "$editor"' EXIT
          cat >"$editor" <<'BASH'
        read -rsp 'Secret: ' value || exit 1
        printf '\n'
        printf '%s' "$value" > "$1"
        BASH
          EDITOR="bash $editor" agenix edit ".secrets/hosts/${computeInstance}/<source>.age"
        )
        ```

        Track new encrypted sources with `jj file track` before running
        `agenix rekey`, so the Git-backed flake includes their conditional
        declarations. Track any new encrypted host rekeys too, then commit
        the sources and rekeys before following the deployment procedure.
        Do not commit plaintext or invent replacement values for unavailable secrets.

        | Kubernetes Secret | Source -> key | Type |
        | --- | --- | --- |
        ${lib.concatStringsSep "\n" secretRows}

        ## Certificates

        cert-manager issues TLS in the cluster: the `letsencrypt-prod`
        ClusterIssuer does Cloudflare DNS-01 (the `cloudflare-api-token` runtime
        Secret) and writes `gateway-tls` in `gateway` and `kanidm-tls` in
        `identity`.
        The token must cover each certificate zone, including the canonical
        identity zone; see [identity operations](operations/identity.md#canonical-name-and-certificate-renewal).
        Gateway reads that identity certificate through its name-scoped grant;
        application wildcard certificates remain separate.

        Check issuance inside the guest:

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

        The guest bundle keeps the native LXC `metadata.tar.xz`, `rootfs.tar.xz`
        and `system` interface. Rootfs compression uses pixz level 0 to reduce
        preparation time at the cost of a larger archive; the decompressed
        guest payload and metadata are unchanged.
        The production guest remains an unprivileged container. Do not substitute
        a qcow2 disk or change its Incus instance type for this bundle; changing
        backends requires a separately validated retained-data handoff.

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

        ### NetworkPolicy enforcement after a reboot

        kube-network-policies (`kube-system/kube-network-policies`) enforces
        NetworkPolicy; K3s's embedded controller is disabled. After every host
        reboot, guest restart or guest replacement, check on the host, as root:

        ```sh
        incus --project compute exec ${computeInstance} -- \
          k3s kubectl -n kube-system rollout status daemonset/kube-network-policies --timeout=2m
        incus --project compute exec ${computeInstance} -- \
          journalctl -u k3s -b --no-pager -o cat |
          grep -E 'Failed to execute iptables-restore|Failed to run iptables-restore|nftables sync failed|Message too long'
        ```

        The first command must report the DaemonSet rolled out. The second
        must print nothing; a line means kube-proxy (in either its iptables or
        its nftables mode) or another component failed to update the guest's
        firewall.

        The enforcer fails closed: while it is down with its rules in place,
        every new Pod connection is refused, including allowed ones, until the
        kubelet restarts it. A deliberate stop (deleting or updating the
        DaemonSet) removes its rules first, so Pods are unprotected until the
        new Pod is ready. To log each connection's verdict while
        investigating a refusal, raise its `--v` argument to 2 in
        `kubernetes.services.network-policy`; Argo reverts edits made only in
        the cluster.

        ### Remove kube-router's leftover rules

        When K3s stops running its embedded controller, its iptables rules and
        ipsets stay behind (k3s-io/k3s#7244) and keep applying stale
        decisions to whatever Pod now holds an old address. From the
        repository checkout on the host, as root:

        ```sh
        incus --project compute exec ${computeInstance} -- \
          sh -s < modules/den/aspects/kubernetes/_kube-router-cleanup.sh
        ```

        It must end with `kube-router rules left: 0`. It is safe to repeat.

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

        ## Service runbooks

        ${lib.concatMapStringsSep "\n" (
          name: "- [`${lib.removeSuffix ".md" name}`](operations/${name})"
        ) runbooks}

      '';
    };
}
