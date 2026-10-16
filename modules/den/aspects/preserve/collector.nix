{
  config,
  den,
  lib,
  ...
}:
let
  compile = config.fleet.preserve.compile;
in
{
  den.schema.host.includes = [ den.aspects.preserve.collector ];

  den.aspects.preserve.collector.nixos =
    { preserve, ... }:
    let
      compiled = compile { realizations = preserve; };
    in
    {
      options.homelab.preserve = {
        desiredInventory = lib.mkOption {
          type = lib.types.raw;
          readOnly = true;
          description = "Schema-versioned desired state-protection inventory.";
        };
        executablePlan = lib.mkOption {
          type = lib.types.raw;
          readOnly = true;
          description = "Strictly resolved executable state-protection plan.";
        };
        ownerProjections = lib.mkOption {
          type = lib.types.raw;
          readOnly = true;
          description = "Inactive lifecycle-owner configuration projections.";
        };
      };

      config = {
        homelab.preserve = {
          inherit (compiled)
            desiredInventory
            executablePlan
            ownerProjections
            ;
        };
        environment.etc."homelab-preserve/desired-inventory.json".text =
          builtins.toJSON compiled.desiredInventory;
        environment.etc."homelab-preserve/executable-plan.json".text =
          builtins.toJSON compiled.executablePlan;
      };
    };
}
