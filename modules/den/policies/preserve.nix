{ den, ... }:
let
  inherit (den.lib.policy) pipe;
in
{
  den.policies.collect-preserve =
    { host, ... }:
    [
      (pipe.from "preserve" [
        (pipe.collectAll ({ host, ... }: true))
      ])
    ];

  den.schema.host.includes = [ den.policies.collect-preserve ];
}
