{
  lib,
  ...
}:
let
  mergerfs = import ../den/aspects/services/_mergerfs.nix { inherit lib; };

  valid = {
    "/srv/media/data".branches = [
      {
        path = "/mnt/hot";
        unit = "hot.mount";
        required = true;
      }
      {
        path = "/mnt/archive";
        unit = null;
        required = false;
        create = false;
      }
    ];
  };
  duplicate = valid // {
    "/srv/other".branches = [
      {
        path = "/mnt/hot";
        unit = "hot.mount";
        required = true;
      }
    ];
  };
  incomplete = {
    "/srv/media/data".branches = [
      {
        path = "/mnt/hot";
        unit = null;
        required = true;
      }
    ];
  };
  derivedUnit = {
    "/srv/media/data".branches = [
      {
        path = "/mnt/hot";
        unit = null;
        fileSystemMount = true;
        required = true;
      }
    ];
  };
  optionalWriter = {
    "/srv/media/data".branches = [
      {
        path = "/mnt/archive";
        unit = null;
        required = false;
        create = true;
      }
    ];
  };

  assertions = {
    "canonical pool paths remain distinct service names" =
      mergerfs.serviceNameFor "/srv/media/data"
      == "mergerfs-mnt-${builtins.hashString "sha256" "/srv/media/data"}"
      &&
        mergerfs.unitNameFor "/srv/media/data"
        == "mergerfs-mnt-${builtins.hashString "sha256" "/srv/media/data"}.service"
      && mergerfs.serviceNameFor "/srv/a/b" != mergerfs.serviceNameFor "/srv/a-b";
    "configured service names are unique" = mergerfs.duplicateServiceNames valid == [ ];
    "non-canonical pool paths are rejected" =
      mergerfs.nonCanonicalPoolPaths {
        "/" = { };
        "/srv//media" = { };
        "/srv/media/" = { };
        "/srv/media/../other" = { };
      } == [
        "/"
        "/srv//media"
        "/srv/media/"
        "/srv/media/../other"
      ];
    "conformant pools have unique placements" = mergerfs.duplicatePaths valid == [ ];
    "one placement cannot back two pools" = mergerfs.duplicatePaths duplicate == [ "/mnt/hot" ];
    "optional placements need no mount unit" = mergerfs.requiredWithoutUnit valid == [ ];
    "required placements need a mount unit" = mergerfs.requiredWithoutUnit incomplete == [ "/mnt/hot" ];
    "a derived fileSystems mount unit satisfies a required placement" =
      mergerfs.requiredWithoutUnit derivedUnit == [ ];
    "optional placements cannot receive writes" =
      mergerfs.optionalCreatePaths optionalWriter == [ "/mnt/archive" ];
    "no-create optional placements are valid" = mergerfs.optionalCreatePaths valid == [ ];
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) assertions);
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks.mergerfs-contracts =
        assert lib.assertMsg (
          failures == [ ]
        ) "MergerFS declaration failures: ${lib.concatStringsSep ", " failures}";
        pkgs.writeText "mergerfs-contracts" "ok\n";
    };
}
