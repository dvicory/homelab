# Fleet groups as real Unix groups.
#
# The registries decide two different things: which groups exist across the
# fleet with a stable numeric ID, and which of them an account receives.
# Resolution handles the second by putting group names into an account's
# supplementary groups — but NixOS does not create a group merely because
# something refers to it, so a group that exists only in the registry resolves
# to nothing: the account lists it and does not have it.
#
# A registry group that declares a numeric ID is therefore materialised. Its
# existence does not depend on who currently holds it, because an ID that
# appears in a file owner or an access entry has to resolve to the same name
# wherever it is inspected.
#
# Groups without an ID are access-resolution concepts that were never meant to
# be Unix groups, and are left alone.
#
# The assertion is the other half of the contract: a group granted to an
# account must exist, whether because this module materialised it or because
# NixOS defines it. It is checked when the system toplevel is evaluated.
{
  den,
  lib,
  config,
  ...
}:
let
  registry = config.den.groups or { };
  withId = lib.filterAttrs (_: group: (group.gid or null) != null) registry;
in
{
  den.aspects.core.users.fleet-groups = {
    nixos =
      { config, ... }:
      let
        granted = lib.unique (
          lib.concatMap (user: user.extraGroups or [ ]) (builtins.attrValues config.users.users)
        );
        unbacked = builtins.filter (name: !(config.users.groups ? ${name})) granted;

        # A GID declared on a fleet POSIX group is the exact fleet identity, so
        # the resolved value has to be exactly that number. Whether it also ends
        # up in filesystem metadata depends on some root actually using it as a
        # capability; the number is fixed either way. This is the whole contract
        # — an ordinary entry in the deterministic registry is only a fallback,
        # where an upstream definition legitimately wins. Checked when the
        # system toplevel is evaluated.
        declared = lib.filterAttrs (
          _: group: (group.gid or null) != null && builtins.elem "posix" (group.labels or [ ])
        ) registry;
        diverged = builtins.filter (
          name: (config.users.groups.${name}.gid or null) != declared.${name}.gid
        ) (builtins.attrNames declared);
      in
      {
        users.groups = lib.mapAttrs (name: group: { gid = lib.mkDefault group.gid; }) withId;

        assertions = [
          {
            assertion = unbacked == [ ];
            message = "den: accounts are granted groups this host does not define: ${lib.concatStringsSep ", " unbacked}";
          }
          {
            assertion = diverged == [ ];
            message = "den: declared fleet group GIDs did not resolve to the declared value: ${lib.concatStringsSep ", " diverged}";
          }
        ];
      };
  };
}
