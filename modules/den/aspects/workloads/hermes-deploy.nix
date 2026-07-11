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

      temporaryRefs = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Explicit, temporary deploy aliases. For example,
          { candidate = "feature/hermes-deploy"; } permits
          `systemctl start hermes-deploy@candidate`. Remove an alias once
          its branch has merged; arbitrary branch names are never accepted.
        '';
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
    };

    nixos =
      { host, pkgs, ... }:
      let
        cfg = host.settings.workloads.hermes.deploy;
        secretName = "hermes-deploy-pat";
        secretFile = host.secretPath + "/${secretName}.age";
        deployTokenPath = "/run/agenix/${secretName}";
        canaryArgs = lib.escapeShellArgs cfg.canary.command;
        temporaryRefCases = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            alias: ref: ''
              ${lib.escapeShellArg alias}) deployRef=${lib.escapeShellArg ref} ;;
            ''
          ) cfg.temporaryRefs
        );
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
            token_file=${lib.escapeShellArg deployTokenPath}
            repository=${lib.escapeShellArg cfg.repository}
            branch=${lib.escapeShellArg cfg.branch}
            requested="''${1:-main}"

            log() {
              printf 'hermes-deploy: %s\n' "$*" >&2
            }

            mkdir -p "$images_dir" "$releases_dir"
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
              GIT_ASKPASS=${lib.escapeShellArg gitAskPass} GIT_TERMINAL_PROMPT=0 git "$@"
            }

            if [ ! -d "$repo/.git" ]; then
              log "cloning deployment checkout from $repository"
              git_auth clone --no-checkout "$repository" "$repo"
            fi
            git -C "$repo" remote set-url origin "$repository"
            deployRef=""
            case "$requested" in
              main) deployRef="$branch" ;;
              ${temporaryRefCases}
              *[!0123456789abcdefABCDEF]* | ? | ?? | ??? | ???? | ????? | ??????)
                echo "Unknown deploy alias '$requested'. Use main or an explicitly configured temporary alias." >&2
                exit 2
                ;;
              *) deployRef="$branch" ;;
            esac
            if [ -n "$deployRef" ]; then
              log "fetching deploy alias '$requested' from branch '$deployRef'"
              git_auth -C "$repo" fetch --force origin "+refs/heads/$deployRef:refs/remotes/origin/$deployRef"
              revision=$(git -C "$repo" rev-parse "origin/$deployRef^{commit}")
            else
              log "resolving commit '$requested' from primary branch '$branch'"
              git_auth -C "$repo" fetch --force origin "+refs/heads/$branch:refs/remotes/origin/$branch"
              revision=$(git -C "$repo" rev-parse --verify "$requested^{commit}")
            fi
            log "resolved '$requested' to revision $revision"

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

            activate() {
              local target=$1
              local user=$2
              local home=$3
              local service=$4
              local archive
              local release_source
              archive=$(archive_for "$target")

              if [ ! -e "$archive" ]; then
                log "$service: no retained image archive for $target"
                return 1
              fi

              log "$service: loading image into $user's Podman storage"
              as_user "$user" podman load --input "$archive" || {
                log "$service: image load failed for $user"
                return 1
              }
              release_source=$(release_source_for "$target" "$user") || {
                log "$service: could not prepare a release source for $user"
                return 1
              }
              log "$service: switching Home Manager profile $home"
              as_user "$user" "/etc/profiles/per-user/$user/bin/home-manager" \
                switch --flake "$release_source#$home" || {
                log "$service: Home Manager activation failed for $user"
                return 1
              }
              log "$service: ensuring Quadlet service is active"
              systemctl --machine="$user@" --user start "$service" || {
                log "$service: systemd start failed"
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
              canary_output=$(as_user "$user" podman exec "$container" ${canaryArgs}) || {
                log "$service: functional canary command failed"
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
                --arg timestamp "$(date --iso-8601=seconds)" \
                '{ status: $status, stage: $stage, revision: $revision, timestamp: $timestamp }' \
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

            checkout_revision "$revision"
            log "running nix flake check (repo-provided nixConfig remains intentionally untrusted)"
            nix flake check "$repo"
            archive=$(archive_for "$revision")
            log "building Hermes OCI image once at $archive"
            nix build --out-link "$archive" "$repo#hermes-agent-image"

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
            log "deployment of $revision completed successfully"
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
            UMask = "0022";
            ExecStart = "${deployScript}/bin/hermes-deploy %i";
          };
        };
      };
  };
}
