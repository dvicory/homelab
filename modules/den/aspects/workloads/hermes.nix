{
  den,
  inputs,
  lib,
  ...
}:
let
  imageTagFor = system: "${system}-${inputs.self.shortRev or "dirty"}";

  profileFor =
    account:
    let
      cfg = account.settings.workloads.hermes or { };
      instance =
        cfg.instance
          or (throw "Hermes workload account '${account.userName}' has no settings.workloads.hermes.instance");
      serviceName = "hermes-${instance}";
    in
    {
      inherit cfg instance serviceName;
      inherit (account) userName;
      containerHome = "/home/hermes";
      workspaceDir = "/home/hermes/workspace/homelab";
      secretNames = {
        env = "${serviceName}-env";
        githubPat = "${serviceName}-github-pat";
        tailscale = "${serviceName}-tailscale";
      };
      tailscaleName = "${serviceName}-tailscale";
    };

  mkHermesImage =
    { pkgs, system }:
    let
      hermesPackage = (inputs.hermes-agent.packages.${system}.default).override {
        extraDependencyGroups = [ "messaging" ];
      };

      entrypoint = pkgs.runCommand "hermes-entrypoint" { } ''
        install -Dm555 ${pkgs.writeShellScript "hermes-entrypoint.sh" ''
          set -euo pipefail

          export HERMES_MANAGED=true
          mkdir -p "$HERMES_HOME"
          touch "$HERMES_HOME/.managed"
          mkdir -p "$HERMES_HOME"/{cron,sessions,logs,memories,plugins}

          if [ -f "$SECRETS_DIR/hermes-env" ]; then
            install -m 0600 "$SECRETS_DIR/hermes-env" "$HERMES_HOME/.env"
          fi

          if [ -f "$SECRETS_DIR/hermes-github-pat" ]; then
            PAT=$(cat "$SECRETS_DIR/hermes-github-pat")
            echo "$PAT" | gh auth login --with-token
            gh auth setup-git
            git config --global user.name "Hermes Agent"
            git config --global user.email "hermes-agent@users.noreply.github.com"
            if [ ! -d "$WORKSPACE_DIR/.git" ]; then
              mkdir -p "$WORKSPACE_DIR"
              git clone "$WORKSPACE_REPOSITORY" "$WORKSPACE_DIR"
            fi
            cd "$WORKSPACE_DIR"
            git fetch origin main || true
            unset PAT
          fi

          # The bundled plugins/cron shadows Hermes' complete Python cron
          # package. Removing the colliding plugin keeps the built-in scheduler.
          rm -rf ${hermesPackage}/share/hermes-agent/plugins/cron 2>/dev/null || true

          exec ${hermesPackage}/bin/hermes gateway "$@"
        ''} $out/entrypoint
      '';
    in
    pkgs.dockerTools.buildLayeredImage {
      name = "hermes-agent";
      tag = imageTagFor system;
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
        WorkingDir = "/home/hermes";
        Env = [
          "HERMES_MANAGED=true"
          "HOME=/home/hermes"
          "HERMES_HOME=/home/hermes/.hermes"
          "WORKSPACE_DIR=/home/hermes/workspace/homelab"
          "WORKSPACE_REPOSITORY=https://github.com/dvicory/homelab.git"
          "SECRETS_DIR=/run/secrets"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        ];
      };
      fakeRootCommands = ''
        mkdir -p ./home/hermes/.hermes ./home/hermes/workspace
      '';
    };
