# Host-owned semantic storage roots.
#
# These are the durable, human-meaningful paths (under `/srv`) that
# applications, guests and operators consume. The declaration owns the name,
# the ownership, the mode, and the access that content created inside inherits.
# It does not own the content itself.
#
# Creation is deliberately non-recursive: `d` creates the root, and `a+` adds
# the declared access entries to the root together with their default entries,
# which is what makes newly created content inherit them. Neither rewrites
# anything that already exists, so routine activation never becomes a migration.
#
# ponytail: arbitrary named-access ACL model predates the semantic-namespace
# policy; redesign before implementing /srv/files or /srv/footage.
{
  den,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  # An owning or accessing identity is either a name this host resolves or a
  # numeric ID. Numeric IDs matter for content written through the compute
  # boundary: the host observes the translated ID, not the guest's number.
  identityType = types.strMatching "([A-Za-z_][A-Za-z0-9_.-]*|[0-9]+)";

  accessType = types.submodule {
    options = {
      group = mkOption {
        type = identityType;
        description = "Group granted access to the root and to content created inside it.";
      };
      access = mkOption {
        type = types.strMatching "[rwx-]{1,3}";
        default = "rwx";
        description = "Permission granted to that group.";
      };
    };
  };

  rootType = types.submodule {
    options = {
      path = mkOption {
        type = types.strMatching "/[^[:space:]]*";
        description = "Absolute host path of the root.";
      };
      user = mkOption {
        type = identityType;
        description = "User owning the root.";
      };
      group = mkOption {
        type = identityType;
        description = "Group owning the root.";
      };
      mode = mkOption {
        type = types.strMatching "[0-7]{3,4}";
        default = "2770";
        description = ''
          Mode of the root. Group access is the normal case, so the
          set-group-ID bit is the default: content created inside keeps the
          root's group rather than the creator's.
        '';
      };
      access = mkOption {
        type = types.listOf accessType;
        default = [ ];
        description = ''
          Additional groups granted access to the root and to content created
          inside it, such as the operator group. This is what makes a
          service-owned root workable from the host without becoming root.
        '';
      };
    };
  };

  inherit (import ./_storage-roots.nix { inherit lib; }) aclOf;

  isNumeric = value: builtins.match "[0-9]+" value != null;
in
{
  den.aspects.services.storage-roots = {
    settings.roots = mkOption {
      type = types.attrsOf rootType;
      default = { };
      description = ''
        Host-owned semantic storage roots. The attribute name identifies the
        root; the declared values describe the root itself, never its contents.
      '';
    };

    nixos =
      { host, config, ... }:
      let
        roots = host.settings.services.storage-roots.roots;
        names = builtins.attrNames roots;
        paths = map (name: roots.${name}.path) names;

        compute = host.settings.virtualization.compute or { };
        computeManaged = lib.optionals (compute != { }) (
          [
            compute.stateRoot
            compute.identityPath
          ]
          ++ map (entry: entry.path) (builtins.attrValues (compute.retainedPaths or { }))
        );

        counted = lib.foldl' (acc: path: acc // { ${path} = (acc.${path} or 0) + 1; }) { } paths;
        duplicates = builtins.filter (path: counted.${path} > 1) (builtins.attrNames counted);

        nested = builtins.filter (
          name:
          let
            path = roots.${name}.path;
          in
          lib.any (other: other != name && lib.hasPrefix (roots.${other}.path + "/") path) names
        ) names;

        overlapping = builtins.filter (
          name:
          let
            path = roots.${name}.path;
          in
          lib.any (
            managed: lib.hasPrefix (managed + "/") path || lib.hasPrefix (path + "/") managed || managed == path
          ) computeManaged
        ) names;

        unresolvedIdentity =
          name:
          let
            root = roots.${name};
            missingFor = attr: value: if isNumeric value || builtins.hasAttr value attr then [ ] else [ value ];
          in
          missingFor config.users.users root.user
          ++ missingFor config.users.groups root.group
          ++ lib.concatMap (entry: missingFor config.users.groups entry.group) root.access;

        unresolved = lib.concatMap unresolvedIdentity names;

        describe = names: lib.concatStringsSep ", " names;
      in
      {
        assertions = [
          {
            assertion = duplicates == [ ];
            message = "storage-roots: two roots declare the same path: ${describe duplicates}";
          }
          {
            assertion = nested == [ ];
            message = "storage-roots: a root is nested inside another root: ${describe nested}";
          }
          {
            assertion = overlapping == [ ];
            message = ''
              storage-roots: a root overlaps a compute-managed path: ${describe overlapping}.
              Guest-retained state and host-owned semantic roots are different things;
              declaring one path as both would give it two owners.'';
          }
          {
            assertion = unresolved == [ ];
            message = "storage-roots: owning or accessing identities this host does not declare: ${describe (lib.unique unresolved)}";
          }
        ];

        systemd.tmpfiles.rules = lib.concatMap (
          name:
          let
            root = roots.${name};
          in
          [
            "d ${root.path} ${root.mode} ${root.user} ${root.group} -"
            "a+ ${root.path} - - - - ${aclOf { inherit (root) mode access; }}"
          ]
        ) names;
      };
  };
}
