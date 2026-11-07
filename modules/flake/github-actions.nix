{ lib, ... }:
let
  # Action authorization is independent of revision resolution in actions.lock.
  policy = {
    permissions = {
      enabled = true;
      allowed_actions = "selected";
      sha_pinning_required = true;
    };
    selected-actions = {
      github_owned_allowed = false;
      verified_allowed = false;
      # Existing approved identities; exact revisions become identity@* only.
      patterns_allowed = [
        "actions/checkout@*"
        "Mic92/hestia@*"
        "Mic92/hestia/matrix@*"
        "cachix/cachix-action@*"
        "cachix/install-nix-action@*"
        "zizmorcore/zizmor-action@*"
        "step-security/harden-runner@*"
        "github/codeql-action/*@*"
        "actions/upload-artifact@*"
        "actions/download-artifact@*"
        "wimpysworld/nothing-but-nix@*"
        "srz-zumix/post-run-action@*"
      ];
    };
    workflow = {
      default_workflow_permissions = "read";
      can_approve_pull_request_reviews = false;
    };
  };
in
{
  perSystem =
    { pkgs, ... }:
    let
      desired = pkgs.writeText "github-actions-policy.json" (builtins.toJSON policy);
      inputs = lib.mapAttrs (
        name: value: pkgs.writeText "github-actions-${name}.json" (builtins.toJSON value)
      ) policy;
      yaml = (pkgs.formats.yaml { }).generate "actions-policy.yml" policy;
      application = pkgs.writeShellApplication {
        name = "github-actions-policy";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gh
          pkgs.jq
        ];
        text = ''
          # No auth setup, implicit repository, or default mutation action.
          set -E
          if [[ $# != 3 || ( "$1" != plan && "$1" != apply ) || "$2" != --repo ]]; then
            printf '%s\n' 'Usage: github-actions-policy {plan|apply} --repo OWNER/NAME' >&2
            exit 2
          fi
          action=$1
          repo=$3
          if [[ ! "$repo" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9_.-]+$ ||
                "''${repo#*/}" == . || "''${repo#*/}" == .. ]]; then
            printf '%s\n' 'Repository must be an explicit OWNER/NAME on github.com.' >&2
            exit 2
          fi

          umask 077
          tmp=$(mktemp -d)
          trap 'rm -rf -- "$tmp"' EXIT
          stage='reading repository policy'
          writes_started=false
          failed() {
            printf 'github-actions-policy: failed while %s (status %s).\n' "$stage" "$1" >&2
            if [[ "$writes_started" == true ]]; then
              printf '%s\n' 'Policy may be partially applied; no rollback attempted. Inspect with plan before retrying.' >&2
            fi
            exit "$1"
          }
          trap 'failed "$?"' ERR

          api() {
            gh api --hostname github.com \
              -H 'Accept: application/vnd.github+json' \
              -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
          }
          read_permissions() {
            stage='reading actions permissions'
            api --method GET "repos/$repo/actions/permissions" > "$tmp/raw.json"
            stage='validating actions permissions (all owned fields must be available)'
            jq -s -e '
              if length == 1 then .[0] else error("expected one API object") end |
              if type == "object" and (.enabled | type == "boolean") and
                 (.sha_pinning_required | type == "boolean") and
                 (.allowed_actions == "all" or .allowed_actions == "local_only" or .allowed_actions == "selected")
              then {enabled, allowed_actions, sha_pinning_required}
              else error("unsupported permissions response: missing or invalid owned fields") end
            ' "$tmp/raw.json" > "$tmp/permissions.json"
          }
          read_selected() {
            # GitHub only supports this GET in selected mode. Inactive is unknown,
            # not an empty allowlist, and a failed supported GET is never ignored.
            if [[ $(jq -r .allowed_actions "$tmp/permissions.json") != selected ]]; then
              printf '%s\n' null > "$tmp/selected-actions.json"
              return
            fi
            stage='reading selected actions'
            api --method GET "repos/$repo/actions/permissions/selected-actions" > "$tmp/raw.json"
            stage='validating selected actions'
            jq -s -e '
              if length == 1 then .[0] else error("expected one API object") end |
              if type == "object" and (.github_owned_allowed | type == "boolean") and
                 (.verified_allowed | type == "boolean") and (.patterns_allowed | type == "array") and
                 (.patterns_allowed | all(.[]; type == "string" and length > 0))
              then {github_owned_allowed, verified_allowed, patterns_allowed: (.patterns_allowed | sort | unique)}
              else error("unsupported selected-actions response: missing or invalid owned fields") end
            ' "$tmp/raw.json" > "$tmp/selected-actions.json"
          }
          read_workflow() {
            stage='reading workflow defaults'
            api --method GET "repos/$repo/actions/permissions/workflow" > "$tmp/raw.json"
            stage='validating workflow defaults'
            jq -s -e '
              if length == 1 then .[0] else error("expected one API object") end |
              if type == "object" and
                 (.default_workflow_permissions == "read" or .default_workflow_permissions == "write") and
                 (.can_approve_pull_request_reviews | type == "boolean")
              then {default_workflow_permissions, can_approve_pull_request_reviews}
              else error("unsupported workflow response: missing or invalid owned fields") end
            ' "$tmp/raw.json" > "$tmp/workflow.json"
          }
          snapshot() {
            read_permissions
            read_selected
            read_workflow
            jq -S -n --slurpfile permissions "$tmp/permissions.json" \
              --slurpfile selected "$tmp/selected-actions.json" \
              --slurpfile workflow "$tmp/workflow.json" \
              '{permissions: $permissions[0], "selected-actions": $selected[0], workflow: $workflow[0]}' \
              > "$tmp/current.json"
          }
          put() {
            stage="updating $1"
            writes_started=true
            api --method PUT "repos/$repo/actions/permissions$2" --input "$3" > /dev/null
          }
          equal() {
            jq -e -n --slurpfile actual "$1" --slurpfile expected "$2" \
              '$actual == $expected' > /dev/null
          }
          report_drift() {
            printf 'Policy drift for %s (inactive selected-actions is null):\n' "$repo"
            jq -n --slurpfile current "$tmp/current.json" --slurpfile desired "$tmp/desired.json" \
              '{current: $current[0], desired: $desired[0]}'
          }

          jq -S '."selected-actions".patterns_allowed |= (sort | unique)' ${desired} > "$tmp/desired.json"
          stage='reading repository visibility'
          api --method GET "repos/$repo" > "$tmp/repository.json"
          stage='requiring a public repository for action pattern allowlists'
          jq -s -e '
            if length == 1 and (.[0] | type == "object") and .[0].private == false
            then true else error("action pattern allowlists require a public repository") end
          ' "$tmp/repository.json" > /dev/null
          snapshot
          if equal "$tmp/current.json" "$tmp/desired.json"; then
            printf 'Policy matches %s.\n' "$repo"
            exit 0
          fi
          if [[ "$action" == plan ]]; then
            report_drift
            exit 1
          fi

          # Enter selected mode before its endpoint is available. Do not enable
          # disabled Actions until the allowlist and workflow defaults are set.
          jq --argjson enabled "$(jq .enabled "$tmp/permissions.json")" \
            '.enabled = $enabled' ${inputs.permissions} > "$tmp/transition.json"
          if ! equal "$tmp/permissions.json" "$tmp/transition.json"; then
            put 'actions permissions (retaining enabled state)' "" "$tmp/transition.json"
            read_permissions
            if ! equal "$tmp/permissions.json" "$tmp/transition.json"; then
              printf '%s\n' 'Mode transition did not persist; policy may be partially applied. No rollback attempted.' >&2
              exit 1
            fi
            read_selected
          fi
          jq -S '.patterns_allowed |= (sort | unique)' ${inputs.selected-actions} > "$tmp/desired-selected.json"
          if ! equal "$tmp/selected-actions.json" "$tmp/desired-selected.json"; then
            put 'selected actions' /selected-actions ${inputs.selected-actions}
          fi
          if ! equal "$tmp/workflow.json" ${inputs.workflow}; then
            put 'workflow defaults' /workflow ${inputs.workflow}
          fi
          # A successful PUT is not proof of effective policy. Verify restrictive
          # settings before enabling a previously disabled repository.
          read_selected
          read_workflow
          if ! equal "$tmp/selected-actions.json" "$tmp/desired-selected.json" ||
             ! equal "$tmp/workflow.json" ${inputs.workflow}; then
            printf '%s\n' 'Selected actions or workflow defaults did not persist; policy may be partially applied. No rollback attempted.' >&2
            exit 1
          fi
          if ! equal "$tmp/permissions.json" ${inputs.permissions}; then
            put 'final actions permissions' "" ${inputs.permissions}
          fi
          snapshot
          if ! equal "$tmp/current.json" "$tmp/desired.json"; then
            printf '%s\n' 'Readback differs; policy may be partially applied. No rollback attempted.' >&2
            report_drift
            exit 1
          fi
          printf 'Policy applied and verified for %s.\n' "$repo"
        '';
      };
    in
    {
      files.file.".github/actions-policy.yml".text = ''
        # Generated from modules/flake/github-actions.nix; GitHub does not auto-read this file.
        # Inspect: nix run .#github-actions-policy -- plan --repo OWNER/NAME
        # Reconcile only with owner approval: nix run .#github-actions-policy -- apply --repo OWNER/NAME
      ''
      + builtins.readFile yaml;
      packages.github-actions-policy = application;
      apps.github-actions-policy = {
        type = "app";
        program = lib.getExe application;
      };
      checks.github-actions-policy-arguments = pkgs.runCommand "github-actions-policy-arguments" { } ''
        if ${lib.getExe application} apply; then
          exit 1
        else
          test "$?" -eq 2
        fi
        if ${lib.getExe application} apply --repo https://github.com/owner/repo; then
          exit 1
        else
          test "$?" -eq 2
        fi
        touch "$out"
      '';
    };
}
