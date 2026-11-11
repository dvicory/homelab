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
      displayName = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = "Name people see for the routed application, such as its entry in the identity service's application list.";
      };
      backendPodSelector = mkOption {
        type = types.addCheck (types.attrsOf types.str) (value: value != { });
        description = "Non-empty pod labels selecting the routed backend workload.";
      };
      sameNamespaceIngress = mkOption {
        type = types.bool;
        default = true;
        description = "Whether the Gateway's backend NetworkPolicy also admits every pod in the route's namespace. Set false when the backend's owner admits its in-cluster clients with its own NetworkPolicy; the Gateway policy then admits only the Gateway proxy.";
      };
      manageBackendIngress = mkOption {
        type = types.bool;
        default = true;
        description = "Generate the Gateway's backend NetworkPolicy. Set false when the backend owner supplies all ingress rules, including Gateway admission.";
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
      backendHostname = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "DNS name required when verifying a TLS backend certificate.";
      };
    };
  };
  oidcAppType =
    cluster:
    types.submodule (
      { name, config, ... }:
      {
        options = {
          routeKey = mkOption {
            type = types.str;
            default = name;
          };
          clientID = mkOption {
            type = types.strMatching "[a-z]([a-z0-9-]{0,61}[a-z0-9])?";
            default = name;
          };
          displayName = mkOption {
            type = types.nullOr types.nonEmptyStr;
            default = null;
          };
          eligibleGroup = mkOption {
            type = types.str;
            default = cluster.settings.kubernetes.services.identity.adminGroup;
          };
          scopes = mkOption {
            type = types.listOf types.str;
            default = [
              "openid"
              "profile"
              "email"
            ];
            apply =
              scopes:
              lib.unique (
                lib.optionals (cluster.routes.${config.routeKey}.auth == "admin") [
                  "openid"
                  "profile"
                  "email"
                  "homelab_admin"
                ]
                ++ scopes
              );
            description = "Scopes requested by this app and its Gateway check, when present.";
          };
          callbackPath = mkOption {
            type = types.nullOr (types.strMatching "/.*");
            default = null;
            description = "Native OIDC callback path; null means only the Gateway signs users in.";
          };
          landingPath = mkOption {
            type = types.strMatching "/.*";
            default = "/";
          };
          secret = mkOption {
            type = types.nullOr (
              types.submodule {
                options = {
                  name = mkOption { type = types.str; };
                  key = mkOption { type = types.str; };
                  labels = mkOption {
                    type = types.attrsOf types.str;
                    default = { };
                  };
                };
              }
            );
            default = null;
            description = "Native app's client Secret, published in its route namespace.";
          };
        };
      }
    );
in
{
  options.den.clusters = inputs.gen-schema.lib.mkInstanceRegistry den.schema.cluster {
    description = "Independently reconciled Kubernetes clusters";
  };
  config = {
    den.schema.cluster.isEntity = true;
    den.schema.cluster.imports = [
      ({ config, ... }: {
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
          };
          oidcApps = mkOption {
            type = types.attrsOf (oidcAppType config);
            default = { };
            description = "Declared OIDC consumers. Gateway administrator routes register automatically; native applications opt in.";
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
        config.oidcApps = lib.mapAttrs (name: _: {
          routeKey = lib.mkDefault name;
        }) (lib.filterAttrs (_: route: route.auth == "admin") config.routes);
      })
    ];
  };
}
