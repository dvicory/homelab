{ config, ... }:
{
  config.fleet.preserve.projectors = {
    zrepl =
      {
        integration,
        ownerConfig,
        realization,
        jobId,
        ...
      }:
      let
        native = ownerConfig.native.zrepl or { };
        missing = builtins.filter (key: !(builtins.isAttrs (native.${key} or null))) [
          "connect"
          "snapshotting"
          "pruning"
        ];
      in
      if missing != [ ] then
        throw "preserve: zrepl projector for '${jobId}' requires native.zrepl ${builtins.concatStringsSep ", " missing} configuration"
      else
        {
          entryPoint = integration.adapter;
          config.services.zrepl = {
            enable = false;
            settings.jobs = [
              (
                {
                  name = jobId;
                  type = "push";
                  filesystems.${realization.locator} = true;
                }
                // native
              )
            ];
          };
        };

    nixos-restic =
      {
        integration,
        ownerConfig,
        realization,
        jobId,
        ...
      }:
      let
        native = ownerConfig.native.restic or { };
        source = ownerConfig.source or { };
        target = native.target or { };
        repository = target.repository or null;
        repositoryFile = target.repositoryFile or null;
        credential = target.passwordFile or target.environmentFile or null;
      in
      if !builtins.isString (realization.path or null) then
        throw "preserve: restic projector for '${jobId}' requires a realization with a filesystem path"
      else if (repository == null) == (repositoryFile == null) then
        throw "preserve: restic projector for '${jobId}' requires exactly one of native.restic.target.repository or native.restic.target.repositoryFile"
      else if credential == null then
        throw "preserve: restic projector for '${jobId}' requires a runtime credential reference (native.restic.target.passwordFile or native.restic.target.environmentFile)"
      else
        let
          base =
            if (source.subpath or null) != null then
              "${realization.path}/${source.subpath}"
            else
              realization.path;
        in
        {
          entryPoint = integration.adapter;
          config.services.restic.backups.${jobId} = {
            paths = [ base ] ++ (source.include or [ ]);
            exclude = source.exclude or [ ];
            repository = repository;
            repositoryFile = repositoryFile;
            passwordFile = target.passwordFile or null;
            environmentFile = target.environmentFile or null;
            timerConfig = native.timerConfig or null;
            pruneOpts = native.pruneOpts or [ ];
            checkOpts = native.checkOpts or [ ];
            runCheck = native.runCheck or false;
            createWrapper = native.createWrapper or true;
          };
        };
  };
}
