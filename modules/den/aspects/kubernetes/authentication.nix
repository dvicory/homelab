{ den, ... }:
{
  den.quirks.native-oidc.description = "Application-owned OIDC login settings collected from selected service aspects";

  den.schema.cluster.includes = [ den.aspects.kubernetes.authentication ];

  den.aspects.kubernetes.authentication.k8s-manifests =
    {
      cluster,
      routes,
      native-oidc,
      lib,
      ...
    }:
    let
      inherit (lib) mkOption types;
      oidcClientType = types.submodule (
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
                  lib.optionals (routes.${config.routeKey}.auth == "admin-gateway") [
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
      options.oidcClients = mkOption {
        type = types.attrsOf oidcClientType;
        readOnly = true;
        description = "Derived clients from native-oidc service settings and admin-gateway route policies. Configure those inputs, not this view.";
      };
      config.oidcClients = lib.zipAttrsWith (_: lib.mkMerge) (
        [
          (lib.mapAttrs (_: _: { }) (lib.filterAttrs (_: route: route.auth == "admin-gateway") routes))
        ]
        ++ native-oidc
      );
    };
}
