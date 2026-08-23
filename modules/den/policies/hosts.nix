# Host-level schema wiring.
#
# Wires env-users onto host scope so user resolution fires for every host.
# `fleet.acl` resolves the applicable environment and host access gates.
{ den, ... }:
{
  den.schema.host.includes = [
    den.policies.env-users
  ];
}
