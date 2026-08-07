{
  den,
  lib,
  ...
}:
let
  inherit (lib) mkEnableOption mkOption types;

  targetType = types.submodule {
    options = {
      user = mkOption {
        type = types.str;
        description = "Unix account owning this workload's rootless Podman storage.";
      };
      home = mkOption {
        type = types.str;
        description = "Standalone Home Manager profile to activate.";
      };
      service = mkOption {
        type = types.str;
        description = "Quadlet-generated user service to restart and verify.";
      };
    };
  };
in
{
  # The deployer is deliberately a host workload, not a capability granted to
  # either Hermes account. It holds the deploy credential and performs the
  # controlled QA -> prod transition on their behalf.
  den.aspects.workloads.hermes.deploy = {
    persist = [ "/var/lib/hermes-deploy" ];

    settings = {
      enable = mkEnableOption "the manual, QA-gated Hermes deploy service";

      repository = mkOption {
        type = types.str;
        default = "https://github.com/dvicory/homelab.git";
        description = "Git repository containing the deployable flake.";
      };

      branch = mkOption {
        type = types.str;
        default = "main";
        description = "Primary branch fetched by hermes-deploy@main.";
      };

      qa = mkOption {
        type = targetType;
        default = {
          user = "hermes-qa-runner";
          home = "hermes-qa-runner@hvn-hyp1";
          service = "hermes-qa";
        };
        description = "QA workload deployment target.";
      };

      prod = mkOption {
        type = targetType;
        default = {
          user = "hermes-prod-runner";
          home = "hermes-prod-runner@hvn-hyp1";
          service = "hermes-prod";
        };
        description = "Production workload deployment target.";
      };

      canary = {
        attempts = mkOption {
          type = types.ints.positive;
          default = 6;
          description = "Number of readiness checks before declaring a canary failed.";
        };
        intervalSeconds = mkOption {
          type = types.ints.positive;
          default = 5;
          description = "Delay between readiness checks.";
        };
        command = mkOption {
          type = types.listOf types.str;
          default = [
            "hermes"
            "-z"
            "Reply with exactly CANARY_OK and nothing else"
          ];
          description = "Command executed inside the running Hermes container for the functional canary.";
        };
      };

      timeouts = {
        gitSeconds = mkOption {
          type = types.ints.positive;
          default = 120;
          description = "Timeout for each authenticated Git network operation.";
        };
        flakeCheckSeconds = mkOption {
          type = types.ints.positive;
          default = 900;
          description = "Timeout for nix flake check.";
        };
        imageBuildSeconds = mkOption {
          type = types.ints.positive;
          default = 1800;
          description = "Timeout for building the Hermes OCI archive.";
        };
        imageLoadSeconds = mkOption {
          type = types.ints.positive;
          default = 300;
          description = "Timeout for loading the OCI archive into one user's Podman storage.";
        };
        homeManagerSeconds = mkOption {
          type = types.ints.positive;
          default = 600;
          description = "Timeout for one standalone Home Manager activation.";
        };
        serviceStartSeconds = mkOption {
          type = types.ints.positive;
          default = 180;
          description = "Timeout for ensuring one Quadlet service is started.";
        };
        canarySeconds = mkOption {
          type = types.ints.positive;
          default = 120;
          description = "Timeout for the functional Hermes canary command.";
        };
        deploymentSeconds = mkOption {
          type = types.ints.positive;
          default = 3600;
          description = "Hard systemd timeout for the complete QA-to-prod deployment.";
        };
      };

      polling = {
        enable = mkEnableOption "periodic deployment of new commits from the primary branch";
        interval = mkOption {
          type = types.str;
          default = "2m";
          description = "systemd duration between primary-branch polls.";
        };
        randomizedDelay = mkOption {
          type = types.str;
          default = "30s";
          description = "Maximum randomized delay added to each poll.";
        };
      };
    };

    nixos =
      { host, pkgs, ... }:
      let
        cfg = host.settings.workloads.hermes.deploy;
        secretName = "hermes-deploy-pat";
        secretFile = host.secretPath + "/${secretName}.age";
        deployTokenPath = "/run/agenix/${secretName}";
        canaryArgs = lib.escapeShellArgs cfg.canary.command;
        gitAskPass = pkgs.writeShellScript "hermes-deploy-git-askpass" ''
          case "$1" in
            *Username*) printf '%s' x-access-token ;;
            *) printf '%s' "$GITHUB_TOKEN" ;;
          esac
        '';

        deployScript = pkgs.writeShellApplication {
          name = "hermes-deploy";
          runtimeInputs = with pkgs; [
            coreutils
            git
            gnugrep
            jq
            nix
            podman
            systemd
            util-linux
          ];
          text = ''
            set -euo pipefail

            state_dir=/var/lib/hermes-deploy
            repo="$state_dir/homelab"
            images_dir="$state_dir/images"
            releases_dir="$state_dir/releases"
            poll_hold="$state_dir/poll-hold.json"
            token_file=${lib.escapeShellArg deployTokenPath}
            repository=${lib.escapeShellArg cfg.repository}
            branch=${lib.escapeShellArg cfg.branch}
            requested="''${1:-main}"

            log() {
              printf 'hermes-deploy: %s\n' "$*" >&2
            }

            write_poll_hold() {
              local source=$1
              local revision=$2
              local reason=$3
              jq -n \
                --arg source "$source" \
                --arg revision "$revision" \
                --arg reason "$reason" \
                --arg timestamp "$(date --iso-8601=seconds)" \
                '{ source: $source, revision: $revision, reason: $reason, timestamp: $timestamp }' \
                > "$poll_hold.tmp"
              mv "$poll_hold.tmp" "$poll_hold"
            }

            mkdir -p "$images_dir" "$releases_dir"
            if [ "$requested" != main ] && [ ! -e "$poll_hold" ]; then
              write_poll_hold "$requested" "" "manual non-main deployment requested"
              log "placed polling on hold for manual deployment '$requested'"
            fi
            exec 9>"$state_dir/deploy.lock"
            if ! flock -n 9; then
              log "another deployment already holds $state_dir/deploy.lock"
              exit 1
            fi
            log "starting requested deploy '$requested'"

            if [ ! -r "$token_file" ]; then
              log "missing deploy credential: $token_file"
              exit 1
            fi

            export GITHUB_TOKEN
            GITHUB_TOKEN=$(<"$token_file")
            trap 'unset GITHUB_TOKEN' EXIT

            git_auth() {
              GIT_ASKPASS=${lib.escapeShellArg gitAskPass} GIT_TERMINAL_PROMPT=0 \
                timeout --signal=TERM --kill-after=15s ${toString cfg.timeouts.gitSeconds}s git "$@"
            }

            if [ ! -d "$repo/.git" ]; then
              log "cloning deployment checkout from $repository"
              git_auth clone --no-checkout "$repository" "$repo"
            fi
            git -C "$repo" remote set-url origin "$repository"
            case "$requested" in
              main)
                log "fetching primary branch '$branch'"
                git_auth -C "$repo" fetch --force origin "+refs/heads/$branch:refs/remotes/origin/$branch"
                revision=$(git -C "$repo" rev-parse "origin/$branch^{commit}")
                ;;
              *[!0123456789abcdefABCDEF]* | ? | ?? | ??? | ???? | ????? | ??????)
                echo "Deploy reference must be main or at least seven hexadecimal commit characters." >&2
                exit 2
                ;;
              *)
                # A root-only wrapper resolves a branch to an immutable SHA
                # before starting this service. Fetch every branch so that
                # commit can be found even when it is not reachable from main.
                log "resolving manual commit '$requested' across origin branches"
                git_auth -C "$repo" fetch --force origin "+refs/heads/*:refs/remotes/origin/*"
                revision=$(git -C "$repo" rev-parse --verify "$requested^{commit}")
                ;;
            esac
            log "resolved '$requested' to revision $revision"
            if [ "$requested" != main ]; then
              hold_source=$(jq -r '.source // empty' "$poll_hold" 2>/dev/null || true)
              hold_revision=$(jq -r '.revision // empty' "$poll_hold" 2>/dev/null || true)
              if [ -z "$hold_source" ] || [ -n "$hold_revision" ]; then
                hold_source="$requested"
              fi
              write_poll_hold "$hold_source" "$revision" "manual non-main deployment in progress"
            fi

            checkout_revision() {
              local target=$1
              log "checking out revision $target"
              git -C "$repo" checkout --detach --force "$target" || return 1
              git -C "$repo" clean -ffd || return 1
            }

            archive_for() {
              local target=$1
              printf '%s/%s' "$images_dir" "$target"
            }

            release_source_for() {
              local target=$1
              local user=$2
              local release_parent
              local release_source="$releases_dir/$target/$user"
              local staging_source

              if [ ! -d "$release_source/.git" ]; then
                log "$user: materializing user-owned release source for $target"
                if [ -e "$release_source" ]; then
                  log "$user: incomplete release source exists at $release_source"
                  return 1
                fi
                release_parent=$(dirname "$release_source")
                mkdir -p "$release_parent" || return 1
                staging_source=$(mktemp -d "$release_parent/.''${user}.XXXXXX") || return 1
                cp -a "$repo/." "$staging_source" || return 1
                chown -R "$user:$user" "$staging_source" || return 1
                mv "$staging_source" "$release_source" || return 1
              fi
              printf '%s' "$release_source"
            }

            as_user() {
              local user=$1
              local uid
              shift
              uid=$(id -u "$user")
              runuser --user "$user" --preserve-environment -- env \
                -u GITHUB_TOKEN \
                HOME="/home/$user" \
                USER="$user" \
                XDG_RUNTIME_DIR="/run/user/$uid" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
                PATH="/etc/profiles/per-user/$user/bin:/run/current-system/sw/bin" \
                "$@"
            }

            refresh_user_manager_groups() {
              local user=$1
              local uid
              local manager_unit
              local manager_pid
              local expected
              local actual=
              local key
              local value
              local gid
              local candidate
              local found
              local groups_match=true
              uid=$(id -u "$user") || return 1
              manager_unit="user@$uid.service"
              expected=$(id -G "$user") || return 1
              manager_pid=$(systemctl show --property=MainPID --value "$manager_unit") || {
                log "$user: could not inspect user manager"
                return 1
              }
              if [ "$manager_pid" != 0 ] && [ -r "/proc/$manager_pid/status" ]; then
                while IFS=: read -r key value; do
                  if [ "$key" = Groups ]; then
                    actual=$value
                    break
                  fi
                done < "/proc/$manager_pid/status"
              fi
              for gid in $expected; do
                found=false
                for candidate in $actual; do
                  [ "$candidate" = "$gid" ] && found=true
                done
                [ "$found" = true ] || groups_match=false
              done
              for gid in $actual; do
                found=false
                for candidate in $expected; do
                  [ "$candidate" = "$gid" ] && found=true
                done
                [ "$found" = true ] || groups_match=false
              done
              if [ "$groups_match" = false ]; then
                log "$user: restarting user manager to refresh supplementary groups"
                ${pkgs.coreutils}/bin/timeout --signal=TERM --kill-after=15s \
                  ${toString cfg.timeouts.serviceStartSeconds}s \
                  systemctl restart "$manager_unit" || {
                  log "$user: user manager group refresh failed or timed out"
                  return 1
                }
              fi
            }


            activate() {
              local target=$1
              local user=$2
              local home=$3
              local service=$4
              local archive
              local release_source
              local active_before
              local active_after
              local systemd_action
              archive=$(archive_for "$target")
              refresh_user_manager_groups "$user" || return 1

              if [ ! -e "$archive" ]; then
                log "$service: no retained image archive for $target"
                return 1
              fi

              log "$service: loading image into $user's Podman storage"
              as_user "$user" ${pkgs.coreutils}/bin/timeout \
                --signal=TERM --kill-after=15s ${toString cfg.timeouts.imageLoadSeconds}s \
                podman load --input "$archive" || {
                log "$service: image load failed or timed out for $user"
                return 1
              }
              release_source=$(release_source_for "$target" "$user") || {
                log "$service: could not prepare a release source for $user"
                return 1
              }
              active_before=$(systemctl --machine="$user@" --user show \
                --property=ActiveEnterTimestampMonotonic --value "$service") || {
                log "$service: could not inspect service activation state"
                return 1
              }
              log "$service: switching Home Manager profile $home"
              as_user "$user" ${pkgs.coreutils}/bin/timeout \
                --signal=TERM --kill-after=30s ${toString cfg.timeouts.homeManagerSeconds}s \
                "/etc/profiles/per-user/$user/bin/home-manager" \
                switch --flake "$release_source#$home" || {
                log "$service: Home Manager activation failed or timed out for $user"
                return 1
              }
              # Home Manager restarts Quadlets when their generated unit
              # changes. Avoid interrupting that fresh container a second time,
              # but recreate an unchanged active container so an atomically
              # replaced agenix secret bind mount is picked up as well.
              if systemctl --machine="$user@" --user --quiet is-active "$service"; then
                active_after=$(systemctl --machine="$user@" --user show \
                  --property=ActiveEnterTimestampMonotonic --value "$service") || {
                  log "$service: could not inspect service activation state"
                  return 1
                }
                if [ "$active_before" != "$active_after" ]; then
                  log "$service: Home Manager already started or restarted Quadlet"
                  return 0
                fi
                systemd_action=restart
              else
                systemd_action=start
              fi
              log "$service: $systemd_action Quadlet service to apply deployment inputs"
              timeout --signal=TERM --kill-after=15s ${toString cfg.timeouts.serviceStartSeconds}s \
                systemctl --machine="$user@" --user "$systemd_action" "$service" || {
                log "$service: systemd $systemd_action failed or timed out"
                return 1
              }
            }

            wait_until_active() {
              local user=$1
              local service=$2
              local remaining_attempts=${toString cfg.canary.attempts}
              log "$service: waiting for systemd readiness ($remaining_attempts attempts)"
              while [ "$remaining_attempts" -gt 0 ]; do
                if systemctl --machine="$user@" --user --quiet is-active "$service"; then
                  return 0
                fi
                remaining_attempts=$((remaining_attempts - 1))
                if [ "$remaining_attempts" -gt 0 ]; then
                  sleep ${toString cfg.canary.intervalSeconds}
                fi
              done
              log "$service: did not become active for $user"
              return 1
            }

            canary() {
              local user=$1
              local service=$2
              local container
              local canary_output

              wait_until_active "$user" "$service" || return 1
              container=$(as_user "$user" podman ps \
                --filter "label=PODMAN_SYSTEMD_UNIT=$service.service" \
                --format '{{.ID}}' | head -n 1) || return 1
              if [ -z "$container" ]; then
                container=$(as_user "$user" podman ps \
                  --filter "name=$service" \
                  --format '{{.ID}}' | head -n 1) || return 1
              fi
              if [ -z "$container" ]; then
                log "$service: could not find its running Quadlet container"
                return 1
              fi

              log "$service: running functional canary in container $container"
              canary_output=$(as_user "$user" ${pkgs.coreutils}/bin/timeout \
                --signal=TERM --kill-after=15s ${toString cfg.timeouts.canarySeconds}s \
                podman exec "$container" ${canaryArgs}) || {
                log "$service: functional canary command failed or timed out"
                return 1
              }
              if [ "$canary_output" != "CANARY_OK" ]; then
                log "$service: functional canary returned '$canary_output' instead of CANARY_OK"
                return 1
              fi
              log "$service: functional canary passed"
            }

            write_result() {
              local status=$1
              local stage=$2
              local deployed_revision=$3
              jq -n \
                --arg status "$status" \
                --arg stage "$stage" \
                --arg revision "$deployed_revision" \
                --arg source "$requested" \
                --arg timestamp "$(date --iso-8601=seconds)" \
                '{ status: $status, stage: $stage, revision: $revision, source: $source, timestamp: $timestamp }' \
                > "$state_dir/latest.json.tmp"
              mv "$state_dir/latest.json.tmp" "$state_dir/latest.json"
              printf '%s %s\n' "$deployed_revision" "$status" > "$state_dir/last-attempt"
            }

            rollback() {
              local role=$1
              local user=$2
              local home=$3
              local service=$4
              local previous_file="$state_dir/$role-current"
              local previous

              if [ ! -s "$previous_file" ]; then
                log "$role: no previous revision is recorded; manual recovery is required"
                return 0
              fi
              previous=$(<"$previous_file")
              log "$role: rolling back to $previous"
              checkout_revision "$previous" || return 1
              activate "$previous" "$user" "$home" "$service" || return 1
              log "$role: rollback activation completed"
            }

            if ! checkout_revision "$revision"; then
              write_result failed checkout "$revision"
              exit 1
            fi
            log "running nix flake check (repo-provided nixConfig remains intentionally untrusted)"
            if ! timeout --signal=TERM --kill-after=30s ${toString cfg.timeouts.flakeCheckSeconds}s \
              nix flake check "$repo"; then
              log "nix flake check failed or timed out"
              write_result failed flake-check "$revision"
              exit 1
            fi
            archive=$(archive_for "$revision")
            log "building Hermes OCI image once at $archive"
            if ! timeout --signal=TERM --kill-after=30s ${toString cfg.timeouts.imageBuildSeconds}s \
              nix build --out-link "$archive" "$repo#hermes-agent-image"; then
              log "Hermes OCI image build failed or timed out"
              write_result failed image-build "$revision"
              exit 1
            fi

            if ! activate "$revision" ${lib.escapeShellArg cfg.qa.user} ${lib.escapeShellArg cfg.qa.home} ${lib.escapeShellArg cfg.qa.service}; then
              log "QA activation failed; production will not be touched"
              rollback qa ${lib.escapeShellArg cfg.qa.user} ${lib.escapeShellArg cfg.qa.home} ${lib.escapeShellArg cfg.qa.service}
              write_result failed qa-activation "$revision"
              exit 1
            fi
            if ! canary ${lib.escapeShellArg cfg.qa.user} ${lib.escapeShellArg cfg.qa.service}; then
              log "QA canary failed; production will not be touched"
              rollback qa ${lib.escapeShellArg cfg.qa.user} ${lib.escapeShellArg cfg.qa.home} ${lib.escapeShellArg cfg.qa.service}
              write_result failed qa-canary "$revision"
              exit 1
            fi
            printf '%s\n' "$revision" > "$state_dir/qa-current"
            log "QA accepted revision $revision; promoting to production"

            if ! activate "$revision" ${lib.escapeShellArg cfg.prod.user} ${lib.escapeShellArg cfg.prod.home} ${lib.escapeShellArg cfg.prod.service}; then
              log "production activation failed; attempting production rollback"
              rollback prod ${lib.escapeShellArg cfg.prod.user} ${lib.escapeShellArg cfg.prod.home} ${lib.escapeShellArg cfg.prod.service}
              write_result failed prod-activation "$revision"
              exit 1
            fi
            if ! canary ${lib.escapeShellArg cfg.prod.user} ${lib.escapeShellArg cfg.prod.service}; then
              log "production canary failed; attempting production rollback"
              rollback prod ${lib.escapeShellArg cfg.prod.user} ${lib.escapeShellArg cfg.prod.home} ${lib.escapeShellArg cfg.prod.service}
              write_result failed prod-canary "$revision"
              exit 1
            fi
            printf '%s\n' "$revision" > "$state_dir/prod-current"
            write_result success prod "$revision"
            if [ "$requested" = main ] && [ -e "$poll_hold" ]; then
              rm -f "$poll_hold"
              log "cleared polling hold after successful main deployment"
            fi
            log "deployment of $revision completed successfully"
          '';
        };

        pollScript = pkgs.writeShellApplication {
          name = "hermes-deploy-poll";
          runtimeInputs = with pkgs; [
            coreutils
            git
            jq
            systemd
            util-linux
          ];
          text = ''
            set -euo pipefail

            state_dir=/var/lib/hermes-deploy
            poll_hold="$state_dir/poll-hold.json"
            token_file=${lib.escapeShellArg deployTokenPath}
            repository=${lib.escapeShellArg cfg.repository}
            branch=${lib.escapeShellArg cfg.branch}

            log() {
              printf 'hermes-deploy-poll: %s\n' "$*" >&2
            }

            exec 9>"$state_dir/deploy.lock"
            if ! flock -n 9; then
              log "deployment already running; skipping this poll"
              exit 0
            fi
            if [ -e "$poll_hold" ]; then
              log "polling is held: $(cat "$poll_hold")"
              exit 0
            fi
            if [ ! -r "$token_file" ]; then
              log "missing deploy credential: $token_file"
              exit 1
            fi

            export GITHUB_TOKEN
            GITHUB_TOKEN=$(<"$token_file")
            trap 'unset GITHUB_TOKEN' EXIT

            remote_line=$(GIT_ASKPASS=${lib.escapeShellArg gitAskPass} GIT_TERMINAL_PROMPT=0 \
              timeout --signal=TERM --kill-after=15s ${toString cfg.timeouts.gitSeconds}s \
              git ls-remote "$repository" "refs/heads/$branch") || {
              log "failed or timed out while reading origin/$branch"
              exit 1
            }
            latest_revision="''${remote_line%%[[:space:]]*}"
            if [[ ! "$latest_revision" =~ ^[0123456789abcdefABCDEF]{40}$ ]]; then
              log "origin/$branch returned an invalid revision '$latest_revision'"
              exit 1
            fi

            last_revision=""
            if [ -s "$state_dir/last-attempt" ]; then
              read -r last_revision _ < "$state_dir/last-attempt" || true
            fi
            if [ "$latest_revision" = "$last_revision" ]; then
              log "origin/$branch remains at already-attempted revision $latest_revision"
              exit 0
            fi

            log "origin/$branch advanced from ''${last_revision:-<none>} to $latest_revision"
            flock -u 9
            systemctl start --no-block hermes-deploy@main.service
            log "queued hermes-deploy@main.service"
          '';
        };

        deployCtl = pkgs.writeShellApplication {
          name = "hermes-deployctl";
          runtimeInputs = with pkgs; [
            coreutils
            git
            jq
            systemd
          ];
          text = ''
            set -euo pipefail

            state_dir=/var/lib/hermes-deploy
            poll_hold="$state_dir/poll-hold.json"
            token_file=${lib.escapeShellArg deployTokenPath}
            repository=${lib.escapeShellArg cfg.repository}

            require_root() {
              if [ "$EUID" -ne 0 ]; then
                echo "Run this command with sudo." >&2
                exit 1
              fi
            }

            write_poll_hold() {
              local source=$1
              local revision=$2
              local reason=$3
              mkdir -p "$state_dir"
              jq -n \
                --arg source "$source" \
                --arg revision "$revision" \
                --arg reason "$reason" \
                --arg timestamp "$(date --iso-8601=seconds)" \
                '{ source: $source, revision: $revision, reason: $reason, timestamp: $timestamp }' \
                > "$poll_hold.tmp"
              mv "$poll_hold.tmp" "$poll_hold"
            }

            resolve_branch() {
              local source=$1
              local remote_line
              local revision

              if [ ! -r "$token_file" ]; then
                echo "Missing deploy credential: $token_file" >&2
                return 1
              fi
              export GITHUB_TOKEN
              GITHUB_TOKEN=$(<"$token_file")
              remote_line=$(GIT_ASKPASS=${lib.escapeShellArg gitAskPass} GIT_TERMINAL_PROMPT=0 \
                timeout --signal=TERM --kill-after=15s ${toString cfg.timeouts.gitSeconds}s \
                git ls-remote "$repository" "refs/heads/$source") || return 1
              revision="''${remote_line%%[[:space:]]*}"
              if [[ ! "$revision" =~ ^[0123456789abcdefABCDEF]{40}$ ]]; then
                echo "Branch '$source' was not found on origin." >&2
                return 1
              fi
              printf '%s' "$revision"
            }

            usage() {
              cat <<'EOF'
            Usage:
              hermes-deployctl deploy [main|branch]
              hermes-deployctl hold [reason]
              hermes-deployctl resume
              hermes-deployctl status
              hermes-deployctl logs [main|commit]
              hermes-deployctl timer <start|stop|status>
            EOF
            }

            command="''${1:-status}"
            if [ "$#" -gt 0 ]; then shift; fi
            case "$command" in
              deploy)
                require_root
                ref="''${1:-main}"
                if [[ ! "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
                  echo "Deploy branch contains unsupported characters." >&2
                  exit 2
                fi
                if [ "$ref" = main ]; then
                  deployment_ref=main
                else
                  deployment_ref=$(resolve_branch "$ref") || exit 1
                  write_poll_hold "$ref" "$deployment_ref" "manual deployment queued by operator"
                  echo "Polling is now held until a successful main deploy or 'hermes-deployctl resume'."
                fi
                systemctl start --no-block "hermes-deploy@$deployment_ref.service"
                echo "Queued hermes-deploy@$deployment_ref.service"
                ;;
              hold)
                require_root
                reason="''${*:-manual operator hold}"
                write_poll_hold operator "" "$reason"
                echo "Polling is held."
                ;;
              resume)
                require_root
                rm -f "$poll_hold"
                echo "Polling hold cleared."
                ;;
              status)
                echo "Deployment state:"
                for file in poll-hold.json latest.json last-attempt qa-current prod-current; do
                  if [ -e "$state_dir/$file" ]; then
                    printf '\n%s:\n' "$file"
                    cat "$state_dir/$file"
                  fi
                done
                printf '\n\nUnits:\n'
                systemctl --no-pager --full status hermes-deploy@main.service hermes-deploy-poll.timer || true
                ;;
              logs)
                ref="''${1:-main}"
                exec journalctl -fu "hermes-deploy@$ref.service"
                ;;
              timer)
                require_root
                action="''${1:-status}"
                case "$action" in
                  start|stop|restart) systemctl "$action" hermes-deploy-poll.timer ;;
                  status) systemctl --no-pager --full status hermes-deploy-poll.timer || true ;;
                  *) usage; exit 2 ;;
                esac
                ;;
              help|-h|--help)
                usage
                ;;
              *)
                usage
                exit 2
                ;;
            esac
          '';
        };
      in
      lib.mkIf cfg.enable {
        secretRequests = lib.optionalAttrs (builtins.pathExists secretFile) {
          ${secretName} = {
            provider = "agenix";
            ageFile = secretFile;
            mode = "0400";
          };
        };

        systemd.services."hermes-deploy@" = {
          description = "Deploy Hermes revision %i through QA before production";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          unitConfig.ConditionPathExists = deployTokenPath;
          path = [ deployScript ];
          serviceConfig = {
            Type = "oneshot";
            StateDirectory = "hermes-deploy";
            StateDirectoryMode = "0755";
            TimeoutStartSec = "${toString cfg.timeouts.deploymentSeconds}s";
            UMask = "0022";
            ExecStart = "${deployScript}/bin/hermes-deploy %i";
          };
        };

        systemd.services.hermes-deploy-poll = lib.mkIf cfg.polling.enable {
          description = "Poll the primary Hermes branch for a new deployment";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          unitConfig.ConditionPathExists = deployTokenPath;
          serviceConfig = {
            Type = "oneshot";
            StateDirectory = "hermes-deploy";
            StateDirectoryMode = "0755";
            TimeoutStartSec = "${toString (cfg.timeouts.gitSeconds + 30)}s";
            UMask = "0022";
            ExecStart = "${pollScript}/bin/hermes-deploy-poll";
          };
        };

        systemd.timers.hermes-deploy-poll = lib.mkIf cfg.polling.enable {
          description = "Periodically poll the primary Hermes deployment branch";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5m";
            OnUnitActiveSec = cfg.polling.interval;
            RandomizedDelaySec = cfg.polling.randomizedDelay;
            Persistent = true;
          };
        };

        environment.systemPackages = [ deployCtl ];
      };
  };
}
