# Expose resolved user contributions to their host scope.
{ den, ... }:
let
  inherit (den.lib.policy) pipe;
in
{
  # Bottom-up: resolved-users emitted per user at user scope,
  # exposed to host scope so host aspects can enumerate resolved users.
  den.policies.expose-resolved-users =
    { user, ... }:
    [
      (pipe.from "resolved-users" [
        pipe.expose
      ])
    ];

  den.schema.user.includes = [
    den.policies.expose-resolved-users
  ];
}
