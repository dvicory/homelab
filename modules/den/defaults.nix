{ den, lib, ... }:
{
  den.reservedKeys = [ "settings" ];

  den.default.includes = [
    den.batteries.define-user
    den.batteries.hostname
    den.batteries.inputs'
    den.batteries.self'
  ];

  den.schema.host.includes = [
    den.aspects.core.nix
    den.aspects.core.nix.stateVersion
    den.aspects.core.localization.time
    den.aspects.core.security.sudo
    den.aspects.core.users.shell
    den.aspects.core.users.home-manager
    den.aspects.core.users.root-user
    den.aspects.core.users.deterministic-uids
    den.aspects.networking.default
    den.aspects.core.network.firewall-collector
    den.aspects.core.secrets.collector
  ];

  den.schema.user.includes = [
    den.aspects.core.users.resolved-user-emitter

    (den.lib.policy.mkPolicy "user-aspect-auto-include" (
      { host, user, ... }:
      lib.optional (den.aspects ? ${host.name} && den.aspects.${host.name} ? ${user.name}) (
        den.lib.policy.include den.aspects.${host.name}.${user.name}
      )
    ))
  ];
}
