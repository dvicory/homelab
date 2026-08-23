{
  config,
  lib,
  self,
  ...
}:
let
  inherit (builtins) attrNames elem hasAttr;

  acl = config.fleet.acl;
  resolve = groups: acl.get "host:hvn-hyp1" "resolveGroups" groups;

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
  workloadOnBuilder = acl.get "host:builder" "resolveGroups" [ "workload-access" ];

  builderUsers = self.nixosConfigurations.builder.config.users.users;
  hvnConfig = self.nixosConfigurations.hvn-hyp1.config;
  hvnUsers = hvnConfig.users.users;
  hvnRequestNames = attrNames hvnConfig.secretRequests;

  accessAssertions = {
    admin-server = adminServer.enable && elem "wheel" adminServer.systemGroups;
    non-admin-server =
      serverUser.enable
      && !(elem "wheel" serverUser.systemGroups)
      && !(elem "admins" serverUser.systemGroups);
    workstation-denied-on-server = !workstationUser.enable;
    broad-system-access =
      systemUser.enable
      && elem "server-access" systemUser.systemGroups
      && elem "workstation-access" systemUser.systemGroups
      && !(elem "wheel" systemUser.systemGroups);
    admin-does-not-grant-login = !adminOnly.enable && elem "wheel" adminOnly.systemGroups;
    missing-grant-omits-identity = !noGrant.enable;
    host-environment-restrictions = workloadOnServer.enable && !workloadOnBuilder.enable;
    materialized-accounts-match-acl =
      hasAttr "daniel" builderUsers
      && hasAttr "daniel" hvnUsers
      && hasAttr "hermes-qa-runner" hvnUsers
      && hasAttr "hermes-prod-runner" hvnUsers
      && !(hasAttr "hermes-qa-runner" builderUsers)
      && elem "wheel" hvnUsers.daniel.extraGroups;
  };

  integrationAssertions = {
    settings-forward-graph =
      (config.fleet.settings.get "host:hvn-hyp1" "resolvedSettings").core.nix.gc.enable == false;
    secret-requests-resolve =
      builtins.length hvnRequestNames == 14
      && elem "gocryptfs-media1" hvnRequestNames
      && elem "hermes-env" hvnRequestNames
      && elem "tailscale-auth-key" hvnRequestNames
      && builtins.all (name: hasAttr name hvnConfig.age.secrets) hvnRequestNames;
  };

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
