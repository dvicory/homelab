{ inputs, lib, ... }: {
  den.aspects.services.searxng = {
    settings = {
      enable = lib.mkEnableOption "SearXNG self-hosted search engine";

      instance = lib.mkOption {
        type = lib.types.str;
        default = "searxng";
        description = "Quadlet container instance name.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "Host port to map SearXNG to.";
      };

      baseUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://localhost:8080";
        description = "Public-facing base URL for SearXNG.";
      };

      secretKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path to agenix secret containing SEARXNG_SECRET_KEY=...";
      };
    };

    nixos = { host, config, pkgs, ... }: let
      cfg = host.settings.services.searxng or { };
      svcName = cfg.instance or "searxng";
      dataVolume = "${svcName}-data";
      secretName = "searxng-secret-key";
      ageFile = cfg.secretKeyFile;
      provisioned = ageFile != null && builtins.pathExists ageFile;
    in lib.mkIf (cfg.enable or false) {

      secretRequests.${secretName} = lib.mkIf provisioned {
        provider = "agenix";
        inherit ageFile;
        mode = "0400";
      };

      warnings = lib.optional (!provisioned) ''
        SearXNG (${svcName}) is enabled but no age secret found at ${builtins.toString ageFile}.
        Create it with:
          echo 'SEARXNG_SECRET_KEY=your-random-secret' | agenix -e ${builtins.toString ageFile}
          agenix rekey
          git add .secrets/ && git commit
      '';

      virtualisation.quadlet.containers.${svcName} = lib.mkIf provisioned {
        autoStart = true;
        containerConfig = {
          image = "docker.io/searxng/searxng:latest";
          publishPorts = [ "${toString cfg.port}:8080" ];
          environmentFiles = [
            "${config.age.secrets.${secretName}.path}"
          ];
          environments = {
            SEARXNG_BASE_URL = cfg.baseUrl;
          };
          volumes = [
            "${dataVolume}:/etc/searxng:rw"
          ];
        };
        serviceConfig.TimeoutStopSec = 30;
      };

      environment.systemPackages = lib.mkIf provisioned [ pkgs.curl ];
    };
  };
}
