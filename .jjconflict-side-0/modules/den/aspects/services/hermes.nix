# Hermes Agent (https://hermes-agent.nousresearch.com) running in its
# *native* systemd-service mode, but isolated inside a declarative NixOS
# systemd-nspawn container for defence-in-depth. The container shares
# the host network namespace (the gateway only makes outbound
# connections to LLM / messaging APIs) and its rootfs + state persist at
# /var/lib/nixos-containers/hermes.
#
# Provisioning (one-time, before the first deploy that should start the
# container):
#   agenix edit .secrets/hosts/<host>/hermes-env.age
#     # at minimum one LLM provider key, e.g.
#     OPENROUTER_API_KEY=sk-or-...
#   agenix rekey && git add .secrets && git commit
# Then redeploy; the declarative nspawn container auto-provisions on
# activation. Until the secret exists the aspect is a no-op (gated on
# the .age file), so the host still builds. Manage the guest with:
#   nixos-container root-login hermes
#   journalctl -M hermes -u hermes-agent -f
{ inputs, lib, ... }: {
  flake-file.inputs.hermes-agent = {
    url = "github:NousResearch/hermes-agent/v2026.7.7.2";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.aspects.services.hermes = {
    settings.agent = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Hermes agent settings rendered to config.yaml inside the
        container (passed through to services.hermes-agent.settings).
        At minimum set model.default, e.g.
          { model.default = "anthropic/claude-sonnet-4"; }
      '';
    };

    settings.dependencyGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Optional pyproject.toml dependency groups to build into the
        sealed venv (passed to services.hermes-agent.extraDependencyGroups).
        Set to [ "messaging" ] to enable Telegram/Discord/Slack.
      '';
    };

    nixos = { host, config, lib, ... }: let
      agentSettings = host.settings.services.hermes.agent or { };
      dependencyGroups = host.settings.services.hermes.dependencyGroups or [ ];
      secretName = "hermes-env";
      ageFile = inputs.self + "/.secrets/hosts/${host.name}/hermes-env.age";
      provisioned = builtins.pathExists ageFile;
    in lib.mkIf provisioned {
      secretRequests.${secretName} = {
        provider = "agenix";
        inherit ageFile;
        mode = "0400";
      };

      containers.hermes = {
        autoStart = true;
        # Shared network namespace: outbound-only gateway traffic, so a
        # private veth + NAT would add complexity without isolation
        # benefit. Filesystem / process / capability isolation still
        # comes from systemd-nspawn.
        privateNetwork = false;

        bindMounts."/run/agenix/${secretName}" = {
          hostPath = config.age.secrets.${secretName}.path;
          isReadOnly = true;
        };

        config = { pkgs, ... }: {
          imports = [ inputs.hermes-agent.nixosModules.default ];
          nixpkgs.overlays = [ inputs.hermes-agent.overlays.default ];

          services.hermes-agent = {
            enable = true;
            # Native mode: container.enable is left false (default), so
            # the agent runs as a hardened systemd service *inside* this
            # nspawn NixOS rather than as a nested OCI container.
            addToSystemPackages = true;
            settings = agentSettings;
            extraDependencyGroups = dependencyGroups;
            environmentFiles = [ "/run/agenix/${secretName}" ];
          };

          # The host owns the firewall; avoid a duplicate ruleset in the
          # shared network namespace.
          networking.firewall.enable = false;
          system.stateVersion = "26.05";
        };
      };
    };

    persist = [ "/var/lib/nixos-containers/hermes" ];
  };
}
