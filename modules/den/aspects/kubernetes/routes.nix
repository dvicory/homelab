{ den, ... }:
{
  den.schema.cluster.includes = [ den.aspects.kubernetes.routes ];
  den.aspects.kubernetes.routes.route-metadata =
    { cluster, lib, ... }:
    {
      options.routes = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule ../../schema/_route.nix);
        default = { };
        description = "Service backend defaults merged with explicit site routes and overrides.";
      };
      config.routes = cluster.routes;
    };
}
