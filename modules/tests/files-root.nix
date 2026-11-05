{
  perSystem =
    { config, pkgs, ... }:
    {
      checks.generated-files-root =
        let
          expected = pkgs.writeText "expected-storage.md" config.files.file."docs/storage.md".text;
        in
        pkgs.runCommand "generated-files-root"
          {
            nativeBuildInputs = [
              pkgs.gitMinimal
              pkgs.jujutsu
            ];
          }
          ''
            ancestor="$PWD/ancestor"
            jj git init --colocate "$ancestor"
            git init "$ancestor/child"
            mkdir -p "$ancestor/docs" "$ancestor/child/nested"
            printf 'unrelated checkout\n' > "$ancestor/docs/storage.md"
            cp "$ancestor/docs/storage.md" ancestor-before
            (
              cd "$ancestor/child/nested"
              export GIT_DIR="$ancestor/.git" GIT_WORK_TREE="$ancestor"
              ${config.apps.write-files.program}
            )
            cmp ${expected} "$ancestor/child/docs/storage.md"
            cmp ancestor-before "$ancestor/docs/storage.md"

            # Invalid nearest metadata must not fall back to the valid ancestor.
            rm -rf "$ancestor/child/.git"
            mkdir "$ancestor/child/.git"
            if (cd "$ancestor/child/nested"; ${config.apps.write-files.program}); then
              echo 'writer accepted invalid nearest repository metadata' >&2
              exit 1
            fi
            cmp ${expected} "$ancestor/child/docs/storage.md"
            cmp ancestor-before "$ancestor/docs/storage.md"
            touch "$out"
          '';
    };
}
