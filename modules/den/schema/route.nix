{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  den.lib.homelab.routeOptions = {
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
}
