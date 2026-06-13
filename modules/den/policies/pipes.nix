# Pipe collection policies for cross-host discovery.
#
# Declares collection policies for all quirks that need cross-host
# aggregation, wired into host schema so every host collects pipe
# entries from peers.
{ den, ... }:
let
  inherit (den.lib.policy) pipe;
in
{
  den.policies.collect-host-addrs =
    { host, ... }:
    [
      (pipe.from "host-addrs" [
        (pipe.collectAll ({ host, ... }: true))
      ])
    ];

  den.policies.collect-prometheus-targets =
    { host, ... }:
    [
      (pipe.from "prometheus-targets" [
        (pipe.collect ({ host, ... }: true))
      ])
    ];

  den.policies.collect-ollama-endpoints =
    { host, ... }:
    [
      (pipe.from "ollama-endpoints" [
        (pipe.collect ({ host, ... }: true))
      ])
    ];

  # Bottom-up: resolved-users emitted per user at user scope,
  # exposed to host scope so host aspects can enumerate resolved users.
  den.policies.expose-resolved-users =
    { user, ... }:
    [
      (pipe.from "resolved-users" [
        pipe.expose
      ])
    ];

  den.schema.host.includes = [
    den.policies.collect-host-addrs
    den.policies.collect-prometheus-targets
    den.policies.collect-ollama-endpoints
  ];

  den.schema.user.includes = [
    den.policies.expose-resolved-users
  ];
}
