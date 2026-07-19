# Finite destination constructors for the secure-terminal network policy
# (V3 §11.1, §12.2).
#
# This library is the ONLY way to write a network destination. It produces
# inert data consumed by policy.nix; all validation happens at evaluation
# time, mirroring the broker's own fail-closed checks:
# - explicit hostname match kinds (exact | subdomains | host-and-subdomains),
#   never ambiguous wildcard strings;
# - public-suffix wildcards rejected;
# - IP literals rejected (internal services arrive only as reviewed service
#   bundles with typed address constraints);
# - invalid ports and empty hostnames rejected;
# - protocol escape hatches (WebSockets, CONNECT, raw TCP, SSH) are absent
#   by construction — the hard floor denies them and no constructor can
#   produce them.
{ lib }:

let
  inherit (lib) all concatStringsSep;

  hostnameRe = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*";

  # Public-suffix-like bases that may never be wildcarded (kept in sync with
  # the broker's FORBIDDEN_WILDCARD_BASES).
  forbiddenWildcardBases = [
    "com" "org" "net" "io" "dev" "app" "co" "me" "info" "biz" "ai" "sh"
    "uk" "us" "de" "fr" "jp" "cn" "au" "ca" "nl" "se" "no" "fi" "dk"
    "co.uk" "com.au" "or.jp" "github.io"
  ];

  isIpv4Literal = host:
    builtins.match "[0-9]{1,3}(\\.[0-9]{1,3}){3}" host != null;

  validateHostname = host:
    if host == "" then
      throw "network-dsl: empty hostname"
    else if isIpv4Literal host || lib.hasInfix ":" host then
      throw "network-dsl: IP literals are not valid destinations: ${host}"
    else if builtins.match hostnameRe host == null then
      throw "network-dsl: invalid hostname: ${host}"
    else
      host;

  validatePorts = ports:
    if ports == null then
      null
    else if !(builtins.isList ports) || ports == [ ] then
      throw "network-dsl: ports must be a non-empty list"
    else if !(all (p: builtins.isInt p && p >= 1 && p <= 65535) ports) then
      throw "network-dsl: invalid port in ${concatStringsSep "," (map toString ports)}"
    else
      lib.unique (lib.sort (a: b: a < b) ports);

  mkDestination = kind: { host, ports ? null }:
    let
      validHost = validateHostname host;
      validPorts = validatePorts ports;
    in
    if kind != "exact" && (lib.elem validHost forbiddenWildcardBases || lib.length (lib.splitString "." validHost) < 2) then
      throw "network-dsl: refusing to wildcard a public suffix: ${validHost}"
    else
      { inherit kind; host = validHost; } // lib.optionalAttrs (validPorts != null) { ports = validPorts; };

in
{
  # TCP 443 HTTPS to exactly this host.
  httpsExact = host: mkDestination "exact" { inherit host; };

  # TCP 443 HTTPS to any subdomain of this host (not the bare host).
  httpsSubdomains = host: mkDestination "subdomains" { inherit host; };

  # TCP 443 HTTPS to this host and any subdomain.
  httpsHostAndSubdomains = host: mkDestination "host-and-subdomains" { inherit host; };

  # A destination with a non-standard port (still HTTPS, still one host).
  httpsExactPort = host: port: mkDestination "exact" { inherit host; ports = [ port ]; };

  # A positive allowlist bundle. The floor's protocol denials are not
  # representable: bundle records carry destinations only.
  bundle =
    {
      destinations,
      ...
    }:
    if !(builtins.isList destinations) || destinations == [ ] then
      throw "network-dsl: a bundle requires at least one destination"
    else
      {
        inherit destinations;
        allowWebSockets = false;
        allowConnect = false;
        allowRawTcp = false;
        allowSsh = false;
      };
}
