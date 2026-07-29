{ lib }:
let
  duplicateFree = values: builtins.length values == builtins.length (lib.unique values);
  permissionRank = {
    none = 0;
    read-only = 1;
    workspace-write = 2;
  };

  check = assertion: message: { inherit assertion message; };
  validateChecks = checks: lib.foldl' (
    valid: item: if item.assertion then valid else throw item.message
  ) true checks;
in
{
  resolve =
    {
      instance,
      workerLanes ? { },
      boards ? { },
      projects ? { },
      ...
    }:
    let
      laneNames = builtins.attrNames workerLanes;
      projectNames = builtins.attrNames projects;

      laneChecks = lib.concatLists (
        lib.mapAttrsToList (
          name: lane:
          let
            workspace = lane.workspace;
            isHermes = lane.runtime == "hermes";
            projectCapable = workspace.projectMode != "none";
          in
          [
            (check (isHermes -> lane.plugin == null) "Hermes worker lane '${name}' must not declare an external plugin")
            (check (
              (!isHermes) -> lane.plugin != null
            ) "External worker lane '${name}' must declare its plugin")
            (check (
              (!isHermes) -> lane.profile == null
            ) "External worker lane '${name}' must not declare a Hermes profile")
            (check (
              (lane.memory == "shared-profile") -> lane.profile != null
            ) "Worker lane '${name}' uses shared-profile memory without a profile")
            (check (
              projectCapable -> workspace.projectProvider != null
            ) "Project-capable worker lane '${name}' must declare projectProvider")
            (check (
              projectCapable -> workspace.maximumPermission != "none"
            ) "Project-capable worker lane '${name}' must grant a non-none permission ceiling")
            (check (
              projectCapable -> workspace.supportedSourceKinds != [ ]
            ) "Project-capable worker lane '${name}' must declare supportedSourceKinds")
            (check (
              (!projectCapable) -> workspace.projectProvider == null
            ) "Scratch-only worker lane '${name}' must not declare projectProvider")
            (check (
              (!projectCapable) -> workspace.maximumPermission == "none"
            ) "Scratch-only worker lane '${name}' must retain a none Project permission ceiling")
          ]
        ) workerLanes
      );

      boardChecks = lib.concatLists (
        lib.mapAttrsToList (
          name: board:
          [
            (check (duplicateFree board.allowedLanes) "Board '${name}' contains duplicate allowedLanes")
            (check (duplicateFree board.allowedProjects) "Board '${name}' contains duplicate allowedProjects")
            (check (
              lib.all (lane: builtins.hasAttr lane workerLanes) board.allowedLanes
            ) "Board '${name}' references an unknown worker lane")
            (check (
              lib.all (project: builtins.hasAttr project projects) board.allowedProjects
            ) "Board '${name}' references an unknown Project")
            (check (
              board.defaultProject == null || lib.elem board.defaultProject board.allowedProjects
            ) "Board '${name}' defaultProject must appear in allowedProjects")
          ]
        ) boards
      );

      projectChecks = lib.concatLists (
        lib.mapAttrsToList (
          projectName: project:
          lib.concatLists (
            lib.mapAttrsToList (
              laneName: permission:
              let
                lane = workerLanes.${laneName} or null;
              in
              [
                (check (lane != null) "Project '${projectName}' grants an unknown worker lane '${laneName}'")
                (check (
                  lane == null || lane.workspace.projectMode != "none"
                ) "Project '${projectName}' grants scratch-only worker lane '${laneName}'")
                (check (
                  lane == null
                  || permissionRank.${permission} <= permissionRank.${lane.workspace.maximumPermission}
                ) "Project '${projectName}' exceeds worker lane '${laneName}' permission ceiling")
                (check (
                  lane == null || lib.elem project.source.type lane.workspace.supportedSourceKinds
                ) "Project '${projectName}' source kind is unsupported by worker lane '${laneName}'")
              ]
            ) project.laneAccess
          )
        ) projects
      );

      laneRevisions = lib.mapAttrs (_: lane: builtins.hashString "sha256" (builtins.toJSON lane)) workerLanes;
      projectRevisions = lib.mapAttrs (
        _: project: builtins.hashString "sha256" (builtins.toJSON project)
      ) projects;

      catalogues = {
        version = 1;
        inherit
          boards
          instance
          laneRevisions
          projectRevisions
          projects
          workerLanes
          ;
      };
      revision = builtins.hashString "sha256" (builtins.toJSON catalogues);
      valid = validateChecks (laneChecks ++ boardChecks ++ projectChecks);
    in
    assert valid;
    {
      inherit
        boards
        instance
        laneNames
        laneRevisions
        projectNames
        projects
        projectRevisions
        revision
        workerLanes
        ;
    };
}
