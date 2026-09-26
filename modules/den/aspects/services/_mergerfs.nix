# mergerfs pool helpers.
#
# Shared by the pooling module and its contract checks.
{ lib }:
let
  isCanonicalPath = import ./_storage-path.nix { inherit lib; };
  serviceNameFor = path: "mergerfs-mnt-${builtins.hashString "sha256" path}";
in
{
  inherit isCanonicalPath serviceNameFor;

  # `/srv/media` -> `mergerfs-mnt-srv-media.service`, the unit the pooling module
  # creates for that pool.
  unitNameFor = path: "${serviceNameFor path}.service";
  nonCanonicalPoolPaths =
    pools: builtins.filter (path: !isCanonicalPath path) (builtins.attrNames pools);

  duplicatePaths =
    pools:
    let
      branches = lib.concatMap (pool: pools.${pool}.branches) (builtins.attrNames pools);
      counts = lib.foldl' (
        result: branch: result // { ${branch.path} = (result.${branch.path} or 0) + 1; }
      ) { } branches;
    in
    builtins.filter (path: counts.${path} > 1) (builtins.attrNames counts);

  duplicateServiceNames =
    pools:
    let
      names = map serviceNameFor (builtins.attrNames pools);
      counts = lib.foldl' (result: name: result // { ${name} = (result.${name} or 0) + 1; }) { } names;
    in
    builtins.filter (name: counts.${name} > 1) (builtins.attrNames counts);

  requiredWithoutUnit =
    pools:
    map (branch: branch.path) (
      builtins.filter (
        branch: branch.required && branch.unit == null && !(branch.fileSystemMount or false)
      ) (lib.concatMap (pool: pools.${pool}.branches) (builtins.attrNames pools))
    );

  optionalCreatePaths =
    pools:
    map (branch: branch.path) (
      builtins.filter (branch: !branch.required && branch.create) (
        lib.concatMap (pool: pools.${pool}.branches) (builtins.attrNames pools)
      )
    );

}
