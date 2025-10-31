{ lib, ... }:
{
  # Export asserts to flake.lib
  config.flake.lib.asserts = {
    # Chain multiple assertions together
    chain =
      assertions: v:
      let
        applyOne = acc: f: if acc == null then null else f acc;
      in
      builtins.foldl' applyOne v assertions;

    # Assert that a list is non-empty
    nonEmptyList =
      v:
      assert (v != [ ]);
      v;

    # Assert that value is null
    isNull = v: if v == null then v else throw "Expected null, got ${toString v}";

    # Assert that value is not null
    isNotNull = v: if v != null then v else throw "Expected non-null, got null";

    # Assert that string is a valid IPv4 address
    isIpv4 =
      ip:
      let
        parts = lib.splitString "." ip;
        isByte = n: (lib.match "^[0-9]+$" n != null) && (lib.toInt n >= 0 && lib.toInt n <= 255);
      in
      if !(lib.isString ip && lib.length parts == 4 && lib.all isByte parts) then
        throw "Invalid IPv4 address: ${ip}"
      else
        ip;

    # Assert that gateway is either null or a string
    gatewayOrNull =
      v:
      assert (v == null || lib.isString v);
      v;

    # Assert that deploy attrset has a target attribute
    deployHasTarget =
      v:
      assert lib.hasAttr "target" v;
      v;

    # Additional useful assertions for DSL validation

    # Assert that string is non-empty
    nonEmptyString =
      v:
      assert (lib.isString v && v != "");
      v;

    # Assert that value is a positive integer
    isPositiveInt =
      v:
      assert (lib.isInt v && v > 0);
      v;

    # Assert that string is a valid hostname (basic check)
    isValidHostname =
      hostname:
      if
        !(lib.isString hostname && lib.match "^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$" hostname != null)
      then
        throw "Invalid hostname: ${hostname}"
      else
        hostname;

    # Assert that string is a valid CIDR notation
    isValidCidr =
      cidr:
      let
        parts = lib.splitString "/" cidr;
        ip = lib.head parts;
        prefix = lib.last parts;
        prefixInt = lib.toInt prefix;
      in
      if
        !(
          lib.length parts == 2
          && lib.isString ip
          && lib.match "^[0-9]+$" prefix != null
          && prefixInt >= 0
          && prefixInt <= 32
        )
      then
        throw "Invalid CIDR: ${cidr}"
      else
        cidr;

    # Assert that system is in allowed list
    isValidSystem =
      allowedSystems: system:
      if !(lib.elem system allowedSystems) then
        throw "Invalid system: ${system}. Allowed: ${lib.concatStringsSep ", " allowedSystems}"
      else
        system;

    # Assert that attrset has all required attributes
    hasRequiredAttrs =
      requiredAttrs: v:
      let
        missing = lib.filter (attr: !lib.hasAttr attr v) requiredAttrs;
      in
      if missing != [ ] then
        throw "Missing required attributes: ${lib.concatStringsSep ", " missing}"
      else
        v;

    # Assert that value is a valid IPv6 address (basic check)
    isIpv6 =
      ip:
      if !(lib.isString ip && lib.match "^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$" ip != null) then
        throw "Invalid IPv6 address: ${ip}"
      else
        ip;

    # Assert that path exists (for device paths)
    pathExists =
      v:
      assert lib.pathExists v;
      v;
  };
}
