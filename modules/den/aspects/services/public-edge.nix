{ den, lib, ... }:
{
  den.aspects.services.public-edge = {

    settings = {
      enable = lib.mkEnableOption "the independent public edge";

      originHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Private origin address reachable from this edge; required when enabled.";
      };

      originPort = lib.mkOption {
        type = lib.types.port;
        default = 30443;
        description = "Private HTTPS NodePort for the Gateway origin.";
      };

      originServerName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "TLS SNI/name used to verify the private origin certificate.";
      };

      families = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            primary = lib.mkOption { type = lib.types.str; description = "Primary wildcard domain family."; };
            backup = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Manual-failover wildcard domain family."; };
            certificate = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Certificate covering both wildcard families."; };
            key = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Private key for certificate."; };
            originCA = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "CA bundle used to verify Gateway origin TLS."; };
          };
        });
        default = { };
        description = "Wildcard domain families forwarded without an application route table.";
      };
    };

    nixos =
      { host, ... }:
      let
        cfg = host.settings.services.public-edge;
      in
      lib.mkIf cfg.enable (
        let
          hostEntries = lib.concatLists (lib.mapAttrsToList (_: family:
            [ { host = "*.${family.primary}"; inherit (family) certificate key originCA; } ]
            ++ lib.optional (family.backup != null) { host = "*.${family.backup}"; inherit (family) certificate key originCA; }
          ) cfg.families);
          virtualHosts = lib.listToAttrs (map (entry: {
            name = entry.host;
            value = {
              forceSSL = true;
              sslCertificate = entry.certificate;
              sslCertificateKey = entry.key;
              locations."/" = {
                proxyPass = "https://${cfg.originHost}:${toString cfg.originPort}";
                proxyWebsockets = true;
                extraConfig = ''
                  proxy_ssl_server_name on;
                  proxy_ssl_name ${cfg.originServerName};
                  proxy_ssl_protocols TLSv1.2 TLSv1.3;
                  proxy_ssl_verify on;
                  proxy_ssl_verify_depth 3;
                  proxy_ssl_trusted_certificate ${entry.originCA};
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
                  proxy_set_header X-Forwarded-For $remote_addr;
                  proxy_set_header X-Forwarded-Host $host;
                  proxy_set_header X-Forwarded-Proto https;
                  proxy_set_header Forwarded "";
                  proxy_set_header X-Forwarded-User "";
                  proxy_set_header X-Forwarded-Email "";
                  proxy_set_header X-Auth-Request-User "";
                  proxy_set_header X-Auth-Request-Email "";
                '';
              };
            };
          }) hostEntries);
        in
        {
          assertions = [
            { assertion = cfg.originHost != null; message = "public-edge requires an explicit private originHost"; }
            { assertion = cfg.originServerName != null; message = "public-edge requires an explicit originServerName"; }
            { assertion = hostEntries != [ ]; message = "public-edge requires at least one domain family"; }
            { assertion = lib.all (family: family.backup == null || family.backup != family.primary) (builtins.attrValues cfg.families); message = "public-edge primary and backup families must differ"; }
            { assertion = lib.all (entry: entry.certificate != null && entry.key != null && entry.originCA != null) hostEntries; message = "public-edge requires certificate, key, and originCA for every family"; }
          ];
          services.nginx = {
            enable = true;
            recommendedOptimisation = true;
            recommendedProxySettings = false;
            recommendedTlsSettings = true;
            virtualHosts = {
              "_" = {
                default = true;
                locations."/" = { return = "404"; };
              };
            } // virtualHosts;
          };
          networking.firewall.allowedTCPPorts = [ 80 443 ];
        }
      );
  };
}
