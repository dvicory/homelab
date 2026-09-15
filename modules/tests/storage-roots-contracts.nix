# Contracts of the host-owned storage roots aspect.
#
# The property under test is inherited access: the ACL is generated in Nix but
# its effect only appears on a filesystem, so a regression here would silently
# widen or narrow what content created inside a root can be reached by. These
# assertions run at evaluation time and fail the build instead.
{
  lib,
  ...
}:
let
  aclOf = (import ../den/aspects/services/_storage-roots.nix { inherit lib; }).aclOf;

  private = aclOf { mode = "0700"; };
  shared = aclOf {
    mode = "2770";
    access = [
      {
        group = "wheel";
        access = "rwx";
      }
    ];
  };
  ungrouped = aclOf { mode = "0755"; };

  hasEntry = acl: entry: lib.hasInfix entry acl;

  noEmptyEntry =
    acl:
    builtins.all (entry: !(lib.hasSuffix "::" entry)) (lib.splitString "," acl)
    && !(hasEntry acl "::,");

  assertions = {
    # A private root must not hand content created inside it to the group. Relying
    # on tmpfiles to derive the default entries widens exactly this to the mask.
    "private root keeps inherited group access closed" =
      hasEntry private "g::---"
      && hasEntry private "m::---"
      && hasEntry private "d:g::---"
      && hasEntry private "d:m::---";

    "private root grants nothing to an undeclared group" = !(lib.hasInfix "g:wheel" private);

    "declared group is inherited by content created inside the root" =
      hasEntry shared "g:wheel:rwx" && hasEntry shared "d:g:wheel:rwx";

    # A narrow group class must not silently limit a declared entry.
    "mask covers the declared entry" = hasEntry shared "m::rwx" && hasEntry shared "d:m::rwx";

    "default entries mirror the owning group" = hasEntry ungrouped "d:g::r-x";

    "no generated entry is empty" = builtins.all noEmptyEntry [
      private
      shared
      ungrouped
    ];
  };

  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) assertions);
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks.storage-roots-contracts =
        assert lib.assertMsg (
          failures == [ ]
        ) "Storage root ACL failures: ${lib.concatStringsSep ", " failures}";
        pkgs.writeText "storage-roots-contracts" "ok\n";
    };
}
