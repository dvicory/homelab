{
  lib,
  inputs,
  den,
  ...
}:
let
  inherit (lib) mkOption types;
  settingsType = import ./_settings-type.nix { inherit lib den; };
  routeType = types.submodule {
    freeformType = types.attrsOf types.anything;
    options = lib.getAttrs [ "hostnames" "auth" "exposure" ] den.lib.homelab.routeOptions;
  };
in
{
  options.den.clusters = inputs.gen-schema.lib.mkInstanceRegistry den.schema.cluster {
    description = "Independently reconciled Kubernetes clusters";
  };
  config = {
    den.schema.cluster.isEntity = true;
    den.schema.cluster.imports = [
      {
        options = {
          environment = mkOption { type = types.str; };
          domain = mkOption {
            type = types.str;
            description = "Primary DNS zone the cluster's routes render under.";
          };
          backupDomain = mkOption {
            type = types.str;
            description = "Backup DNS zone serving the cluster's routes during failover.";
          };
          hostSystem = mkOption {
            type = types.str;
            description = "System key identifying the physical host/toolchain that owns compute, storage lifecycle, guest tooling, and cluster API input. It does not describe Kubernetes node architectures, renderer independence, or workload image selection.";
          };
          hostName = mkOption {
            type = types.str;
            description = "Host entity owning this cluster's physical compute environment. It identifies where the Incus guest and its storage live; it is not a Kubernetes scheduling boundary and does not itself encode node or workload architecture.";
          };
          kubeVersion = mkOption {
            type = types.str;
            description = "Kubernetes API/tooling version used when rendering and validating manifests. It does not identify a Nix builder or physical machine.";
          };
          k8sVersion = mkOption { type = types.str; };
          repository = mkOption {
            type = types.str;
            description = "Git repository containing the generated production manifest tree reconciled by Argo CD.";
          };
          branch = mkOption {
            type = types.str;
            description = "Git ref or branch containing the generated production manifests Argo CD tracks.";
          };
          ingress = mkOption {
            type = types.submodule {
              options = {
                nodePort = mkOption {
                  type = types.port;
                  default = 30443;
                };
                mode = mkOption {
                  type = types.enum [
                    "direct"
                    "trustedEdges"
                  ];
                };
                trustedProxyCIDRs = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                };
              };
            };
            default = { };
          };
          routes = mkOption {
            type = types.attrsOf routeType;
            default = { };
            description = "Explicit site routes and overrides. Selected service aspects supply backend defaults; route-metadata validates the complete records.";
          };
          settings =
            (mkOption {
              type = settingsType;
              default = { };
              description = "Typed per-aspect cluster settings";
            })
            // {
              identity = false;
            };
        };
      }
    ];
  };
}
