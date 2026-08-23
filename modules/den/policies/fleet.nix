# Fleet topology policies.
#
# Wires the scope tree: flake -> fleet -> environment -> hosts.
# Environment membership derived from den.schema.host.environment.
{
  lib,
  den,
  config,
  ...
}:
let
  inherit (den.lib.policy) resolve;

  inherit (config.den) environments;
in
{
  # flake -> fleet: single fleet entity (fires at flake scope).
  # secretsConfig propagates through scope inheritance to all descendants.
  den.policies.to-fleet = _: [
    (resolve.to "fleet" {
      fleet = {
        name = "fleet";
      };
      inherit (config.den) secretsConfig;
    })
  ];

  # fleet -> environments: fan out per registered environment.
  den.policies.fleet-to-envs =
    _:
    lib.mapAttrsToList (
      _: env:
      resolve.to "environment" {
        environment = env;
      }
    ) environments;

  # environment -> hosts: walk den.hosts whose environment matches.
  den.policies.env-to-hosts =
    { environment, ... }:
    lib.concatMap (
      system:
      lib.concatMap (
        hostName:
        let
          hostCfg = den.hosts.${system}.${hostName};
        in
        lib.optionals (hostCfg.environment == environment.name && hostCfg.intoAttr != [ ]) [
          (resolve.to "host" { host = hostCfg; })
          (den.lib.policy.instantiate hostCfg)
        ]
      ) (builtins.attrNames (den.hosts.${system} or { }))
    ) (builtins.attrNames (den.hosts or { }));

  # environment -> homes: instantiate standalone den.homes whose bound host
  # is in this environment. Mirrors env-to-hosts.
  den.policies.env-to-homes =
    { environment, ... }:
    let
      envHostNames = lib.concatMap (
        system:
        lib.concatMap (
          hostName:
          let hostCfg = den.hosts.${system}.${hostName} or { };
          in lib.optional (hostCfg.environment == environment.name) hostName
        ) (builtins.attrNames (den.hosts.${system} or { }))
      ) (builtins.attrNames (den.hosts or { }));

      envHostSet = builtins.listToAttrs (map (n: { name = n; value = true; }) envHostNames);

      envHomes = lib.concatMap (
        system:
        lib.filter (home: home.hostName != null && envHostSet ? ${home.hostName})
          (builtins.attrValues (den.homes.${system} or { }))
      ) (builtins.attrNames (den.homes or { }));
    in
    lib.concatMap (
      home:
      lib.optionals (home.intoAttr != [ ]) [
        (resolve.to "home" {
          inherit home;
          account = config.den.users.registry.${home.userName} or null;
        })
        (den.lib.policy.instantiate home)
      ]
    ) envHomes;

  # Schema wiring.
  den.schema.flake.includes = [ den.policies.to-fleet ];
  den.schema.fleet.includes = [ den.policies.fleet-to-envs ];
  den.schema.environment.includes = [
    den.policies.env-to-hosts
    den.policies.env-to-homes
  ];

  # Fleet handles host instantiation -- exclude default walking policies.
  den.schema.flake-system.excludes = [
    den.policies.system-to-os-outputs
    den.policies.system-to-hm-outputs
  ];

  # Exclude den's built-in host-to-users (fleet user policies replace it).
  den.schema.host.excludes = [ den.policies.host-to-users ];
}
