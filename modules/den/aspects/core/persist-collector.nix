_: {
  den.aspects."core/persist-collector" = {
    nixos = { persist, cache, lib, ... }:
      let
        wrapPath = path: metadata:
          if metadata.user != null || metadata.group != null || metadata.mode != null then
            { directory = path; }
            // lib.optionalAttrs (metadata.user != null) { user = metadata.user; }
            // lib.optionalAttrs (metadata.group != null) { group = metadata.group; }
            // lib.optionalAttrs (metadata.mode != null) { mode = metadata.mode; }
          else
            path;

        collectDirs = entries:
          lib.unique (lib.concatMap
            (entry: map
              (d: wrapPath d {
                user = entry.user or null;
                group = entry.group or null;
                mode = entry.mode or null;
              })
              (if builtins.isString entry then [ entry ]
               else entry.directories or [ ]))
            entries);

        collectFiles = entries:
          lib.unique (lib.concatMap
            (entry: map
              (f: wrapPath f {
                user = entry.user or null;
                group = entry.group or null;
                mode = entry.mode or null;
              })
              (if builtins.isAttrs entry then entry.files or [ ] else [ ]))
            entries);

        mergePersist = entries:
          let dirs = collectDirs entries;
              fils = collectFiles entries;
          in
          lib.optionalAttrs (dirs != [ ]) { directories = dirs; }
          // lib.optionalAttrs (fils != [ ]) { files = fils; };
      in
      {
        environment.persistence."/persist" = mergePersist persist;
        environment.persistence."/cache" = mergePersist cache;
      };
  };
}
