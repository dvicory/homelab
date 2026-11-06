{
  config,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  identityPhase = cluster.settings.kubernetes.services.identity.phase;
  seerrPhase = cluster.settings.kubernetes.services.seerr.phase;
  homarrPhase = cluster.settings.kubernetes.services.homarr.phase;
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
        - **Homarr publication phase:** `${homarrPhase}`

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

        Host deployment with deploy-rs `--test` changes the system profile and
        running configuration, but not the boot-loader selection. Automatic
        rollback requires the previous generation's `deploy-rs-activate` hook;
        a plain NixOS profile needs a wrapper around its exact existing system first.

        On an x86 Linux checkout, run `nix run path:.#stock-go-audit` to audit
        the selected Incus daemon/client and Tailscale multicall ELF without
        contacting their daemons. It checks compiled Go symbols, compiler and
        linked module versions; application versions come from evaluated Nix.
        It does not audit C libraries or replace application security review.

        `nix flake update nixpkgs --flake path:.` advances the ordinary fleet
        channel, including the kernel and K3s. Review retained source patches
        and vendor hashes against the selected releases. The Tailscale release
        override rejects newer upstream versions rather than downgrading them.
        The upgrade fixtures pin the former production package set separately;
        they must not follow the candidate root.

        Tailscale retains the `compress` fix for
        [GO-2026-6865](https://vuln.go.dev/ID/GO-2026-6865): control-map zstd
        decoding imports the affected Huffman/FSE decoder. The packaged Linux
        daemon/CLI and auxiliary commands do not import deprecated OpenPGP
        ([GO-2026-5932](https://vuln.go.dev/ID/GO-2026-5932)) or `x/net/html`
        ([GO-2026-6860](https://vuln.go.dev/ID/GO-2026-6860),
        [GO-2026-6866](https://vuln.go.dev/ID/GO-2026-6866)); a module-wide
        advisory match alone is not a reason to patch unrelated packages.
        Incus uses the ordinary supported release and its dependencies, with
        only the adjacent/empty ID-map correction and local completion fix.

        Incus has a 330-second graceful shutdown budget. Before restarting it,
        retain a stopped full-state backup and each
        external storage pool; a profile rollback cannot undo database changes.

        CrowdSec uses the native directory module and 1.8.1 package from the
        pinned CrowdSec component source, not the historical flat fork module.
        The native module owns the manual's reset section; deleting its data
        directories is destructive recovery, not a migration step.
        Keep `/persist/crowdsec/data` intact: it holds SQLite decisions, local
        API credentials, online API credentials and console sharing state.
        Generated console defaults initialize missing state without replacing
        operator sharing choices; other configuration remains declarative.
        The enrollment key remains an agenix runtime secret, and registration
        keeps its existing setup ownership and sandbox. The bouncer key under
        `/var/lib/crowdsec-firewall-bouncer-register` is not newly persisted;
        native registration must reconcile its loss after an ephemeral-root boot.

        Before an upgrade, stop the engine, setup, bouncer and registration
        units and retain a consistent copy of the whole persistent CrowdSec
        directory and current bouncer registration directory. Run
        `nix build .#checks.x86_64-linux.crowdsec-upgrade` on an authorized KVM
        test host: it activates the actual old 1.8.0 and new 1.8.1 aspects,
        cold-boots both with retained state, verifies credentials, decisions
        and packet enforcement, and attempts old-binary rollback against
        new-touched state. This fixture uses the candidate root package set
        for both generations; it is not a complete historical host upgrade.
        It does not enroll production console/CAPI identities or prove
        compatibility with every live database. Retain the stopped-state
        backup even if this bounded rollback fixture passes.

        ## Declared routes

        | Service | Exposure | Canonical URL | Secondary URL | Backend | Auth |
        | --- | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" routeRows}

        `admin` requires Gateway administrator sign-in; `native` uses the
        application's own sign-in.

        Public edges publish only `public` routes. The `idm` canonical hostname
        remains the identity issuer across direct and secondary-edge access;
        failover changes DNS, not the issuer or certificate identity.

        ${requestsRouteNote}The `home` route is omitted from Gateway and edges until
        Homarr is `ready` and identity is `normal`. Complete private onboarding
        and audience checks in [the Homarr runbook](operations/homarr.md)
        before publishing it.

        For `direct` ingress, point each hostname at the host's LAN or Tailscale
        address. TCP 443 forwards to the guest's NodePort. For `trustedEdges`,
        point DNS at the edge.

        The shared direct listener also serves `private` routes. Do not forward
        it to the Internet expecting the exposure label or missing DNS records
        to protect those routes. Plan public ingress with an explicit private
        access path: trusted-edge mode admits only declared edge peers at the
        origin, while public edges omit private routes.

        Incus UI/API TCP 8443 is open only on the declared Tailscale interface,
        subject to tailnet access policy. It is closed on LAN and compute-guest
        interfaces. Management-LAN SSH TCP 22 remains independent: SSH to the
        host and use its local Incus socket without the UI or identity service.

        Service aspects publish full NixOS configuration fragments through
        `den.quirks.firewall`; the globally included collector merges them.
        Payloads include `networking.firewall`, not bare port sets. Compute
        bridge DNS/DHCP and source-scoped metrics stay service-owned. Tailscale
        transport UDP 41641 stays open, but its interface is not blanket-trusted.
        Linux PeerAPI is intercepted in userspace before host INPUT; no ephemeral
        PeerAPI ports are opened. Ad hoc Tailnet bridge DNS, metrics or discovery
        consumers have not been established and must not be assumed to work.

        On an isolated x86_64 Linux/KVM builder, qualify the host policy and the
        unchanged Gateway forwarding path without production credentials:

        ```sh
        nix build path:.#checks.x86_64-linux.compute-contracts path:.#checks.x86_64-linux.compute-ingress-runtime -L
        ```

        This fixture exercises real nftables, trusted TLS UI/API requests and
        management-LAN SSH recovery, not a real Tailscale control-plane login.

        Public edges retain queryless access records with upstream status and
        request ID. journald drops whole nginx request-context error records,
        so their detailed failure causes are lost. Lifecycle diagnostics remain
        available; older retained logs are unchanged.

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
        IFS= read -rsp 'Secret: ' value || exit 1
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

        The enforcer fails closed while it is down with its rules in place:
        every new Pod connection is refused, including allowed ones, until the
        kubelet restarts it. A deliberate stop (deleting or updating the
        DaemonSet) removes its rules first, leaving a gap until rules are
        installed again. Initial startup also has no enforcement guarantee.
        Its readiness probe checks metrics, not packet enforcement.
        Close or qualify these lifecycle gaps before broader public exposure.
        Connection verdict logging is off normally. To investigate a refusal,
        set its `--log-verdicts` argument to `all` in
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
