{ den, ... }:
let
  mkRunner =
    { uid, instance }:
    {
      aspect = den.aspects.workloads.hermes.account;
      groups = [ "workload-access" ];

      system = {
        inherit uid;
        kind = "workload";
        linger = true;
      };

      settings.workloads.hermes = {
        inherit instance;
        config = {
          model.default = "opencode-go/deepseek-v4-flash";
          agent.restart_drain_timeout = 120;
        };
        tailscale.hostname = "hermes-${instance}";
      };
    };
in
{
  den.users.registry = {
    hermes-qa-runner = mkRunner {
      uid = 1100;
      instance = "qa";
    };
    hermes-prod-runner = mkRunner {
      uid = 1101;
      instance = "prod";
    };
  };

  # Placement remains explicit topology data. Both homes reuse the same
  # workload aspect; their behavior comes from the matching registry account.
  den.homes.x86_64-linux = {
    "hermes-qa-runner@hvn-hyp1".aspect = den.aspects.workloads.hermes.home;
    "hermes-prod-runner@hvn-hyp1".aspect = den.aspects.workloads.hermes.home;
  };
}
