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
    options = {
      namespace = mkOption { type = types.str; };
      service = mkOption { type = types.str; };
      backendPodSelector = mkOption {
        type = types.addCheck (types.attrsOf types.str) (value: value != { });
        description = "Non-empty pod labels selecting the routed backend workload.";
      };
      port = mkOption { type = types.port; };
      hostnames = mkOption {
        type = types.addCheck (types.listOf types.str) (
          value: value != [ ] && lib.all (hostname: hostname != "") value
        );
      };
      pathPrefix = mkOption {
        type = types.strMatching "/.*";
        default = "/";
      };
      auth = mkOption {
        type = types.enum [
          "native"
          "admin"
        ];
      };
      exposure = mkOption {
        type = types.enum [
          "private"
          "public"
        ];
      };
      timeouts = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              request = mkOption { type = types.str; };
              backendRequest = mkOption { type = types.str; };
            };
          }
        );
        default = null;
      };
      backendTLS = mkOption {
        type = types.bool;
        default = false;
      };
    };
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
            description = "Approved Git revision whose checked-in production manifests Argo CD reconciles.";
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
