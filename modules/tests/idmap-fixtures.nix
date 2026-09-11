{
  lib,
  ...
}:
# Direct fixtures for the canonical ID-map planner.
#
# These are pure: they assert the rows the planner emits for a given declared
# capability set, so a coordinate mistake fails here rather than on a host.
let
  idmap = import ../den/aspects/virtualization/_idmap.nix { inherit lib; };
  base = 1000000;
  size = 65536;
  last = base + size - 1;
  planFor = capabilityGids: idmap.plan { idmapBase = base; idmapSize = size; inherit capabilityGids; };
  row = nsid: hostid: range: { inherit nsid hostid range; };

  none = planFor [ ];
  one = planFor [ 505 ];
  two = planFor [ 600 505 ];

  fixtures = {
    "no-capability-rows" =
      none.uid == [ (row 0 base size) ] && none.gid == [ (row 0 base size) ];
    "no-capability-raw" =
      none.rawIdmap == "uid ${toString base}-${toString last} 0-${toString (size - 1)}\ngid ${toString base}-${toString last} 0-${toString (size - 1)}";
    "one-capability-rows" =
      one.gid == [
        (row 0 base 505)
        (row 505 505 1)
        (row 506 (base + 506) (size - 506))
      ];
    "one-capability-identity" = one.identityHostIds == [ 505 ];
    "one-capability-raw" =
      one.rawIdmap == "uid ${toString base}-${toString last} 0-${toString (size - 1)}\ngid ${toString base}-${toString (base + 504)} 0-504\ngid 505 505\ngid ${toString (base + 506)}-${toString last} 506-${toString (size - 1)}";
    "one-capability-project-ranges" =
      one.permittedHostGidRanges == "${toString base}-${toString (base + 504)},505-505,${toString (base + 506)}-${toString last}"
      && one.permittedHostUidRanges == "${toString base}-${toString last}";
    "one-capability-subordinate" =
      one.subordinateGidRanges == [
        {
          startGid = base;
          count = size;
        }
        {
          startGid = 505;
          count = 1;
        }
      ];
    "multiple-holes" =
      two.gid == [
        (row 0 base 505)
        (row 505 505 1)
        (row 506 (base + 506) 94)
        (row 600 600 1)
        (row 601 (base + 601) (size - 601))
      ];
    "holes-are-sorted" = two.gid == (planFor [ 505 600 ]).gid;
    "guest-coverage-is-complete" =
      (builtins.foldl' (total: entry: total + entry.range) 0 two.gid) == size;
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) fixtures);
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks.idmap-fixtures = pkgs.writeText "idmap-fixtures" (
        if failures == [ ] then "ok\n" else throw "idmap fixture failures: ${lib.concatStringsSep ", " failures}"
      );
    };
}
