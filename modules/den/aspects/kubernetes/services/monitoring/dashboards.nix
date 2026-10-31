# Grafana dashboards for prod-home monitoring.
#
# Grafana renders only with the `grafana` administrator route and in identity
# phase `normal`, when its sign-in can work. Alerting does not need it. The
# Gateway requires administrator sign-in before any request reaches Grafana,
# and Grafana signs the user in again through the same Kanidm client, with no
# login form, basic authentication or anonymous access.
{ inputs, lib, ... }:
let
  inherit (lib) mkOption types;
  namespace = "monitoring";
  dashboardsDirectory = inputs.self + "/assets/monitoring/dashboards";
  # Each vendored dashboard records its upstream source, revision and
  # SHA-256; evaluation fails if a file no longer matches its record.
  dashboardSources = builtins.fromJSON (builtins.readFile (dashboardsDirectory + "/sources.json"));
in
{
  den.aspects.kubernetes.services.monitoring.settings.grafana.oidc = mkOption {
    type = types.submodule {
      options = {
        # Kanidm refuses a request whose scopes are not all mapped to the
        # user's groups; `groups_name` emits short group names in `groups`.
        scopes = mkOption {
          type = types.listOf types.str;
          default = [
            "openid"
            "profile"
            "email"
            "groups_name"
          ];
          description = "Scopes Grafana requests; identity provisioning maps each one to the administrator group.";
        };
        secretName = mkOption {
          type = types.str;
          default = "grafana-oidc";
          description = "Secret in the monitoring namespace where identity provisioning publishes the client secret.";
        };
        secretKey = mkOption {
          type = types.str;
          default = "client-secret";
          description = "Key of the client secret in that Secret.";
        };
      };
    };
    default = { };
    description = "Grafana's sign-in through Kanidm. Identity provisioning adds these values to the Kanidm client of the `grafana` route, which the Gateway also uses.";
  };

  den.aspects.kubernetes.services.monitoring.dashboards = {
    # Both administrator credentials use agenix-rekey's generated runtime flow;
    # nobody types them.
    compute-resources = _: {
      runtimeSecrets.monitoring--grafana-admin--secret-key = {
        inherit namespace;
        name = "grafana-admin";
        key = "secret-key";
        generator = "alnum-no-newline";
      };
      runtimeSecrets.monitoring--grafana-admin--admin-password = {
        inherit namespace;
        name = "grafana-admin";
        key = "admin-password";
        generator = "alnum-no-newline";
      };
    };

    k8s-manifests =
      {
        cluster,
        computeResources,
        lib,
        ...
      }:
      let
        identity = cluster.settings.kubernetes.services.identity;
        identityHostname = builtins.head cluster.routes.idm.hostnames;
        oidc = cluster.settings.kubernetes.services.monitoring.grafana.oidc;
        route = cluster.routes.grafana;
        hostname = builtins.head route.hostnames;
        url = "https://${hostname}";
        enabled = cluster.routes ? grafana && identity.phase == "normal";
        dashboards = lib.mapAttrs (
          file: record:
          let
            path = dashboardsDirectory + "/${file}";
          in
          assert lib.assertMsg (
            builtins.hashFile "sha256" path == record.sha256
          ) "monitoring dashboard ${file} does not match its recorded SHA-256";
          builtins.readFile path
        ) dashboardSources;
      in
      assert lib.assertMsg (
        !(cluster.routes ? grafana)
        ||
          route.namespace == namespace
          && route.service == "grafana"
          && route.auth == "admin"
          && route.pathPrefix == "/"
      ) "The grafana route must be an administrator route to monitoring/grafana at the hostname root";
      lib.optionalAttrs enabled {
        applications.monitoring = {
          objects = [
            {
              apiVersion = "v1";
              kind = "ConfigMap";
              metadata = {
                name = "grafana-dashboards";
                inherit namespace;
              };
              data = dashboards;
            }
          ];

          helm.releases.grafana = {
            chart = lib.helm.downloadHelmChart {
              repo = "oci://ghcr.io/grafana-community/helm-charts";
              chart = "grafana";
              version = "13.5.0";
              chartHash = "sha256-yWw0Dj4RBv21iHNTZW9mSR6LWo0P4ZceDpSQdH9HSVc=";
            };
            values = {
              fullnameOverride = "grafana";
              image = {
                registry = "docker.io";
                repository = "grafana/grafana";
                tag = "13.2.3-distroless";
                # The chart prefixes the algorithm itself.
                sha = "202e5d5b3f8499e70ccac7991eea6d7da72d2790eb2e0597e7987acf724e7180";
              };
              testFramework.enabled = false;
              rbac.create = false;
              serviceAccount = {
                create = true;
                automountServiceAccountToken = false;
              };
              automountServiceAccountToken = false;
              # The database is disposable; dashboards and data sources come
              # from Git.
              persistence.enabled = false;
              initChownData.enabled = false;
              sidecar = {
                dashboards.enabled = false;
                datasources.enabled = false;
              };
              nodeSelector."kubernetes.io/hostname" = computeResources.instance;
              resources = {
                requests = {
                  cpu = "50m";
                  memory = "192Mi";
                };
                limits = {
                  cpu = "1";
                  memory = "1Gi";
                };
              };
              # This managed password seeds only a new disposable database.
              # Normal local sign-in stays disabled; emergency access is private.
              # Explicitly reuse the runtime Secret, never the chart's random one.
              admin.existingSecret = "grafana-admin";
              env = {
                GF_SECURITY_ADMIN_USER = "admin";
                # Grafana expands $__file itself; the distroless image has no
                # /run.sh to honour the __FILE form.
                GF_SECURITY_ADMIN_PASSWORD = "$__file{/etc/secrets/grafana-admin/admin-password}";
              };
              extraSecretMounts = [
                {
                  name = "grafana-admin";
                  secretName = "grafana-admin";
                  mountPath = "/etc/secrets/grafana-admin";
                  readOnly = true;
                  defaultMode = 288;
                }
                {
                  name = "grafana-oidc";
                  secretName = oidc.secretName;
                  mountPath = "/etc/secrets/grafana-oidc";
                  readOnly = true;
                  defaultMode = 288;
                }
              ];
              "grafana.ini" = {
                server = {
                  root_url = url;
                  domain = hostname;
                };
                analytics = {
                  reporting_enabled = false;
                  check_for_updates = false;
                  check_for_plugin_updates = false;
                };
                news.news_feed_enabled = false;
                security = {
                  secret_key = "$__file{/etc/secrets/grafana-admin/secret-key}";
                  cookie_secure = true;
                  disable_gravatar = true;
                };
                users.allow_sign_up = false;
                auth = {
                  disable_login_form = true;
                };
                "auth.basic".enabled = false;
                "auth.anonymous".enabled = false;
                "auth.generic_oauth" = {
                  enabled = true;
                  auto_login = true;
                  name = "Kanidm";
                  # Identity names each administrator route's client after
                  # the route, so Grafana and its entrance share one client.
                  client_id = "grafana";
                  client_secret = "$__file{/etc/secrets/grafana-oidc/${oidc.secretKey}}";
                  scopes = lib.concatStringsSep " " oidc.scopes;
                  auth_url = "https://${identityHostname}/ui/oauth2";
                  token_url = "https://${identityHostname}/oauth2/token";
                  api_url = "https://${identityHostname}/oauth2/openid/grafana/userinfo";
                  use_pkce = true;
                  use_refresh_token = true;
                  allow_sign_up = true;
                  login_attribute_path = "preferred_username";
                  email_attribute_path = "email";
                  groups_attribute_path = "groups";
                  # Only the administrator group gets a role; everyone else
                  # is refused.
                  role_attribute_path = "contains(groups[*], '${identity.adminGroup}') && 'Admin' || ''";
                  role_attribute_strict = true;
                  allow_assign_grafana_admin = false;
                };
                # Keep the external Alertmanager UI, but leave evaluation to vmalert.
                unified_alerting.execute_alerts = false;
                # Grafana's own metrics endpoint would be reachable through its route.
                metrics.enabled = false;
                # No plugin downloads at start: the image is the pinned set.
                plugins.preinstall_disabled = true;
              };
              datasources."datasources.yaml" = {
                apiVersion = 1;
                datasources = [
                  {
                    name = "VictoriaMetrics";
                    uid = "victoriametrics";
                    type = "prometheus";
                    access = "proxy";
                    url = "http://victoriametrics.${namespace}.svc:8428";
                    isDefault = true;
                    editable = false;
                    jsonData.timeInterval = "30s";
                  }
                  {
                    name = "Alertmanager";
                    uid = "alertmanager";
                    type = "alertmanager";
                    access = "proxy";
                    url = "http://alertmanager.${namespace}.svc:9093";
                    editable = false;
                    jsonData = {
                      implementation = "prometheus";
                      handleGrafanaManagedAlerts = false;
                    };
                  }
                ];
              };
              dashboardProviders."dashboardproviders.yaml" = {
                apiVersion = 1;
                providers = [
                  {
                    name = "homelab";
                    orgId = 1;
                    type = "file";
                    disableDeletion = true;
                    allowUiUpdates = false;
                    editable = false;
                    options.path = "/var/lib/grafana/dashboards/homelab";
                  }
                ];
              };
              dashboardsConfigMaps.homelab = "grafana-dashboards";
            };
          };
        };
      };
  };
}
