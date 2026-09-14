_: {
  den.preserve = {
    slots."host-root-dataset" = {
      consistency = "filesystem";
      restoreSemantics = "scratch-only";
      suggestedPolicy = "household-roots-plan";
      caveats = [
        "Coverage is non-recursive and does not include child datasets or mounted filesystems."
        "Filesystem snapshots do not establish application consistency."
      ];
    };

    states = {
      "household/home" = {
        stateId = "household/home";
        slotId = "host-root-dataset";
        mode = "plan-only";
        explicitPolicy = "household-roots-plan";
      };
      "household/persist" = {
        stateId = "household/persist";
        slotId = "host-root-dataset";
        mode = "plan-only";
        explicitPolicy = "household-roots-plan";
      };
    };

    policies."household-roots-plan" = {
      disposable = false;
      routes = [ "household-copy" ];
    };

    routes."household-copy" = {
      routeId = "household-copy";
      target = null;
      integration = null;
      operation = "run";
      requiredConsistency = "filesystem";
      requiredFidelity = "filesystem";
    };
  };
}
