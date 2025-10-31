{ lib, ... }:
let
  readAndTrim = f: lib.strings.trim (builtins.readFile f);

  readAsStr = v: if lib.isPath v then readAndTrim v else lib.strings.trim v;

  readAsInt =
    v:
    let
      vStr = readAsStr v;
    in
    if lib.isString vStr then lib.strings.toInt vStr else vStr;

  # https://discourse.nixos.org/t/nix-function-to-merge-attributes-records-recursively-and-concatenate-arrays/2030/9
  # consider https://codeberg.org/amjoseph/infuse.nix for more complex merging needs
  deepMerge =
    lhs: rhs:
    lhs
    // rhs
    // (builtins.mapAttrs (
      rName: rValue:
      let
        lValue = lhs.${rName} or null;
      in
      if builtins.isAttrs lValue && builtins.isAttrs rValue then
        deepMerge lValue rValue
      else if builtins.isList lValue && builtins.isList rValue then
        lValue ++ rValue
      else
        rValue
    ) rhs);
in
{
  flake.lib.utilities = {
    inherit readAsStr readAsInt deepMerge;
  };
}
