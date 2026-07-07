# Hermes Agent running as a native systemd service inside a MicroVM guest.
#
# This is the MicroVM counterpart to the nspawn-based `services.hermes`
# aspect. Use this aspect for hermes-prod/qa guest hosts (MicroVMs on
# hvn-hyp1). The nspawn aspect is used by hvn-hyp1 directly.
#
# Differences from the nspawn aspect:
# - No containers.hermes block — the MicroVM IS the isolation boundary
# - Adds workspace clone + gh auth + git config bootstrap oneshots
# - Adds extraPackages support (agent can PR adding packages to itself)
# - Secrets arrive via virtiofs share (per-VM agenix symlink farm on host)
# - Persists agent state via impermanence (not a container rootfs)
#
# Provisioning (one-time, before the first deploy):
#   agenix edit .secrets/hosts/<host>/hermes-env.age
#     OPENROUTER_API_KEY=sk-or-...
#     TELEGRAM_BOT_TOKEN=...
#     TELEGRAM_ALLOWED_USERS=...
#   agenix edit .secrets/hosts/<host>/hermes-github-pat.age
#     ghp_...  (repo:write scope)
#   agenix rekey && git add .secrets && git commit
# Then deploy hvn-hyp1 — the MicroVM auto-provisions.
{ inputs, lib, ... }: {
  den.aspects.services.hermes-microvm = {
    settings.agent = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Hermes agent settings rendered to config.yaml (passed through to
        services.hermes-agent.settings). At minimum set model.default.
      '';
    };

    settings.dependencyGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Optional pyproject.toml dependency groups to build into the
        sealed venv. Set to [ "messaging" ] for Telegram/Discord/Slack.
      '';
    };

    settings.extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = ''
        Extra packages available to the agent. The agent can PR adding
        packages to itself.
      '';
    };

    settings.workspace.repo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/dvicory/homelab.git";
      description = "Git repo URL for the agent's workspace clone.";
    };

    settings.gitIdentity.name = lib.mkOption {
      type = lib.types.str;
      default = "Hermes Agent";
      description = "Git commit author name for the agent.";
    };

    settings.gitIdentity.email = lib.mkOption {
      type = lib.types.str;
      default = "hermes@localhost";
      description = "Git commit author email for the agent.";
    };

    nixos = { host, config, pkgs, lib, ... }: let
      agentSettings = host.settings.services.hermes-microvm.agent or { };
      dependencyGroups = host.settings.services.hermes-microvm.dependencyGroups or [ ];
      extraPackages = host.settings.services.hermes-microvm.extraPackages or [ ];
      workspaceRepo = host.settings.services.hermes-microvm.workspace.repo or
        "https://github.com/dvicory/homelab.git";
      gitName = host.settings.services.hermes-microvm.gitIdentity.name or "Hermes Agent";
      gitEmail = host.settings.services.hermes-microvm.gitIdentity.email or "hermes@localhost";
      secretName = "hermes-env";
      # host.secretPath resolves to .secrets/guests/<name>/ for MicroVM guests
      # (see the schema override in microvm-host.nix)
      ageFile = host.secretPath + "/hermes-env.age";
      patAgeFile = host.secretPath + "/hermes-github-pat.age";
      provisioned = builtins.pathExists ageFile;
      patProvisioned = builtins.pathExists patAgeFile;
    in {
      imports = [ inputs.hermes-agent.nixosModules.default ];

      config = lib.mkMerge [
        { nixpkgs.overlays = [ inputs.hermes-agent.overlays.default ]; }

        (lib.mkIf provisioned {
          secretRequests.${secretName} = {
            provider = "agenix";
            ageFile = ageFile;
            mode = "0400";
          };

          services.hermes-agent = {
            enable = true;
            addToSystemPackages = true;
            settings = agentSettings;
            extraDependencyGroups = dependencyGroups;
            extraPackages = extraPackages;
            environmentFiles = [ "/run/agenix/${secretName}" ];
          };

          networking.firewall.enable = false;
          system.stateVersion = "26.05";
        })

        (lib.mkIf (provisioned && patProvisioned) {
          secretRequests.hermes-github-pat = {
            provider = "agenix";
            ageFile = patAgeFile;
            mode = "0400";
          };

          # Bootstrap: clone workspace if missing, auth gh, set git identity.
          # Idempotent — safe to run on every boot.
          systemd.services.hermes-workspace-clone = {
            description = "Clone homelab workspace for agent";
            after = [ "hermes-agent.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            script = ''
              workspace="/var/lib/hermes/workspace/homelab"
              if [ ! -d "$workspace/.git" ]; then
                mkdir -p "$(dirname "$workspace")"
                git clone "${workspaceRepo}" "$workspace"
              fi
              cd "$workspace"
              git fetch origin
            '';
          };

          systemd.services.hermes-gh-auth = {
            description = "Authenticate gh CLI with PAT";
            after = [ "hermes-agent.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            script = ''
              pat=$(cat /run/agenix/hermes-github-pat)
              echo "$pat" | ${pkgs.gh}/bin/gh auth login --with-token
            '';
          };

          systemd.services.hermes-git-config = {
            description = "Set git identity for agent commits";
            after = [ "hermes-agent.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            script = ''
              git config --global user.name "${gitName}"
              git config --global user.email "${gitEmail}"
            '';
          };

          environment.systemPackages = with pkgs; [
            git gh nix jq
          ];
        })
      ];
    };

    persist = [
      "/var/lib/hermes/.hermes/skills"
      "/var/lib/hermes/.hermes/sessions"
      "/var/lib/hermes/.hermes/memories"
      "/var/lib/hermes/.hermes/cron"
      "/var/lib/hermes/workspace"
    ];
  };
}
