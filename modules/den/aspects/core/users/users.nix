# users — enriches NixOS user accounts from den's user entity data.
#
# Parametric aspect: takes { host, user } and emits NixOS config for
# SSH keys, system groups, password files.
#
# Included via den.schema.user.includes so it fires for every resolved user.
{
  lib,
  self,
  config,
  ...
}:
let
  userEnrich =
    { host, user }:
    let
      inherit (user) userName;
      # POSIX group membership is resolved by the gen-scope ACL graph
      # (config.fleet.acl): transitive closure of the user's registry groups
      # over the den.groups membership graph, filtered to posix-scoped groups.
      aclUser = config.fleet.acl.get "host:${host.name}" "resolveUser" userName;
      uid = user.system.uid or null;
      gid = if user.system.gid or null != null then user.system.gid else uid;
      subUidStart = if uid != null then 100000 + ((uid - 1000) * 65536) else null;

      passwordPath = self + "/.secrets/users/${userName}/user-${userName}-password.age";
      materializeSecrets = host.settings.core.users.secrets.enable or true;
      hasPasswordFile = materializeSecrets && builtins.pathExists passwordPath;
    in
    {
      name = "user-enrich/${userName}@${host.name}";

      nixos =
        { ... }:
        {
          users.deterministicIds.${userName} = lib.optionalAttrs (uid != null) {
            inherit uid gid;
            subUidRanges = lib.optional (subUidStart != null) {
              startUid = subUidStart;
              count = 65536;
            };
            subGidRanges = lib.optional (subUidStart != null) {
              startGid = subUidStart;
              count = 65536;
            };
          };

          users.groups.${userName} = lib.optionalAttrs (gid != null) { inherit gid; };

          users.users.${userName} = {
            openssh.authorizedKeys.keys = map (k: k.key) (user.identity.sshKeys or [ ]);
            extraGroups = aclUser.systemGroups or [ ];
            isNormalUser = true;
            home = "/home/${userName}";
            useDefaultShell = user.system.useDefaultShell or true;
            description = lib.mkDefault (user.identity.displayName or "");
            linger = user.system.linger or false;
          }
          // lib.optionalAttrs (uid != null) { inherit uid; }
          // lib.optionalAttrs (gid != null) { group = userName; }
          // lib.optionalAttrs hasPasswordFile {
            hashedPasswordFile = "/run/agenix/user-${userName}-password";
          };

        }
        // lib.optionalAttrs hasPasswordFile {
          age.secrets."user-${userName}-password".rekeyFile = passwordPath;
        };
    };
in
{
  # Wire into user schema includes — fires for every resolved user
  den.schema.user.includes = [ userEnrich ];

  # Host-level mutableUsers setting
  den.aspects.core.users = {
    settings.secrets.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Deliver per-user private secrets on this host.";
    };
    nixos = {
      users.mutableUsers = false;
    };
  };
}
