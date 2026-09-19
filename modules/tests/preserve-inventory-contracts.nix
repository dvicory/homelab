{
  lib,
  self,
  ...
}:
let
  hvn = self.nixosConfigurations.hvn-hyp1.config;
  inventory = hvn.homelab.preserve.desiredInventory;
  states = builtins.listToAttrs (
    map (entry: {
      name = entry.stateId;
      value = entry;
    }) inventory.states
  );
  issuesOf = entry: entry.issues ++ lib.concatMap (route: route.issues) entry.routes;
  home = states."household/home";
  persist = states."household/persist";
  assertions = {
    household-states =
      builtins.attrNames states == [
        "household/home"
        "household/persist"
      ]
      && inventory.kind == "desired-inventory"
      && inventory.fixtureOnly == false;
    evaluated-dataset-bindings =
      home.realization.path == hvn.disko.devices.zpool.rpool.datasets."safe/home".mountpoint
      && home.realization.locator == "rpool/safe/home"
      && home.realization.owner.id == "hvn-hyp1"
      && persist.realization.path == hvn.disko.devices.zpool.rpool.datasets."safe/persist".mountpoint
      && persist.realization.locator == "rpool/safe/persist"
      && persist.realization.owner.id == "hvn-hyp1";
    distinct-slots = home.slotId == "household/home" && persist.slotId == "household/host-role-persist";
    plan-only-unresolved = builtins.all (
      entry:
      entry.mode == "plan-only"
      && !entry.operational
      && !entry.realization.boundary.recursive
      && builtins.elem "filesystem-read" entry.realization.capabilities
      && builtins.elem "zfs-snapshot" entry.realization.capabilities
      && builtins.elem "zfs-send" entry.realization.capabilities
      && builtins.elem "missing-target" (map (issue: issue.code) (issuesOf entry))
      && !(entry ? caveats)
      && !(entry ? failureDomainIndependent)
    ) inventory.states;
    no-production-enablement =
      hvn.homelab.preserve.executablePlan.states == [ ]
      && !hvn.services.zrepl.enable
      && hvn.services.restic.backups == { };
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) assertions);
in
{
  perSystem =
    { pkgs, system, ... }:
    {
      checks.preserve-inventory-contracts =
        assert lib.assertMsg (
          failures == [ ]
        ) "Preserve inventory contract assertions failed: ${lib.concatStringsSep ", " failures}";
        pkgs.writeText "preserve-inventory-contracts" "ok\n";
    };
}
