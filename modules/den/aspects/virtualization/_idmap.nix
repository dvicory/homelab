# Canonical Incus ID-map planner.
#
# One place computes the effective map, in the vocabulary Incus itself reports:
# rows of { nsid, hostid, range }. Everything else — `raw.idmap`, the project's
# permitted host IDs, the descriptor the lifecycle tool compares against —
# derives from these rows, so there is no second coordinate algorithm to get
# wrong.
#
# A declared capability GID is identity-mapped: guest GID 505 is host GID 505.
# That costs the ordinary shift exactly one host ID, because the guest's
# coordinate 505 no longer maps to `idmapBase + 505`.
#
#   idmapBase = 1000000, idmapSize = 65536, capability = 505
#
#   gid: { nsid = 0;   hostid = 1000000; range = 505;   }
#        { nsid = 505; hostid = 505;     range = 1;     }
#        { nsid = 506; hostid = 1000506; range = 65030; }
#
# Note which coordinate each bound lives in: cut points are guest-space, and the
# guest-space hole is the capability GID itself. Mixing the two is the mistake
# this module exists to make impossible.
{ lib }:
let
  row = nsid: hostid: range: {
    inherit nsid hostid range;
  };

  gidRows =
    idmapBase: idmapSize: capabilityGids:
    let
      walk =
        cursor: holes:
        if holes == [ ] then
          lib.optional (cursor < idmapSize) (row (cursor) (idmapBase + cursor) (idmapSize - cursor))
        else
          let
            gid = builtins.head holes;
            ordinary = lib.optional (gid > cursor) (
              row cursor (idmapBase + cursor) (gid - cursor)
            );
            identity = row gid gid 1;
          in
          ordinary ++ [ identity ] ++ walk (gid + 1) (builtins.tail holes);
    in
    walk 0 (lib.sort builtins.lessThan capabilityGids);

  line =
    kind: entry:
    if entry.range == 1 then
      "${kind} ${toString entry.hostid} ${toString entry.nsid}"
    else
      "${kind} ${toString entry.hostid}-${toString (entry.hostid + entry.range - 1)} ${toString entry.nsid}-${toString (entry.nsid + entry.range - 1)}";

  # Incus is given host-side ranges. A singleton uses the bare form:
  # upstream ParseUint32Range accepts "number" or "start-end" but rejects
  # "start-start" (start must be lower than end).
  spans = entries: lib.concatStringsSep "," (
    map (entry: if entry.range == 1 then toString entry.hostid else "${toString entry.hostid}-${toString (entry.hostid + entry.range - 1)}") entries
  );
in
{
  plan =
    {
      idmapBase,
      idmapSize,
      capabilityGids ? [ ],
    }:
    let
      uid = [
        (row 0 idmapBase idmapSize)
      ];
      gid = gidRows idmapBase idmapSize (lib.sort builtins.lessThan capabilityGids);
      identityRows = builtins.filter (entry: entry.nsid == entry.hostid && entry.range == 1) gid;
    in
    {
      inherit uid gid;
      rawIdmap = lib.concatStringsSep "\n" (map (line "uid") uid ++ map (line "gid") gid);
      permittedHostUidRanges = spans uid;
      permittedHostGidRanges = spans gid;
      # Host IDs the kernel's setuid helpers must be authorized to map.
      subordinateGidRanges =
        [
          {
            startGid = idmapBase;
            count = idmapSize;
          }
        ]
        ++ map (entry: {
          startGid = entry.hostid;
          count = 1;
        }) identityRows;
      identityHostIds = map (entry: entry.hostid) identityRows;
    };
}
