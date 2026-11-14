# Project the existing Den entities and rendered Gateway objects through files.file.
{
  config,
  lib,
  self,
  ...
}:
let
  hosts = lib.concatLists (
    lib.mapAttrsToList (
      system: byName: lib.mapAttrsToList (name: host: { inherit name system host; }) byName
    ) config.den.hosts
  );
  clusters = config.den.clusters;
  computeFor =
    cluster: config.den.hosts.${cluster.hostSystem}.${cluster.hostName}.settings.virtualization.compute;
  hostLink = name: "[`${name}`](modules/den/hosts/${name}/default.nix)";
  quote = value: "`${value}`";
  fleetRows = map (
    entry:
    let
      parents = lib.filter (cluster: (computeFor cluster).instance == entry.name) (
        lib.attrValues clusters
      );
      addresses = entry.host.ipv4 ++ map (cluster: (computeFor cluster).address) parents;
    in
    "| ${hostLink entry.name} | `${entry.host.environment}` | `${entry.system}` | ${
      if addresses == [ ] then "—" else lib.concatMapStringsSep ", " quote addresses
    } | ${
      if parents == [ ] then
        "—"
      else
        lib.concatMapStringsSep ", " (cluster: hostLink cluster.hostName) parents
    } |"
  ) hosts;
in
{
  perSystem =
    { system, ... }:
    let
      clusterSection =
        name: cluster:
        let
          compute = computeFor cluster;
          rendered = self.nixidyEnvs.${system}.${name}.config;
          # Reuse the same rendered-object projection as monitoring; do not repeat
          # the Gateway's phase/publication conditions here.
          published = map (object: object.metadata.name) (
            lib.filter (object: object.kind == "HTTPRoute") (
              rendered.applications.gateway.objects ++ (rendered.applications.identity-gateway.objects or [ ])
            )
          );
          routeRows = lib.mapAttrsToList (
            key: route:
            let
              emitted = builtins.elem key published;
              url = "https://${builtins.head route.hostnames}${route.pathPrefix}";
              endpoint =
                if emitted then
                  "[`${builtins.head route.hostnames}`](${url})"
                else
                  "`${builtins.head route.hostnames}`";
            in
            "| `${route.namespace}/${route.service}` | ${endpoint} | `${route.exposure}` | ${
              {
                admin-gateway = "Gateway admin";
                app-managed = "Application";
              }
              .${route.auth} or route.auth
            } | ${if emitted then "yes" else "no"} |"
          ) config.flake.clusterRoutes.${name}.routes;
        in
        ''
          ### `${name}`

          - **Kubernetes API:** `${cluster.kubeVersion}`; ingress `${cluster.ingress.mode}` on NodePort `${toString cluster.ingress.nodePort}`.
          - **Persistent state:** `${compute.stateRoot}` on ${hostLink cluster.hostName}, mounted at `${compute.stateGuestPath}` in the guest. [Paths and owners](docs/operations.md#retained-state).
          - **GitOps:** [generated manifests](generated/manifests/${name}/), tracked from `${cluster.branch}` by Argo CD. [Deployment runbook](docs/operations.md#deploy-configuration).

          | Backend | Canonical hostname | Exposure | Route auth | In manifests |
          | --- | --- | --- | --- | --- |
          ${lib.concatStringsSep "\n" routeRows}

          **Route auth:** Gateway admin requires Kanidm administrator sign-in
          in addition to any application checks. Application leaves sign-in
          and access control to the app; it does not imply OIDC.
        '';
    in
    {
      files.file."README.md".text = ''
        <!-- provenance: generated from evaluated Den entities and Nixidy Gateway objects by modules/flake/docs/readme.nix; regenerate with nix run .#write-files. -->
        # homelab

        NixOS homelab and nix-darwin workstation configuration, composed with
        [Den](https://github.com/denful/den) and flake-parts.

        ## Fleet

        | Host | Environment | Platform | IPv4 | Managed guest of |
        | --- | --- | --- | --- | --- |
        ${lib.concatStringsSep "\n" fleetRows}

        ## Services and topology

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList clusterSection clusters)}
        Routes reflect generated manifests, not live health.
        [Route details and publication gates](docs/operations.md#declared-routes) cover secondary hostnames and onboarding.

        ## Operate and recover

        - [Household operations](docs/operations.md): deployment, retained state and runtime secrets.
        - [Identity](docs/operations/identity.md) · [Homarr](docs/operations/homarr.md) · [Media](docs/operations/media.md) · [Jellyfin](docs/operations/jellyfin.md) · [Monitoring](docs/operations/monitoring.md).
        - [Storage layout](docs/storage.md) · [Disk migration](docs/operations/luks-storage-migration.md).

        ## Sources and checks

        - [Cluster and route declarations](modules/den/clusters/home.nix) · [Service implementations](modules/den/aspects/kubernetes/services/) · [Compute lifecycle](modules/den/aspects/virtualization/compute.nix).
        - [CI and local checks](CI.md) · [Regenerate this page](CI.md#regenerate-documentation).
        - [Current contracts](openspec/specs/) · [Architecture decisions](docs/architecture/decisions/).
      '';
    };
}