in
{
  # OCI images contain native binaries, so publish them for every Linux system
  # rather than hard-coding one architecture or creating unusable Darwin images.
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) (
      let
        image = mkHermesImage { inherit pkgs system; };
      in
      {
        packages.hermes-agent-image = image;
      }
    );

  # A resolved registry user contributes the static host platform and its own
  # secret requests. The profile data still comes only from the registry entry.
  den.aspects.workloads.hermes.account =
    { user, ... }:
    let
      profile = profileFor user;
    in
    {
      name = "workloads/hermes-account/${user.userName}";
      includes = [ den.aspects.virtualization.podman-user ];

      nixos =
        { host, ... }:
        let
          inherit (profile) secretNames userName;
          envAgeFile = host.secretPath + "/${secretNames.env}.age";
          patAgeFile = host.secretPath + "/${secretNames.githubPat}.age";
          tailscaleAgeFile = inputs.self + "/.secrets/shared/tailscale-auth-key.age";
        in
        {
          secretRequests =
            lib.optionalAttrs (builtins.pathExists envAgeFile) {
              ${secretNames.env} = {
                provider = "agenix";
                ageFile = envAgeFile;
                mode = "0400";
                owner = userName;
                group = userName;
              };
            }
            // lib.optionalAttrs (builtins.pathExists patAgeFile) {
              ${secretNames.githubPat} = {
                provider = "agenix";
                ageFile = patAgeFile;
                mode = "0400";
                owner = userName;
                group = userName;
              };
            }
            // lib.optionalAttrs (builtins.pathExists tailscaleAgeFile) {
              ${secretNames.tailscale} = {
                provider = "agenix";
                ageFile = tailscaleAgeFile;
                mode = "0400";
                owner = userName;
                group = userName;
              };
            };
        };
    };

  # The independently instantiated home receives its matching registry account
  # from env-to-homes and emits only Home Manager/Quadlet configuration.
  den.aspects.workloads.hermes.home =
    { account, ... }:
    let
      profile = profileFor account;
    in
    {
      name = "workloads/hermes-home/${account.userName}";
      includes = [ den.aspects.virtualization.quadlet-home ];

      homeManager =
        {
          host,
          osConfig,
          pkgs,
          ...
        }:
        let
          inherit (profile)
            cfg
            containerHome
            secretNames
            serviceName
            tailscaleName
            workspaceDir
            ;
          requiredSecrets = builtins.attrValues secretNames;
          hasRequiredSecrets = lib.all (
            name: lib.hasAttrByPath [ "age" "secrets" name ] osConfig
          ) requiredSecrets;
          image = cfg.image or "localhost/hermes-agent:${imageTagFor host.system}";
          repository = cfg.repository or "https://github.com/dvicory/homelab.git";
          tailscaleHostname = cfg.tailscale.hostname or serviceName;
          restartDrainTimeout = cfg.restartDrainTimeout or 120;
          configFile = (pkgs.formats.yaml { }).generate "${serviceName}-config.yaml" (
            cfg.config or {
              model.default = "opencode-go/deepseek-v4-flash";
              agent.restart_drain_timeout = restartDrainTimeout;
            }
          );
        in
        {
          home.stateVersion = "26.05";

          warnings = lib.optional (!hasRequiredSecrets) ''
            ${serviceName} containers are disabled until all required host secrets are provisioned.
          '';

          virtualisation.quadlet = lib.mkIf hasRequiredSecrets {
            containers = {
              ${tailscaleName} = {
                autoStart = true;
                containerConfig = {
                  image = "docker.io/tailscale/tailscale:latest";
                  addCapabilities = [ "NET_ADMIN" ];
                  devices = [ "/dev/net/tun" ];
                  environments = {
                    TS_STATE_DIR = "/var/lib/tailscale";
                    TS_AUTHKEY = "file:/run/secrets/tailscale-auth-key";
                    TS_HOSTNAME = tailscaleHostname;
                  };
                  volumes = [
                    "${tailscaleName}:/var/lib/tailscale"
                    "${osConfig.age.secrets.${secretNames.tailscale}.path}:/run/secrets/tailscale-auth-key:ro"
                  ];
                };
              };

              ${serviceName} = {
                autoStart = true;
                # Network=container only selects Podman's shared namespace; it
                # does not make systemd start that container first. Refer to
                # the Quadlet source unit so the generator translates this to
                # the matching generated service dependency.
                unitConfig = {
                  Requires = [ "${tailscaleName}.container" ];
                  After = [ "${tailscaleName}.container" ];
                };
                containerConfig = {
                  inherit image;
                  networks = [ "container:${tailscaleName}" ];
                  environments = {
                    HOME = containerHome;
                    HERMES_HOME = "${containerHome}/.hermes";
                    WORKSPACE_DIR = workspaceDir;
                    WORKSPACE_REPOSITORY = repository;
                    SECRETS_DIR = "/run/secrets";
                  };
                  volumes = [
                    "${serviceName}-state:${containerHome}/.hermes"
                    "${serviceName}-workspace:${containerHome}/workspace"
                    "${configFile}:${containerHome}/.hermes/config.yaml:ro"
                    "${osConfig.age.secrets.${secretNames.env}.path}:/run/secrets/hermes-env:ro"
                    "${osConfig.age.secrets.${secretNames.githubPat}.path}:/run/secrets/hermes-github-pat:ro"
                  ];
                };
                serviceConfig.TimeoutStopSec = restartDrainTimeout + 30;
              };
            };
          };
        };
    };
}
