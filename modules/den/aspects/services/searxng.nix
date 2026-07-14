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
        type = lib.types.str;
        description = "Path to agenix secret containing SEARXNG_SECRET_KEY.";
      };
    };

    nixos = { host, config, pkgs, ... }: let
      cfg = host.settings.services.searxng or { };
      svcName = cfg.instance or "searxng";
      dataVolume = "${svcName}-data";
      secretName = "searxng-secret-key";
      ageFile = cfg.secretKeyFile;
      provisioned = builtins.pathExists ageFile;
    in lib.mkMerge [
      (lib.mkIf (cfg.enable or false) {
        secretRequests.${secretName} = lib.mkIf provisioned {
          provider = "agenix";
          inherit ageFile;
          mode = "0400";
        };

        warnings = lib.optional (!provisioned) ''
          SearXNG (${svcName}) is enabled but no age secret found at ${ageFile}.
          Create it with: echo "my-secret-key" | agenix -e ${ageFile}
          Then run: agenix rekey
        '';

        virtualisation.quadlet.containers.${svcName} = lib.mkIf provisioned {
          autoStart = true;
          containerConfig = {
            image = "docker.io/searxng/searxng:latest";
            publishPorts = [ "${toString cfg.port}:8080" ];
            environments = {
              SEARXNG_BASE_URL = cfg.baseUrl;
              SEARXNG_SECRET_KEY = "file:/run/secrets/${secretName}";
            };
            volumes = [
              "${dataVolume}:/etc/searxng:rw"
            ];
          };
          serviceConfig.TimeoutStopSec = 30;
        };
      })
      {
        environment.systemPackages = [ pkgs.curl ];
      }
    ];
  };
}
