{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  validOctet = value: builtins.match "^(0|[1-9][0-9]{0,2})$" value != null;
  parseIPv4 =
    address:
    let
      parts = lib.splitString "." address;
      valid = builtins.length parts == 4 && lib.all validOctet parts;
    in
    if valid then map builtins.fromJSON parts else [ ];
  privateIPv4 =
    address:
    let
      octets = parseIPv4 address;
      valid = builtins.length octets == 4 && lib.all (octet: octet <= 255) octets;
      first = if valid then builtins.elemAt octets 0 else -1;
      second = if valid then builtins.elemAt octets 1 else -1;
    in
    valid
    && (
      first == 10
      || (first == 172 && second >= 16 && second <= 31)
      || (first == 192 && second == 168)
      || (first == 100 && second >= 64 && second <= 127)
    );
  privatePeerCIDR =
    cidr:
    let
      parts = lib.splitString "/" cidr;
    in
    builtins.length parts == 2
    && privateIPv4 (builtins.elemAt parts 0)
    && builtins.elemAt parts 1 == "32";

  tlsType = types.submodule {
    options = {
      certificate = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "TLS certificate for this edge's selected hostname family.";
      };
      key = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "TLS private key for this edge's selected hostname family.";
      };
    };
  };

  settingsFor = role: {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the independently deployed ${role} edge.";
    };

    originHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Private IPv4 address of the Gateway origin.";
    };

    originPort = mkOption {
      type = types.port;
      default = 30443;
      description = "Private HTTPS NodePort for the Gateway origin.";
    };

    originServerName = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "TLS SNI/name used to verify the private Gateway origin.";
    };

    originCA = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "CA bundle used to verify the private Gateway origin.";
    };

    peerAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Private source address presented by this edge; the exact /32 must be in cluster.ingress.trustedProxyCIDRs.";
    };

    bareRoute = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Route-inventory key receiving the bare-domain redirect.";
    };

    tls = mkOption {
      type = types.submodule {
        options = {
          primary = mkOption {
            type = tlsType;
            default = { };
            description = "Certificate input for the primary hostname family.";
          };
          backup = mkOption {
            type = tlsType;
            default = { };
            description = "Certificate input for the backup hostname family.";
          };
        };
      };
      default = { };
      description = "Separate primary and backup TLS inputs; no ACME or DNS automation.";
    };
  };

  proxyLocation =
    {
      originHost,
      originPort,
      originServerName,
      originCA,
    }:
    {
      proxyPass = "https://${originHost}:${toString originPort}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_ssl_server_name on;
        proxy_ssl_name ${originServerName};
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 3;
        proxy_ssl_trusted_certificate ${originCA};
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header Forwarded "";
        proxy_set_header X-Request-ID $request_id;
        proxy_set_header X-Forwarded-User "";
        proxy_set_header X-Forwarded-Email "";
        proxy_set_header X-Auth-Request-User "";
        proxy_set_header X-Auth-Request-Email "";
        proxy_set_header Remote-User "";
      '';
    };

  mkRole =
    role:
    let
      aspectName = "${role}-edge";
      variant = if role == "remote" then 0 else 1;
    in
    {
      settings = settingsFor role;

      nixos =
        { host, ... }:
        let
          cfg = host.settings.services.${aspectName};
          cluster = config.den.clusters."prod-home";
          environment = config.den.environments.${cluster.environment};
          identityNormal = cluster.settings.kubernetes.services.identity.phase == "normal";
          routes = lib.filterAttrs (
            name: route:
            route.exposure == "public" && (identityNormal || (route.auth != "admin" && name != "idm"))
          ) cluster.routes;
          tlsConfig = cfg.tls;
          selectedTLS = if variant == 0 then tlsConfig.primary else tlsConfig.backup;
          selectedDomain = if variant == 0 then environment.domain else environment.backupDomain;
          routeShapeValid = lib.all (
            route:
            builtins.length route.hostnames == 2
            && lib.all (hostname: hostname != "") route.hostnames
            && builtins.length (lib.unique route.hostnames) == 2
          ) (builtins.attrValues routes);
          routeDomainsValid =
            routeShapeValid
            && lib.all (
              route:
              lib.hasSuffix ".${environment.domain}" (builtins.elemAt route.hostnames 0)
              && lib.hasSuffix ".${environment.backupDomain}" (builtins.elemAt route.hostnames 1)
            ) (builtins.attrValues routes);
          routePathsValid = lib.all (route: route.pathPrefix == "/") (builtins.attrValues routes);
          routesValid = routeShapeValid && routeDomainsValid && routePathsValid;
          routeEntries =
            if routesValid then
              lib.mapAttrsToList (name: route: {
                inherit name;
                hostname = builtins.elemAt route.hostnames variant;
                tls = selectedTLS;
              }) routes
              ++ lib.optionals (role == "home" && routes ? idm) [
                {
                  name = "idm-canonical";
                  hostname = builtins.head routes.idm.hostnames;
                  tls = tlsConfig.primary;
                }
              ]
            else
              [ ];
          routeHosts = map (entry: entry.hostname) routeEntries;
          routeHostsUnique = builtins.length (lib.unique routeHosts) == builtins.length routeHosts;
          bareRouteValid = cfg.bareRoute != null && builtins.hasAttr cfg.bareRoute cluster.routes && routesValid;
          bareRoutePublishable = bareRouteValid && builtins.hasAttr cfg.bareRoute routes;
          bareTarget =
            if bareRoutePublishable then builtins.elemAt routes.${cfg.bareRoute}.hostnames variant else "";
          primaryTLS = tlsConfig.primary;
          backupTLS = tlsConfig.backup;
          tlsPairValid =
            family:
            (family.certificate == null) == (family.key == null)
            && (family.certificate == null || family.certificate != "")
            && (family.key == null || family.key != "");
          tlsInputsValid =
            tlsPairValid primaryTLS
            && tlsPairValid backupTLS
            && selectedTLS.certificate != null
            && selectedTLS.key != null
            && (role != "home" || !(routes ? idm) || (primaryTLS.certificate != null && primaryTLS.key != null));
          originValid =
            cfg.originHost != null
            && privateIPv4 cfg.originHost
            && cfg.originServerName != null
            && cfg.originServerName != ""
            && cfg.originCA != null
            && cfg.originCA != ""
            && cfg.peerAddress != null
            && privateIPv4 cfg.peerAddress
            && cfg.peerAddress != cfg.originHost;
          peerCIDR = if cfg.peerAddress == null then "" else "${cfg.peerAddress}/32";
          peerIsDeclared = peerCIDR != "" && builtins.elem peerCIDR cluster.ingress.trustedProxyCIDRs;
          edgeModeValid = cluster.ingress.mode == "trustedEdges";
          origin = {
            inherit (cfg)
              originHost
              originPort
              originServerName
              originCA
              ;
          };
          virtualHosts =
            if routesValid && routeHostsUnique && bareRouteValid && tlsInputsValid && originValid then
              lib.listToAttrs (
                map (entry: {
                  name = entry.hostname;
                  value = {
                    forceSSL = true;
                    sslCertificate = entry.tls.certificate;
                    sslCertificateKey = entry.tls.key;
                    locations."/" = proxyLocation origin;
                  };
                }) routeEntries
              )
              // {
                "_" = {
                  default = true;
                  rejectSSL = true;
                  locations."/" = {
                    return = "404";
                  };
                };
              }
              // lib.optionalAttrs bareRoutePublishable {
                ${selectedDomain} = {
                  forceSSL = true;
                  sslCertificate = selectedTLS.certificate;
                  sslCertificateKey = selectedTLS.key;
                  locations."/" = {
                    return = "308 https://${bareTarget}$request_uri";
                  };
                };
              }
            else
              {
                "_" = {
                  default = true;
                  rejectSSL = true;
                  locations."/" = {
                    return = "404";
                  };
                };
              };
        in
        lib.mkIf cfg.enable {
          assertions = [
            {
              assertion = config.den.clusters ? "prod-home";
              message = "${aspectName} requires the prod-home route inventory";
            }
            {
              assertion = routeShapeValid;
              message = "${aspectName} requires exactly two distinct non-empty hostnames per route";
            }
            {
              assertion = routeDomainsValid;
              message = "${aspectName} requires primary and backup hostnames under their declared domains";
            }
            {
              assertion = routePathsValid;
              message = "${aspectName} only supports hostname-root routes";
            }
            {
              assertion = routeHostsUnique;
              message = "${aspectName} route hostnames must be unique";
            }
            {
              assertion = bareRouteValid;
              message = "${aspectName} bareRoute must name a declared route";
            }
            {
              assertion = originValid;
              message = "${aspectName} requires a private origin address, verified TLS SNI/CA and a distinct private peer address";
            }
            {
              assertion = tlsInputsValid;
              message = "${aspectName} requires complete primary/backup TLS pairs and the selected family";
            }
            {
              assertion = peerIsDeclared;
              message = "${aspectName} peerAddress must be declared as an exact trusted Gateway peer";
            }
            {
              assertion = edgeModeValid;
              message = "${aspectName} requires ingress mode trustedEdges";
            }
            {
              assertion = lib.all privatePeerCIDR cluster.ingress.trustedProxyCIDRs;
              message = "Gateway trusted proxy entries must be private /32 edge peers";
            }
          ];

          services.nginx = {
            enable = true;
            recommendedOptimisation = true;
            recommendedProxySettings = false;
            commonHttpConfig = ''
              log_format homelab_safe escape=json
                '{"timestamp":"$time_iso8601",'
                '"client":"$remote_addr",'
                '"method":"$request_method",'
                '"path":"$uri",'
                '"host":"$host",'
                '"status":$status,'
                '"duration_s":$request_time,'
                '"request_id":"$request_id",'
                '"upstream_status":"$upstream_status",'
                '"bytes_sent":$bytes_sent}';
              access_log /var/log/nginx/access.log homelab_safe;
            '';
            recommendedTlsSettings = true;
            virtualHosts = virtualHosts;
          };

          networking.firewall.allowedTCPPorts = [
            80
            443
          ];
        };
    };
in
{
  den.aspects.services.remote-edge = mkRole "remote";
  den.aspects.services.home-edge = mkRole "home";
}
