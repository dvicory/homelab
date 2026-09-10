# ACL text for host-owned storage roots.
#
# Kept separate from the aspect so the generated ACL can be checked directly:
# the failure this avoids — inherited group access wider than the root's own
# mode — is invisible in Nix and only appears in the resulting ACL.
{ lib }:
let
  permissionBits = {
    "0" = "---";
    "1" = "--x";
    "2" = "-w-";
    "3" = "-wx";
    "4" = "r--";
    "5" = "r-x";
    "6" = "rw-";
    "7" = "rwx";
  };

in
rec {
  # The three permission triples of a mode. A leading special bit is handled by
  # the mode on the directory itself, so it is skipped here.
  permissionsOf =
    mode:
    let
      digits = if builtins.stringLength mode == 4 then builtins.substring 1 3 mode else mode;
    in
    {
      user = permissionBits.${builtins.substring 0 1 digits};
      group = permissionBits.${builtins.substring 1 1 digits};
      other = permissionBits.${builtins.substring 2 1 digits};
    };

  # POSIX masks the group class and every named entry with one mask, so the mask
  # has to cover the group's own permissions and every declared entry; otherwise
  # a narrow group class silently limits a declared entry. An empty result is
  # written as `---` rather than left blank, which would be invalid ACL text.
  unionPermissions =
    permissions:
    let
      union = lib.concatStrings (
        builtins.filter (c: lib.any (p: lib.hasInfix c p) permissions) [
          "r"
          "w"
          "x"
        ]
      );
    in
    if union == "" then "---" else union;

  # Base entries are stated explicitly instead of letting tmpfiles derive them:
  # derivation widens the *default* group entry to the mask, which would give
  # content created inside a private root more group access than the root
  # itself grants.
  aclOf =
    {
      mode,
      access ? [ ],
    }:
    let
      perms = permissionsOf mode;
      mask = unionPermissions ([ perms.group ] ++ map (entry: entry.access) access);
      named = lib.concatMap (entry: [
        "g:${entry.group}:${entry.access}"
        "d:g:${entry.group}:${entry.access}"
      ]) access;
    in
    lib.concatStringsSep "," (
      [
        "u::${perms.user}"
        "g::${perms.group}"
        "o::${perms.other}"
        "m::${mask}"
      ]
      ++ named
      ++ [
        "d:u::${perms.user}"
        "d:g::${perms.group}"
        "d:o::${perms.other}"
        "d:m::${mask}"
      ]
    );
}
