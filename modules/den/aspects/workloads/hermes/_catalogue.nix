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

  hash = value: builtins.hashString "sha256" (builtins.toJSON value);

  # Trusted workspace-provider contracts. `broker-project` is the only
  # Project provider: it materializes task-private three-plane broker
  # workspaces and never falls back to a gateway host worktree.
  providerContracts = {
    broker-project = {
      supportedSourceKinds = [ "git" ];
      permissions = [
        "read-only"
        "workspace-write"
      ];
    };
  };

  sourceRevisionsFor = sources: lib.mapAttrs (_: source: hash source) sources;
  providerRevisionsFor = providers: lib.mapAttrs (_: provider: hash provider) providers;

  # A trusted acquisition URL is an https endpoint without embedded
  # userinfo. Credentials never ride the URL, a store path, an environment
  # name, argv, or a guest-visible path.
  hasUserinfo =
    upstream:
    let
      authority = builtins.head (lib.splitString "/" (lib.removePrefix "https://" upstream));
    in
    lib.hasInfix "@" authority;
  trustedUpstream =
    upstream:
    lib.hasPrefix "https://" upstream
    && !lib.hasPrefix "/nix/store" upstream
    && !hasUserinfo upstream;
in
{
  inherit providerContracts sourceRevisionsFor providerRevisionsFor;

  resolve =
    {
      instance,
      workerLanes ? { },
      boards ? { },
      projects ? { },
      projectSources ? { },
      ...
    }:
    let
      laneNames = builtins.attrNames workerLanes;
      projectNames = builtins.attrNames projects;
      providerSourceKinds = providerContracts.broker-project.supportedSourceKinds;

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
            (check (
              projectCapable -> lib.all (kind: lib.elem kind providerSourceKinds) workspace.supportedSourceKinds
            ) "Project-capable worker lane '${name}' declares a source kind unsupported by the broker-project provider")
            (check (
              (workspace.inputs or null) == null || (
                (workspace.inputs.enabled or true)
                && (workspace.inputs.maxInputs or 0) >= 1
                && (workspace.inputs.maxInputBytes or 0) >= 1
                && (workspace.inputs.maxInputEntries or 0) >= 1
                && (workspace.inputs.maxInputPathBytes or 0) >= 256
              ) || (!(workspace.inputs.enabled or true))
            ) "Worker lane '${name}' declares enabled inputs without positive count/byte/entry/path ceilings")
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

      sourceChecks = lib.concatLists (
        lib.mapAttrsToList (
          repositoryId: source:
          [
            (check (trustedUpstream source.upstream) "Project source '${repositoryId}' upstream must be a credential-free https URL outside the Nix store")
            (check (
              !lib.hasPrefix "/" source.defaultRef && !lib.hasInfix ".." source.defaultRef
            ) "Project source '${repositoryId}' default ref must be an ordinary ref name, not a path")
          ]
        ) projectSources
      );

      projectChecks = lib.concatLists (
        lib.mapAttrsToList (
          projectName: project:
          let
            adapter = projectSources.${project.source.repositoryId} or null;
          in
          [
            (check (adapter != null) "Project '${projectName}' references an unknown repositoryId '${project.source.repositoryId}'")
            (check (
              adapter == null || adapter.type == project.source.type
            ) "Project '${projectName}' source kind disagrees with its trusted source adapter")
            (check (
              adapter == null || adapter.defaultRef == project.source.defaultRef
            ) "Project '${projectName}' default ref disagrees with its trusted source adapter")
          ]
          ++ lib.concatLists (
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

      laneRevisions = lib.mapAttrs (_: lane: hash lane) workerLanes;
      projectRevisions = lib.mapAttrs (_: project: hash project) projects;
      sourceRevisions = sourceRevisionsFor projectSources;
      providerRevisions = providerRevisionsFor providerContracts;

      catalogues = {
        version = 1;
        inherit
          boards
          instance
          laneRevisions
          projectRevisions
          projects
          providerRevisions
          sourceRevisions
          workerLanes
          ;
      };
      revision = hash catalogues;
      valid = validateChecks (laneChecks ++ boardChecks ++ projectChecks ++ sourceChecks);
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
        providerRevisions
        revision
        sourceRevisions
        workerLanes
        ;
    };
}
