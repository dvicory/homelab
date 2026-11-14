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

        ## Software inventories and updates

        `Software vulnerability inventory` collects declared host/compute roots,
        exported packages and OCI images on source changes and twice weekly.
        Host and image declarations are desired state; package exports are
        exported state. Building or resolving an artifact does not make it deployed.
        No live fleet dashboard or deployment discovery is installed by this workflow.

        Download `security-plan` and the matching per-target inventory/report artifacts
        from the workflow run. The plan lists unsupported targets and discovery
        failures. Collection, provenance or report errors fail their jobs; a missing
        report is not a successful scan. Artifacts are retained for 90 days.

        Native inventories retain the original SBOM, closure/patch evidence and
        opaque-path ledger. `native-identity.cdx.json` is a derived companion:
        its `nix_drv` PURL qualifier carries the actual Nix derivation path without
        changing package versions or CPEs. `native-identity.provenance.json` binds
        the original, derived inventory and identity changes. Keep originals;
        normalized dashboard exports need not preserve all source evidence.

        Saved inventories can be rescanned with current advisory data without
        rebuilding software or querying hosts/registries. Reuse verifies source,
        producer, target identity and file hashes.
        Reused image inventories keep the original software evidence; their
        Homelab references come from the current plan, not the original scan.
        Automated consumers use `.github/security_artifacts.py` to verify the trusted
        producer and sealed files. Its `discover_plan(..., run_id=...)` recovery
        option selects an exact run without bypassing source, event or artifact checks.
        Scanner configuration and ignore files from the repository are not loaded. Raw portable reports
        remain downloadable; this workflow does not submit Code Scanning alerts.

        Version/CPE matches are candidates, not Nix backport or runtime-reachability
        decisions. Missing versions/CPEs and opaque paths remain unknown coverage.
        Referenced lockfiles and fixtures do not prove their software is deployed.
        Complete artifact collection is not complete vulnerability coverage.

        `Dependency update PRs` prepares ordinary Nix input and declared-source
        updates with read authority. Candidate evaluation and generation run in a
        disposable checkout/private store; package builds use unprivileged Nix
        build users. A separate publisher accepts validated regular-file patches
        with validated source revisions and exact updater-branch leases, not
        executable candidate code. It never merges or activates software.
        Unsupported source policies and incomplete coupled
        releases remain explicit refusals, not guessed updates.
        Publishers recheck main immediately before pushing and refuse already-stale
        candidates. Main can still advance after that check; review against current
        main before merging.

        Read-only preparation does not require PR-creation permission. Publishing
        requires GitHub's Settings → Actions → General → Workflow permissions →
        Allow GitHub Actions to create and approve pull requests. Keep default
        token permissions read-only and write authority confined to publisher jobs;
        successful default-token publication still needs qualification.

        Approve pending CI runs or dispatch Nix CI on an updater branch before
        reviewing a merge. Merging generated manifests to main can roll out
        services through Argo; host activation remains separate.

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

        ## Private Dependency-Track (available, not enrolled)

        No fleet selects this service or its ingestor. Production enrollment
        requires placement, storage, recovery and NetworkPolicy admission.
        The declared resource limits are not full-feed capacity qualification.

        Select `kubernetes.services.dependency-track` with `privateAccess=true`,
        and select `workloads.dependency-track-sync.compute-guest` on the
        corresponding compute guest. Set its `apiUrl` to
        `http://127.0.0.1:1022`. Set the service's `automaticInventory=true` when
        its operator-issued ingestion credentials are available. Keep the
        workload's `onCalendar=null` until bootstrap and mirror admission finish.
        Selecting the service alone enables no import schedule.

        Private HTTPS uses the existing internal Gateway and native Kanidm
        login for the existing administrators group. The UI and API hostnames
        come from their Den routes. Routes remain absent until
        `databasePhase=restore` and `identity.phase=normal`. The public OIDC
        client has no client secret. Its provisioning Job requires a verified,
        main-published `kanidm-provision` release with public-client support;
        a PR image or an incomplete release receipt is not a substitute.

        The separate root access-policy service requires the old default
        password to fail and verifies the recovery administrator and allowed
        group mapping before admitting each API Pod UID to Service endpoints.
        The importer never receives that password or a kubeconfig.
        Readiness controls routing, not direct Pod-IP access: bootstrap must
        take place on a controlled, trusted node and network.
        Group removal takes effect at a new login; it does not instantly revoke
        existing browser sessions.

        For controlled bootstrap or recovery, use the existing authenticated
        Kubernetes administrative path with loopback-only forwards:

        ```sh
        kubectl -n dependency-track port-forward --address 127.0.0.1 service/dependency-track-api 18080:8080
        kubectl -n dependency-track port-forward --address 127.0.0.1 service/dependency-track-frontend 18081:8080
        ```

        Normal operation uses private HTTPS, not these forwards. The separate
        loopback-only profile defaults its browser API URL to
        `http://127.0.0.1:18080`; both forwards must be on the browser's machine.

        The task scheduler and telemetry default off. In the private profile,
        only explicit bootstrap may rotate the stock password; restore must
        authenticate the retained recovery administrator instead.
        Before accepting inventories, disable remote analyzers, package
        repositories, KEV and EPSS through the native administrative interface.
        API egress allows PostgreSQL, cluster DNS and
        public HTTPS; the stock outbound policy further restricts HTTP
        destinations to `storage.googleapis.com` and `nvd.nist.gov`.

        Apply the packaged, source-owned advisory policy using an existing
        mode-0600 administrative session file, not the ingestion key:

        ```sh
        dependency-track-sync configure --api-url http://127.0.0.1:18080 --admin-session-file "$DT_ADMIN_SESSION_FILE"
        ```

        This idempotent command disables GitHub and JVN sources, enables
        official NVD and OSV Go data, and verifies configuration readback.
        It neither grants credentials nor starts an import. Other language
        ecosystems remain outside this profile.
        Admit the first mirrors separately. Select `initialMirror = true`
        with scheduled refresh off to serialize mirror work and pause
        analysis/import workers. Drain existing work first; a disabled worker
        does not cancel queued activity. Keep a consistent DB/API-keyset
        recovery point. A failed or uncertain NVD import requires recovery
        disposition before any retry; do not edit upstream watermarks.
        Require each native mirror workflow, including its metrics tail, to
        reach `COMPLETED`. Then leave initial-mirror mode and require
        successful sequential project analyses.
        Refresh the initial portfolio metrics through the supported
        `GET /api/v1/metrics/portfolio/refresh` and require its workflow to
        complete before trusting the first dashboard. Findings may already
        exist while the dashboard still shows stale zeros. Dashboard totals
        deduplicate advisory aliases; raw finding rows need not match them.
        Only after that admission, select `advisoryRefresh = true` with
        `initialMirror = false` for stock scheduled refresh. Activity,
        analysis, reconciliation and artifact-import concurrency are bounded
        separately; portfolio-dispatch concurrency alone is insufficient.
        Do not enable the scheduler before applying and qualifying the policy.
        More sources need separate capacity, destination and freshness checks.

        ### Automatic inventories and retained evidence

        Routine operation requires no `dependency-track-sync sync` command:

        1. GitHub Actions builds or reuses declared software inventories and
           refreshes scanner reports. Downloadable original artifacts remain on
           GitHub for 90 days. They describe public configuration, not observed
           running software.
        2. The compute guest's `dependency-track-sync.service` checks the latest
           completed allowed-event producer on the configured repository/branch.
           It verifies declarations, GitHub artifact digests, sizes and seals
           before importing. Production trusts `dvicory/homelab` branch `main`;
           qualification branches require separate evidence and API state.
        3. The service imports desired hosts and referenced images by default,
           then evaluates supported host inclusion paths from that exact trusted
           source revision. Exported packages remain accounted for but require
           explicit selection. The selected workload defaults to a daily timer;
           `onCalendar=null` leaves an explicitly started oneshot.

        Give its dedicated ingestion team only `VIEW_PORTFOLIO`,
        `PORTFOLIO_MANAGEMENT` and `BOM_UPLOAD`. These are instance-wide stock
        permissions, not per-project isolation. Use a dedicated private instance.
        Enroll its API key and a read-only GitHub acquisition token through the
        existing agenix/runtime-secret flow. The service requests
        `dependency-track--dependency-track-sync--api-key.age` and
        `dependency-track--dependency-track-sync--github-token.age` for the
        compute instance; neither credential is generated.

        Root projects only those two keys from the exact Kubernetes Secret.
        systemd gives non-login UID/GID705 private credential files; the importer
        has no root control files or trusted Nix-daemon access. A fixed root-owned
        loopback broker supplies the API transport without handing out Kubernetes
        credentials. Failed policy admission stops ingestion.

        Original ZIPs, sealed inventories, source receipts, origin reports and
        the single-writer journal stay on the compute guest under
        `/srv/state/dependency-track-evidence`, owned by 705:705. Routine operation
        needs no operator-local build or artifact directory. Dashboard properties
        keep compact run/commit references; full receipts stay in retained evidence.
        A stale source, corrupt cache or failed import preserves the last complete
        snapshot and records failed/unknown coverage. Check the unit journal and
        `dependency-track-sync status --state-dir /srv/state/dependency-track-evidence`
        rather than treating an old dashboard as current.

        Software revisions follow actual Nix derivation/output or image/platform
        identity, not report timestamps. Changed content for the same immutable
        root fails closed. Cached projects must retain expected identity, owner,
        parent and leaf layout before update or retirement. Failed ownership
        checks keep failure status local instead of modifying another collection.
        The UI uses readable Host, Package and Image names; short display
        suffixes do not replace full managed identity checks. Within Nix
        targets, Nix packages lists the derivation-backed package inventory;
        Contents scan lists Trivy's executable metadata, package metadata and
        dependency declarations. Neither view proves software is executing.
        Component Details → Properties exposes the preserved Trivy `PkgType`
        and `Type`: `gobinary`/`rustbinary` are binary-associated metadata,
        `cargo` is a lockfile catalogue, `node-pkg` is package-manifest identity,
        and `python-pkg` is distribution-style metadata. The stock UI has no
        arbitrary-property evidence filter. Do not hide declarations or call
        all contents compiled libraries. The source Application/Library
        classifier does not establish deployment or exposure.

        For supported host inventories, inclusion tracing runs automatically.
        It currently covers `environment.systemPackages` and `systemd.package`,
        not every option, exported package or image. The evaluated derivation
        and output must match the admitted inventory. Component Details →
        Properties shows Homelab inclusion paths; the chain-link menu opens
        pinned source files. Unresolved paths stay unknown. Enrichment keeps the
        original seals and software identities intact.

        Update preparation remains independent of this dashboard. Findings do
        not yet create CVE-driven update PRs, merge updates, activate software or
        establish package affectedness.

        ### Dependency-Track bootstrap, backup and recovery

        The normal `databasePhase=restore` refuses a missing encrypted database
        credential, missing/non-18 PostgreSQL data, or a missing API encryption
        keyset. Only an explicitly admitted empty new service may select
        `bootstrap`; switch back to `restore` after initialization and secret
        generation. Never use bootstrap to repair missing state.

        Bootstrap creates the restricted `dtrack` owner of its dedicated database
        and schema. `postgres` administration uses local Unix-socket peer
        authentication, with no password or TCP access. The API refuses
        elevated role flags or dangerous memberships on bootstrap and restore;
        recover correct roles and object ownership rather than weakening that
        check. Recover the encrypted database and recovery-administrator
        credentials with their matching retained data.

        Retain the three host-owned `dependency-track-postgres` (70:70),
        `dependency-track-api` (1000:0) and `dependency-track-evidence` (705:705)
        directories, their configured encrypted storage, and the original
        agenix database credential. PostgreSQL18 uses
        `/var/lib/postgresql/18/docker`; the stock API key-encryption keyset is
        inside `/data/.dependency-track/keys`. DT-normalized exports are not
        substitutes for sealed originals, companions, provenance or the journal.
        No automatic evidence deletion is configured.

        For a cold backup, first record and hold automated sync for both the
        root `apps` Application and `dependency-track`, as in
        [Homarr recovery](operations/homarr.md#full-portable-capture).
        Stop every ingestor, including its timer. Scale
        both API and PostgreSQL Deployments to zero and wait until all their
        Pods have terminated. Do not copy while a writer remains or Argo can
        restart one. Snapshot/copy all three retained host directories and the
        encrypted secret source, then restore the recorded sync policies and
        ingestion schedule. Restore the directories and encrypted credential
        sources together with their declared numeric ownership and private
        modes on encrypted retained storage before reconstructing disposable
        compute/Kubernetes state. Preserve the API encryption keyset byte-exact:
        an API-key login proves hash authentication, not retained-secret decryption.
        A different valid key with the same IDs can pass initialization.
        Recreate static retained claims against the existing directories;
        do not provision substitute storage or restore an old container cache,
        root filesystem or Kubernetes object UID. Use `restore`, then start
        PostgreSQL before the API. Require native login, root policy admission
        and resumed inventory/provenance coverage. If managed secrets exist,
        exercise a retained secret through its normal consumer as well.
        Backup/restore rehearsal and retention/capacity qualification remain
        rollout gates; no recovery SLA is introduced.

        Images stay digest-bound to the tested stock API/frontend5.2.1 pair
        and PostgreSQL18. Review API/frontend releases together. PostgreSQL
        major or image-variant changes require an explicit migration and
        identity review, never an independent automatic image upgrade.

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
        DaemonSet) removes its rules first, leaving a gap until rules are
        installed again. Its readiness probe checks metrics, not packet
        enforcement. Connection verdict logging is off normally. To investigate
        a refusal, set its `--log-verdicts` argument to `all` in
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
