{
  config,
  lib,
  self,
  ...
}:
let
  inherit (builtins) attrNames elem hasAttr;

  acl = config.fleet.acl;
  resolveOn = host: groups: acl.get "host:${host}" "resolveGroups" groups;
  resolve = resolveOn "hvn-hyp1";

  adminServer = resolve [
    "admins"
    "server-access"
  ];
  serverUser = resolve [ "server-access" ];
  workstationUser = resolve [ "workstation-access" ];
  systemUser = resolve [ "system-access" ];
  adminOnly = resolve [ "admins" ];
  noGrant = resolve [ ];
  workloadOnServer = resolve [ "workload-access" ];
  workloadOnBuilder = resolveOn "builder" [ "workload-access" ];
  workstationOnWorkstation = resolveOn "daniels-2021-mbp" [ "workstation-access" ];
  serverOnWorkstation = resolveOn "daniels-2021-mbp" [ "server-access" ];

  builderUsers = self.nixosConfigurations.builder.config.users.users;
  hvnConfig = self.nixosConfigurations.hvn-hyp1.config;
  hvnUsers = hvnConfig.users.users;
  registry = config.den.users.registry;
  registryNames = attrNames registry;
  placementMatches =
    host: users:
    builtins.all (
      name: hasAttr name users == (acl.get "host:${host}" "resolveUser" name).enable
    ) registryNames;

  accessAssertions = {
    admin-server = adminServer.enable && elem "wheel" adminServer.systemGroups;
    non-admin-server =
      serverUser.enable
      && !(elem "wheel" serverUser.systemGroups)
      && !(elem "admins" serverUser.systemGroups);
    narrow-machine-access =
      !workstationUser.enable
      && workstationOnWorkstation.enable
      && !serverOnWorkstation.enable;
    broad-system-access =
      systemUser.enable
      && elem "server-access" systemUser.systemGroups
      && elem "workstation-access" systemUser.systemGroups
      && !(elem "wheel" systemUser.systemGroups);
    admin-does-not-grant-login = !adminOnly.enable && elem "wheel" adminOnly.systemGroups;
    host-environment-restrictions =
      workloadOnServer.enable
      && elem "workload-access" workloadOnServer.systemGroups
      && !(elem "wheel" workloadOnServer.systemGroups)
      && !workloadOnBuilder.enable;
    missing-grant-omits-identity = !noGrant.enable;
    materialized-accounts-match-acl =
      placementMatches "builder" builderUsers
      && placementMatches "hvn-hyp1" hvnUsers
      && builtins.all (
        name:
        let
          isEnabledAdmin =
            elem "admins" (registry.${name}.groups or [ ])
            && (acl.get "host:hvn-hyp1" "resolveUser" name).enable;
        in
        !isEnabledAdmin || elem "wheel" hvnUsers.${name}.extraGroups
      ) registryNames;
  };

  integrationAssertions.secret-requests-resolve =
    let
      requests = attrNames hvnConfig.secretRequests;
    in
    requests != [ ] && builtins.all (name: hasAttr name hvnConfig.age.secrets) requests;

  failures = attrNames (
    lib.filterAttrs (_: passed: !passed) (accessAssertions // integrationAssertions)
  );
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks.den-semantics =
        assert lib.assertMsg (
          failures == [ ]
        ) "Den semantic assertions failed: ${builtins.concatStringsSep ", " failures}";
        pkgs.writeText "den-semantics" "ok\n";
    };
}
