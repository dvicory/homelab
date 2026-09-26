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

  builderConfig = self.nixosConfigurations.builder.config;
  builderUsers = builderConfig.users.users;
  hvnConfig = self.nixosConfigurations.hvn-hyp1.config;
  hvnUsers = hvnConfig.users.users;
  darwinConfig = self.darwinConfigurations.daniels-2021-mbp.config;
  darwinUsers = darwinConfig.home-manager.users;
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
      !workstationUser.enable && workstationOnWorkstation.enable && !serverOnWorkstation.enable;
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

  environmentAssertions.timezone-projection =
    builderConfig.time.timeZone == config.den.environments.dev.timezone
    && hvnConfig.time.timeZone == config.den.environments.prod.timezone;

  integrationAssertions.secret-requests-resolve =
    let
      requests = attrNames hvnConfig.secretRequests;
    in
    requests != [ ] && builtins.all (name: hasAttr name hvnConfig.age.secrets) requests;
  # A secret change must never restart a unit that holds storage open:
  # restarting it closes or unmounts a live volume. A new unlock key applies
  # on the next unlock instead.
  integrationAssertions.secret-restarts-spare-storage =
    let
      isStorageUnit =
        unit:
        lib.hasPrefix "gocryptfs-" unit
        || lib.hasPrefix "systemd-cryptsetup@" unit
        || lib.hasPrefix "mergerfs-" unit
        || lib.hasSuffix ".mount" unit;
      restartTargets = lib.concatMap (
        host:
        lib.concatMap (req: req.restartUnits) (builtins.attrValues (host.config.secretRequests or { }))
      ) (builtins.attrValues self.nixosConfigurations);
    in
    !(builtins.any isStorageUnit restartTargets);
  integrationAssertions.darwin-account =
    hasAttr "daniel.vicory" darwinUsers
    && !(hasAttr "daniel" darwinUsers)
    && darwinUsers."daniel.vicory".home.homeDirectory == "/Users/daniel.vicory"
    && darwinConfig.age.secrets."user-identity-daniel".owner == "daniel.vicory"
    && darwinConfig.age.secrets."user-identity-daniel".group == "staff";
  integrationAssertions.daniel-shell =
    hvnConfig.users.users.daniel.shell == hvnConfig.programs.fish.package
    && darwinConfig.users.users."daniel.vicory".shell == darwinConfig.programs.fish.package;
  integrationAssertions.darwin-maintenance =
    darwinConfig.nix.gc.automatic
    && darwinConfig.nix.gc.options == "--delete-older-than 30d"
    && darwinUsers."daniel.vicory".home.stateVersion == "25.11";
  integrationAssertions.hermes-secure-terminal =
    hasAttr "hermes-qa-broker" hvnConfig.systemd.services
    && hasAttr "hermes-qa-broker-execution" hvnConfig.systemd.sockets
    && hasAttr "hermes-qa-broker-control" hvnConfig.systemd.sockets
    && !(hasAttr "hermes-prod-broker" hvnConfig.systemd.services);

  failures = attrNames (
    lib.filterAttrs (_: passed: !passed) (
      accessAssertions // environmentAssertions // integrationAssertions
    )
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
