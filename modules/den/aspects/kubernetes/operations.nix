{
  config,
  lib,
  ...
}:
let
  cluster = config.den.clusters.prod-home;
  compute =
    config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
  routeUrl =
    route: hostname:
    "https://${hostname}${
      if route.pathPrefix == "/" then "" else lib.removeSuffix "/" route.pathPrefix
    }";
  routeAuth =
    route:
    if route.auth == "native" then
      "native application authentication"
    else
      "administrator browser gate; native APIs remain private";
  routeRows = lib.mapAttrsToList (
    name: route:
    let
      primary = routeUrl route (builtins.head route.hostnames);
      backup =
        if builtins.length route.hostnames > 1 then
          routeUrl route (builtins.elemAt route.hostnames 1)
        else
          "not declared";
    in
    "| `${name}` | `${primary}` | `${backup}` | ${routeAuth route} | `${route.namespace}/${route.service}:${toString route.port}` |"
  ) cluster.routes;
  stateRows = lib.mapAttrsToList (
    name: entry:
    let
      access = if entry.readOnly then "read-only" else "writable";
    in
    "| `${name}` | `${entry.path}` | `${entry.guestPath}` | `${toString entry.uid}:${toString entry.gid}` | `${entry.mode}` | ${access} |"
  ) compute.retainedPaths;
  secretGroups = lib.groupBy (
    source:
    let
      entry = compute.runtimeSecrets.${source};
    in
    "${entry.namespace}/${entry.name}"
  ) (builtins.attrNames compute.runtimeSecrets);
  secretRows = lib.mapAttrsToList (
    target: sources:
    let
      refs = map (
        source:
        let
          entry = compute.runtimeSecrets.${source};
        in
        "`${source}` → `${entry.key}`"
      ) sources;
      entry = compute.runtimeSecrets.${builtins.head sources};
    in
    "| `${target}` | ${lib.concatStringsSep ", " refs} | `${entry.type}` |"
  ) secretGroups;
