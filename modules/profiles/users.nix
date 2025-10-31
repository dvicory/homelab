{ self, lib, ... }:
{
  config.flake.modules.nixos.profiles-users =
    { config, ... }:
    let
      inherit (self.lib.dlab) sshKeysForUser;
      inherit (config.dlab) hostCfg;

      # ideally, we could template it in the DSL? e.g. "${hostName}/users/${userName}/hashedPassword"
      sopsSecretPath =
        userName:
        lib.concatStrings [
          config.dlab.hostName
          "/users/"
          userName
          "/hashedPassword"
        ];

      # SOPS secrets for users with passwords
      secretsForNixosUsers = lib.mapAttrs' (
        userName: user:
        lib.nameValuePair (sopsSecretPath userName) {
          # Keep this option true or the user will not be able to log in.
          # https://github.com/Mic92/sops-nix?tab=readme-ov-file#setting-a-users-password
          neededForUsers = true;
        }
      ) (lib.filterAttrs (_: user: user.hashedPasswordPath != null) hostCfg.users);

      toNixosUsers = lib.mapAttrs (
        userName: user:
        {
          isNormalUser = true;
          extraGroups = user.groups;
          openssh.authorizedKeys.keys = sshKeysForUser userName config.dlab.hostName self.dlab.hosts;
        }
        // (lib.optionalAttrs (user.hashedPasswordPath != null) {
          # TODO: use contracts to fulfill this?
          hashedPasswordFile = config.sops.secrets.${sopsSecretPath userName}.path;
        })
      ) hostCfg.users;
    in
    {
      users.users = toNixosUsers;
      sops.secrets = secretsForNixosUsers;
    };
}
