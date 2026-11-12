{ lib }:
let
  tailnetIPv4 =
    address:
    let
      parts = if builtins.isString address then lib.splitString "." address else [ ];
      validParts =
        builtins.length parts == 4
        && lib.all (part: builtins.match "(0|[1-9][0-9]{0,2})" part != null) parts;
      octets = if validParts then map builtins.fromJSON parts else [ ];
      valid = validParts && lib.all (octet: octet <= 255) octets;
      first = if valid then builtins.elemAt octets 0 else -1;
      second = if valid then builtins.elemAt octets 1 else -1;
    in
    valid && first == 100 && second >= 64 && second <= 127;
  tailnetIPv6 =
    address:
    let
      text = if builtins.isString address then lib.toLower address else "";
      halves = lib.splitString "::" text;
      groups = lib.concatMap (part: if part == "" then [ ] else lib.splitString ":" part) halves;
      count = builtins.length groups;
    in
    lib.hasPrefix "fd7a:115c:a1e0:" text
    && ((builtins.length halves == 1 && count == 8) || (builtins.length halves == 2 && count < 8))
    && lib.all (part: builtins.match "[0-9a-f]{1,4}" part != null) groups;
  validPort = port: builtins.isInt port && port >= 1 && port <= 65535;
  valid =
    ingress:
    validPort ingress.nodePort
    && (
      ingress.public == null
      || (
        tailnetIPv4 ingress.public.originAddress
        && tailnetIPv4 ingress.public.peerAddress
        && tailnetIPv6 (ingress.public.peerIPv6Address or null)
        && ingress.public.originAddress != ingress.public.peerAddress
        && validPort ingress.public.nodePort
        && ingress.public.nodePort >= 30000
        && ingress.public.nodePort <= 32767
        && ingress.public.nodePort != ingress.nodePort
      )
    );
in
{
  inherit tailnetIPv4 tailnetIPv6 valid;
}