in
{
  perSystem =
    { ... }:
    {
      files.file."docs/operations.md".text = ''
        # Household operations

        > This runbook is generated from the evaluated `prod-home` route, compute and runtime-secret declarations. It is a declaration reference, not a readiness result or production authorization.

        Regenerate the committed copy after changing those declarations:

        ```sh
        nix run .#write-files
        ```

        Run it from the repository root.

        ## Scope

        This runbook covers the declared household guest, Kubernetes bootstrap
        boundary, private service routes, retained state and runtime-secret
        references. It separates guest lifecycle, static application delivery,
        normal reconciliation and recovery. The tables below are generated from
        Nix declarations; they do not inspect a live host or cluster.

        **Stack:** `${cluster.environment}` / `prod-home` on `${compute.instance}`
        (`${cluster.hostName}`), with Gateway API through private NodePort
        `${toString cluster.ingress.nodePort}`.

        Application-owned users, first-run owners, passkeys, libraries, media,
        requests, history, dashboards and other records not named by a
        declaration remain outside Nix ownership. Changes to Nix-managed fields
        may be repaired by reconciliation.

        Nothing here authorizes production deployment, destructive replacement,
        credential creation, DNS/router changes or backup scheduling.

        ## Prerequisites

        Before a mutating operation, obtain separate authorization for the
        target environment and confirm the selected immutable flake revision.

        - Review this file and the matching guest descriptor at
          `/etc/homelab/compute.json`.
        - Run `compute-guest` only as root on the physical Linux Incus host. It
          uses the local Incus socket and checks the declared project, profile,
          identity, ID range and required mounted host paths.
        - Keep runtime credentials in the existing agenix/rekey flow. The host
          bootstrap path expects staged files and never generates replacement
          identities.
        - Use a fresh kubeconfig for the selected guest. After guest
          replacement, the old CA and client identity are stale.
        - Select a private management path. The routes in this document do not
          prove reachable edges, certificates, DNS, router forwarding or login
          success.
        - Run recovery only with a protected recovery destination, a matching
          descriptor and the exact packaged inventory. Keep recovery output and
          staged credentials outside Git and the Nix store.

        ## Declared access and routes

        These addresses come from evaluated route declarations. The first
        hostname is primary; the second is the declared backup address. Backup
        access, canonical identity failover and DNS changes require separate
        operation and verification.

        | Service | Primary | Backup | Authentication | Declared backend |
        | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" routeRows}

        `native` routes retain application-native authentication for supported
        clients. `admin` routes use an administrator browser gate while native
        API access remains private. Neither label proves a deployed TLS
        certificate or successful login. The declared trusted proxy CIDRs are
        `${builtins.toJSON cluster.ingress.trustedProxyCIDRs}`.

        ## Declared retained state

        The table is the evaluated compute attachment interface. Host paths are
        owned by the host declaration; guest paths are the paths mounted into
        the unprivileged guest. A retained directory is not an independent
        backup.

        | Retained key | Host path | Guest path | Guest UID:GID | Mode | Access |
        | --- | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" stateRows}

        Jellyfin's legacy media export is a separate read-only attachment. It
        is not part of the retained state table or the household recovery set.
        The `retained-local` capability for ordinary Helm PVCs is documented in
        the [retained-storage notes](../modules/den/aspects/kubernetes/services/retained-storage.md).

        ## Runtime-secret references

        These rows contain references only. No plaintext value is rendered.
        Agenix source files are materialized on the host and delivered to the
        declared Kubernetes Secret keys before their consumers start. Never
        copy secret values into Git, manifests, images or this document.

        | Kubernetes Secret | Agenix source → key | Type |
        | --- | --- | --- |
        ${lib.concatStringsSep "\n" secretRows}

        ## Deploy

        Guest lifecycle and application delivery are separate. The lifecycle
        command accepts `inspect`, `create` and `replace`; `replace` deletes an
        existing guest only after its explicit confirmation.

        ```sh
        compute-guest inspect
        compute-guest create --bundle BUNDLE
        compute-guest replace --bundle BUNDLE --confirm ${compute.instance}
        ```

        Use `create` only when the declared guest is absent. Use `replace` only
        when the destructive operation and retained-data prerequisites have
        been authorized. `BUNDLE` must be an immutable guest bundle accepted by
        the command; do not substitute a mutable checkout.

        For an existing Running guest, the host wrapper performs the
        non-destructive adoption and static delivery checks:

        ```sh
        household-bootstrap-host /etc/homelab/compute.json --confirm ${compute.instance}
        ```

        It verifies the target guest, fresh kubeconfig, declared node placement,
        absent Argo Applications, staged runtime credentials and the pinned
        provisioning image before mutation. It does not create or delete
        guests, deploy the host OS, publish Git or enable Argo.

        The wrapper applies static namespaces, runtime Secrets and workload
        resources without live Git or pruning. Normal Argo reconciliation is a
        separate, explicit handoff after static delivery and native first-run
        enrollment. Do not use environment-wide pruning or manual scale/copy
        operations as a substitute.

        ## Verify

        Run these commands with an explicitly selected `KUBECONFIG`:

        ```sh
        household-bootstrap --status
        household-bootstrap --check-ready
        ```

        `--status` reports declared controllers and bootstrap Jobs without
        mutation. `--check-ready` waits for the declared node, controllers and
        persistent bootstrap Jobs. It does not prove application acceptance,
        native first-run enrollment, authenticated clients, provider delivery,
        GPU/transcoding behavior or backup success.

        Inspect each service through its supported private route or native API.
        Confirm that managed routes, mounts and Secret references match the
        generated tables. Verify service connections against the selected
        service declarations, and that application-owned records remain
        present after a restart or reconciliation. Do not record a successful
        apply as readiness.

        Complete each service's native first-enrollment prerequisites before
        expecting its configuration Jobs to succeed. Keep service-specific
        requirements with the service declaration. Escrow generated credentials
        through agenix/rekey and never put them in this runbook.

        ## Failure handling

        Static bootstrap refuses to mutate when it cannot inspect Argo ownership,
        when Argo Applications already exist, when the target guest or node does
        not match, or when staged runtime credentials are missing. Fix the
        prerequisite and start a new explicit operation.

        If a declared bootstrap hook Job is terminal `Failed`, and no Argo
        Applications are present, retry only eligible declared hooks:

        ```sh
        household-bootstrap --retry-jobs
        ```

        Active, missing, unknown and non-terminal Jobs are refused. TTL-managed
        Job completion is not retained as evidence. A failed guest lifecycle
        operation leaves retained inputs in place and stops the guest when
        possible; inspect the reported layer before retrying.

        A failed recovery operation leaves the guest and reconcilers stopped.
        Inspect its journal and staged/displaced paths, correct the cause, and
        do not resume blindly. There is no automatic rollback for a partial
        restore.

        ## Recovery limits

        The packaged recovery interface is:

        ```sh
        household-recovery export|restore|resume DESCRIPTOR POINT METRICS_DIRECTORY
        household-recovery --help
        ```

        It is an investigation interface, not a routine backup recipe. Its
        whole-stack export/restore procedure remains unverified and does not
        establish guest-loss recovery, application-consistent capture or
        production readiness. Follow the packaged guidance only when
        investigating an explicitly authorized operation.

        A recovery point contains only the declared retained set. Host identity,
        runtime credentials, read-only media, external providers and any
        undeclared application data need separate protection and reconstruction.
        Same-host retained directories and exports do not survive loss or
        corruption of that host and are not independent backups. Copy a complete
        trusted point and its pinned inputs to a separately protected destination
        only under the backup policy approved for the environment.

        ## Remaining gates

        The declarations and commands above do not establish physical mount,
        encryption, capacity, subordinate-ID or GPU evidence; production
        credentials, DNS/router/provider changes; authenticated primary/backup
        client access; routine capture/restore/resume results; independent
        off-host backup; or production approval.
      '';
    };
}
