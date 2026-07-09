{ den, ... }:
{
  den.users.registry.hermes-runner = {
    system.uid = 1100;
    system.linger = true;
    groups = [ "workload-access" ];
  };
}
