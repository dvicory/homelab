{ lib, ... }:
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
        source = ownerConfig.source or { };
        derivedKeys = builtins.filter (key: builtins.hasAttr key native) [
          "name"
          "type"
          "filesystems"
        ];
        missing = builtins.filter (key: !(builtins.isAttrs (native.${key} or null))) [
          "connect"
          "snapshotting"
          "pruning"
        ];
      in
      if derivedKeys != [ ] then
        throw "preserve: zrepl projector for '${jobId}' refuses derived native.zrepl keys ${builtins.concatStringsSep ", " derivedKeys}"
      else if
        (source.subpath or null) != null || (source.include or [ ]) != [ ] || (source.exclude or [ ]) != [ ]
      then
        throw "preserve: zrepl projector for '${jobId}' does not support source subpath/include/exclude narrowing"
      else if missing != [ ] then
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
        tags = native.tags or [ ];
        localRepository =
          if builtins.isString repository && lib.hasPrefix "/" repository then
            repository
          else if builtins.isString repository && lib.hasPrefix "local:/" repository then
            lib.removePrefix "local:" repository
          else
            null;
      in
      if !builtins.isString (realization.path or null) then
        throw "preserve: restic projector for '${jobId}' requires a realization with a filesystem path"
      else if (repository == null) == (repositoryFile == null) then
        throw "preserve: restic projector for '${jobId}' requires exactly one of native.restic.target.repository or native.restic.target.repositoryFile"
      else if credential == null then
        throw "preserve: restic projector for '${jobId}' requires a runtime credential reference (native.restic.target.passwordFile or native.restic.target.environmentFile)"
      else if !builtins.isList tags || !builtins.all (tag: builtins.isString tag && tag != "") tags then
        throw "preserve: restic projector for '${jobId}' requires native.restic.tags to be a list of non-empty strings"
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
          targetBoundaries =
            if localRepository != null then
              {
                paths = [ localRepository ];
                nativeLocators = [ ];
                nativeNamespace = null;
              }
            else if
              builtins.isString repository && lib.hasInfix ":" repository && !lib.hasPrefix "local:" repository
            then
              {
                paths = [ ];
                nativeLocators = [ repository ];
                nativeNamespace = "restic.repository";
              }
            else
              null;
          config.services.restic.backups.${jobId} = {
            paths = [ base ] ++ (source.include or [ ]);
            exclude = source.exclude or [ ];
            repository = repository;
            repositoryFile = repositoryFile;
            passwordFile = target.passwordFile or null;
            environmentFile = target.environmentFile or null;
            extraBackupArgs = map (tag: "--tag ${lib.escapeShellArg tag}") tags;
            timerConfig = native.timerConfig or null;
            pruneOpts = native.pruneOpts or [ ];
            checkOpts = native.checkOpts or [ ];
            runCheck = native.runCheck or false;
            createWrapper = native.createWrapper or true;
          };
        };
  };
}
