{ lib, inputs, den, ... }:
let
  inherit (lib) mkOption types;
  settingsType = import ./_settings-type.nix { inherit lib den; };
  routeType = types.submodule {
    options = {
      namespace = mkOption { type = types.str; };
      service = mkOption { type = types.str; };
      port = mkOption { type = types.port; };
      hostnames = mkOption { type = types.listOf types.str; };
      pathPrefix = mkOption { type = types.strMatching "/.*"; default = "/"; };
      auth = mkOption { type = types.enum [ "native" "admin" ]; };
      backendTLS = mkOption { type = types.bool; default = false; };
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
          nodeName = mkOption { type = types.str; };
          storageRoot = mkOption { type = types.strMatching "/.+"; };
          domain = mkOption { type = types.str; };
          backupDomain = mkOption { type = types.str; };
          kubeVersion = mkOption { type = types.str; };
          k8sVersion = mkOption { type = types.str; };
          repository = mkOption { type = types.str; };
          branch = mkOption { type = types.str; };
          ingress = mkOption {
            type = types.submodule {
              options = {
                nodePort = mkOption { type = types.port; default = 30443; };
                trustedProxyCIDRs = mkOption { type = types.listOf types.str; default = [ ]; };
              };
            };
            default = { };
          };
          routes = mkOption { type = types.attrsOf routeType; default = { }; };
          settings = (mkOption {
            type = settingsType;
            default = { };
            description = "Typed per-aspect cluster settings";
          }) // { identity = false; };
        };
      }
    ];
  };
}
