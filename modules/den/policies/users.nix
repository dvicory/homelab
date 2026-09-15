# User registry and access-driven user resolution policies.
#
# Users are resolved onto hosts by the same transitive ACL result that supplies
# their resulting POSIX groups.
{
  lib,
  den,
  config,
  ...
}:
let
  inherit (den.lib.policy) resolve;
  inherit (lib) mkOption types;

  registry = config.den.users.registry;

  matchRegistryUsers =
    hostName:
    lib.filter (name: (config.fleet.acl.get "host:${hostName}" "resolveUser" name).enable) (
      builtins.attrNames registry
    );

  # Registry entry type — mirrors the standard user entity shape so that
  # pipeline self-provide, define-user, and other batteries find the
  # expected attributes (userName, aspect, classes).
  registryUserType = types.submodule (
    { name, config, ... }:
    {
      freeformType = types.attrsOf types.anything;
      imports = [ den.schema.user ];
      config._module.args.user = config;
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "User name (from attrset key)";
        };
        userName = mkOption {
          type = types.str;
          default = name;
          description = "User account name";
        };
        classes = mkOption {
          type = types.listOf types.str;
          default = [ "user" ];
          description = "Home management nix classes";
        };
        aspect = mkOption {
          type = types.raw;
          default = den.aspects.${name} or { };
          defaultText = "den.aspects.<name>";
          description = "Aspect that configures this user";
        };
        groups = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Direct group memberships; fleet ACL resolution adds transitive memberships";
        };
      };
    }
  );
in
{
  # User registry option.
  options.den.users.registry = mkOption {
    type = types.attrsOf registryUserType;
    default = { };
    description = "User registry for host access and account resolution";
  };

  config = {
    # Promote users to real entities.
    den.schema.user.isEntity = true;
    den.schema.user.classes = lib.mkDefault [ "homeManager" ];

    # Host account existence and emitted POSIX groups both use fleet.acl's
    # transitive resolver, so direct and inherited machine grants cannot diverge.
    den.policies.env-users =
      { host, ... }:
      map (name: resolve.to "user" { user = registry.${name}; }) (matchRegistryUsers host.name);
  };
}
