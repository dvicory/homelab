{ lib }:
path:
builtins.match "/[^[:space:]]+" path != null
&& path != "/"
&& !lib.hasSuffix "/" path
&& !lib.hasInfix "//" path
&& builtins.all (segment: segment != "." && segment != "..") (lib.drop 1 (lib.splitString "/" path))
