{ inputs, den, lib, ... }:
{
  flake-file.inputs.quadlet-nix = {
    url = "github:SEIAROTg/quadlet-nix";
  };

  perSystem = { system, pkgs, ... }:
    let
      hermesPackage = (inputs.hermes-agent.packages.${system}.default).override {
        extraDependencyGroups = [ "messaging" ];
      };
      entrypoint = pkgs.runCommand "hermes-entrypoint" {} ''
        install -Dm555 ${pkgs.writeShellScript "hermes-entrypoint.sh" ''
          set -euo pipefail

          export HERMES_MANAGED=true
          mkdir -p "$HERMES_HOME"
          touch "$HERMES_HOME/.managed"

          if [ -f "$SECRETS_DIR/hermes-env" ]; then
            set -a; . "$SECRETS_DIR/hermes-env"; set +a
          fi

          if [ -f "$SECRETS_DIR/hermes-github-pat" ]; then
            PAT=$(cat "$SECRETS_DIR/hermes-github-pat")
            echo "$PAT" | gh auth login --with-token
            gh auth setup-git
            git config --global user.name "Hermes Agent"
            git config --global user.email "hermes-agent@users.noreply.github.com"
            if [ ! -d "$WORKSPACE_DIR/.git" ]; then
              mkdir -p "$WORKSPACE_DIR"
              git clone https://github.com/dvicory/homelab.git "$WORKSPACE_DIR"
            fi
            cd "$WORKSPACE_DIR"
            git fetch origin main || true
            unset PAT
          fi

          # plugins/cron/ (incomplete plugin category) shadows
          # site-packages/cron/ (complete package with
          # scheduler_provider.py) because platform adapters do
          # sys.path.insert(0, plugins_dir) at import time.
          # Delete it from the overlay rootfs so the real cron resolves.
          rm -rf ${hermesPackage}/share/hermes-agent/plugins/cron 2>/dev/null || true

          exec ${hermesPackage}/bin/hermes gateway "$@"
        ''} $out/entrypoint
      '';
      image = pkgs.dockerTools.buildLayeredImage {
        name = "hermes-qa";
        tag = "latest";
        contents = [
          hermesPackage
          pkgs.git
          pkgs.gh
          pkgs.jq
          pkgs.cacert
          pkgs.coreutils
          entrypoint
        ];
        config = {
          Entrypoint = [ "/entrypoint" ];
          WorkingDir = "/home/hermes-runner";
          Env = [
            "HERMES_MANAGED=true"
            "HOME=/home/hermes-runner"
            "HERMES_HOME=/home/hermes-runner/.hermes"
            "WORKSPACE_DIR=/home/hermes-runner/workspace/homelab"
            "SECRETS_DIR=/run/secrets"
            "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          ];
        };
        fakeRootCommands = ''
          mkdir -p ./home/hermes-runner
        '';
      };
    in
    {
      packages.hermes-qa-image = image;
    };

  den.aspects.virtualization.rootless-podman = {
    nixos = { host, config, pkgs, ... }: let
      envAgeFile = inputs.self + "/.secrets/hosts/${host.name}/hermes-qa-env.age";
      patAgeFile = inputs.self + "/.secrets/hosts/${host.name}/hermes-qa-github-pat.age";
      tailscaleKeyAgeFile = inputs.self + "/.secrets/shared/tailscale-auth-key.age";
      hasSecrets = builtins.pathExists envAgeFile || builtins.pathExists patAgeFile;
    in
    lib.mkMerge [
      {
        virtualisation.podman = {
          enable = true;
          dockerCompat = false;
          defaultNetwork.settings = {
            dns_enabled = true;
          };
        };

        home-manager.sharedModules = [ inputs.quadlet-nix.homeManagerModules.quadlet ];

        users.users.hermes-runner = {
          useDefaultShell = lib.mkForce false;
        };

        nix.settings.allowed-users = lib.mkForce [ "root" "@wheel" "hermes-runner" ];
      }

      (lib.mkIf hasSecrets {
        secretRequests = lib.optionalAttrs (builtins.pathExists envAgeFile) {
          hermes-qa-env = {
            provider = "agenix";
            ageFile = envAgeFile;
            mode = "0400";
            owner = "hermes-runner";
            group = "hermes-runner";
          };
        } // lib.optionalAttrs (builtins.pathExists patAgeFile) {
          hermes-qa-github-pat = {
            provider = "agenix";
            ageFile = patAgeFile;
            mode = "0400";
            owner = "hermes-runner";
            group = "hermes-runner";
          };
        } // lib.optionalAttrs (builtins.pathExists tailscaleKeyAgeFile) {
          hermes-qa-tailscale = {
            provider = "agenix";
            ageFile = tailscaleKeyAgeFile;
            mode = "0400";
            owner = "hermes-runner";
            group = "hermes-runner";
          };
        };
      })
    ];
  };
}
